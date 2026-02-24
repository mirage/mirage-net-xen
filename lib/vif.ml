(*
 * Copyright (c) 2010-2013 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (c) 2014-2015 Citrix Inc
 * Copyright (c) 2015 Thomas Leonard <talex5@gmail.com>
 * Copyright (c) 2026 Pierre Alain <pierre.alain@tuta.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 * Unified Xen network channel implementation for both frontend and backend.
 *)

open Lwt.Infix

module Gntref = Xen_os.Xen.Gntref
module Export = Xen_os.Xen.Export
module Import = Xen_os.Xen.Import

let src = Logs.Src.create "net-xen channel" ~doc:"Unified Xen network channel"
module Log = (val Logs.src_log src : Logs.LOG)

let return = Lwt.return

(* ============================================================================
   TYPES
   ============================================================================ *)

type kind = 
  | Frontend
  | Backend

type 'a ring_side =
  | Front_ring of ('a, int) Ring.Rpc.Front.t * ('a, int) Lwt_ring.Front.t
  | Back_ring of ('a, int) Ring.Rpc.Back.t

type transport = {
  kind: kind;
  vif_id: int;
  peer_domid: int;
  mac: Macaddr.t;
  peer_mac: Macaddr.t option;
  mtu: int;
  
  tx_ring: TX.Response.t ring_side;
  tx_gnt: Gntref.t;
  tx_mutex: Lwt_mutex.t;
  tx_pool: Shared_page_pool.t option;
  
  rx_ring: RX.Response.t ring_side;
  rx_gnt: Gntref.t;
  rx_grants: RX.Request.t Lwt_dllist.t option;
  rx_map: (int, Gntref.t * Io_page.t) Hashtbl.t option;
  mutable rx_id: int;
  mutable free_pages: Io_page.t list;
  
  evtchn: Xen_os.Eventchn.t;
  stats: Mirage_net.stats;
}

type grant_ops = {
  get_tx_grants: transport -> int -> (Gntref.t * Io_page.t) list Lwt.t;
  get_rx_grants: transport -> int -> (Gntref.t * Io_page.t) list Lwt.t;
  release_grant: transport -> Gntref.t -> unit Lwt.t;
}

type t = {
  mutable t: transport;
  l: Lwt_mutex.t;
  c: unit Lwt_condition.t;
  grant_ops: grant_ops;
}

let h = Xen_os.Eventchn.init ()

(* ============================================================================
   RING CREATION
   ============================================================================ *)

let frontend_allocate_ring ~domid =
  let page = Io_page.get 1 in
  let x = Io_page.to_cstruct page in
  Export.get () >>= fun gnt ->
  Export.grant_access ~domid ~writable:true gnt page;
  return (gnt, x, page)

let frontend_create_ring ~domid ~idx_size name =
  frontend_allocate_ring ~domid >>= fun (gnt, buf, page) ->
  let sring = Ring.Rpc.of_buf ~buf ~idx_size ~name in
  let fring = Ring.Rpc.Front.init ~sring in
  let client = Lwt_ring.Front.init string_of_int fring in
  return (gnt, Front_ring (fring, client), page)

let backend_import_ring ~domid ~gntref ~idx_size name writable =
  let grant = {Import.domid; ref = gntref} in
  let mapping = Import.map_exn grant ~writable in
  let buf = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
  let sring = Ring.Rpc.of_buf_no_init ~buf ~idx_size ~name in
  let bring = Ring.Rpc.Back.init ~sring in
  return (Back_ring bring, mapping)

(* ============================================================================
   RING OPERATIONS
   ============================================================================ *)

module Ring_ops = struct
  let next_req_id = function
    | Front_ring (fring, _) -> Ring.Rpc.Front.next_req_id fring
    | Back_ring bring -> Ring.Rpc.Back.next_res_id bring 
  
  let slot = function
    | Front_ring (fring, _) -> fun id -> Ring.Rpc.Front.slot fring id
    | Back_ring bring -> fun id -> Ring.Rpc.Back.slot bring id
  
  let push_and_check_notify = function
    | Front_ring (fring, _) -> Ring.Rpc.Front.push_requests_and_check_notify fring
    | Back_ring bring -> Ring.Rpc.Back.push_responses_and_check_notify bring
  
  let ack = function
    | Front_ring (fring, _) -> fun f -> Ring.Rpc.Front.ack_responses fring f
    | Back_ring bring -> fun f -> Ring.Rpc.Back.ack_requests bring f
  
  let get_free_slots = function
    | Front_ring (fring, _) -> Ring.Rpc.Front.get_free_requests fring
    | Back_ring _bring -> failwith "Backend doesn't have free ring slots" (* unused *)
  
  let wait_for_free ring n = match ring with
    | Front_ring (_, client) -> Lwt_ring.Front.wait_for_free client n
    | Back_ring _ -> failwith "Backend doesn't wait for free ring slots" (* unused *)
end

(* ============================================================================
   GRANT MANAGEMENT
   ============================================================================ *)

let backend_get_n_grefs t n =
  let rx_grants = Option.get t.rx_grants in
  let rec take seq = function
    | 0 -> []
    | _n(*TODO*) when Lwt_dllist.is_empty seq -> []
    | n -> Lwt_dllist.take_l seq :: (take seq (n - 1))
  in
  
  let rec loop after =
    let n' = Lwt_dllist.length rx_grants in
    (* Log.debug (fun f -> f "[Backend.TX] get_n_grefs: need %d, have %d" n n'); *)
    
    if n' >= n then return (take rx_grants n)
    else begin
      (* Log.debug (fun f -> f "[Backend.TX] Not enough grefs, acking requests from ring"); *)
      
      Ring_ops.ack t.rx_ring (fun slot ->
        let req = RX.Request.read slot in
        (*Log.debug (fun f -> f "[Backend.TX] Got RX request: id=%d gref=%ld" 
          req.RX.Request.id req.RX.Request.gref);*)
        ignore(Lwt_dllist.add_r req rx_grants)
      );
      
      let new_n = Lwt_dllist.length rx_grants in
      (* Log.debug (fun f -> f "[Backend.TX] After acking: had %d, now have %d grefs" n' new_n); *)
      
      if new_n <> n' then
        loop after
      else begin
        (* Log.debug (fun f -> f "[Backend.TX] No new grefs, waiting for event on channel"); *)
        Xen_os.Activations.after t.evtchn after >>= loop
      end
    end
  in
  (* Log.debug (fun f -> f "[Backend.TX] get_n_grefs: do not wait for lock, write already took it"); *)
  (* Lwt_mutex.with_lock t.tx_mutex (fun () -> *)
    (* Log.debug (fun f -> f "[Backend.TX] get_n_grefs: acquired lock, starting"); *)
    loop Xen_os.Activations.program_start
  (* ) *)

(* ============================================================================
   TX/RX OPERATIONS
   ============================================================================ *)

module Unified_TX_Ops = struct
  type nonrec t = transport
  
  let fragment_data t data =
    let size = Cstruct.length data in
    
    match t.kind with
    | Frontend ->
        let numneeded = Shared_page_pool.blocks_needed size in
        let tx_pool = Option.get t.tx_pool in
        
        (* Log.debug (fun f -> f "[Frontend.TX] fragment_data: size=%d, need %d blocks" size numneeded); *)
        
        Ring_ops.wait_for_free t.tx_ring numneeded >>= fun () ->
        (* Log.debug (fun f -> f "[Frontend.TX] wait_for_free completed, proceeding with copy"); *)
        
        let rec copy_to_pages datav offset acc_frags = function
          | 0 -> return (List.rev acc_frags)
          | n ->
              Shared_page_pool.use tx_pool (fun ~id gref shared_block ->
                let len, datav' = Cstruct.fillv ~src:datav ~dst:shared_block in
                let frag = Assemble.{
                  id; offset = shared_block.Cstruct.off; size = len;
                  gref = Gntref.to_int32 gref;
                } in
                return ((datav', frag, Io_page.get 1), Lwt.return_unit)
              ) >>= fun ((datav', frag, page), _) ->
              copy_to_pages datav' (offset + frag.size) ((frag, page) :: acc_frags) (n - 1)
        in
        copy_to_pages [data] 0 [] numneeded
    
    | Backend ->
        let pages_needed = max 1 @@ Io_page.round_to_page_size size / Io_page.page_size in
        
        (* Log.debug (fun f -> f "[Backend.TX] fragment_data: size=%d, pages_needed=%d" size pages_needed); *)
        
        backend_get_n_grefs t pages_needed >>= fun reqs ->
        
        (* Log.debug (fun f -> f "[Backend.TX] Got %d grant refs, mapping and copying" (List.length reqs)); *)
        
        let rec map_and_copy src offset acc_frags = function
          | [] -> return (List.rev acc_frags)
          | req :: rest ->
              let gnt = {Import.domid = t.peer_domid; ref = Gntref.of_int32 req.RX.Request.gref} in
              let mapping = Import.map_exn gnt ~writable:true in
              let dst = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
              
              Cstruct.memset dst 0;
              
              let to_copy = min (Cstruct.length dst) (size - offset) in
              let src_part = Cstruct.sub src offset to_copy in
              Cstruct.blit src_part 0 dst 0 to_copy;
              
              let frag = Assemble.{
                id = req.RX.Request.id;
                offset = 0;
                size = to_copy;
                gref = req.RX.Request.gref;
              } in
              
              let page = Import.Local_mapping.to_buf mapping in
              Import.Local_mapping.unmap_exn mapping;
              
              map_and_copy src (offset + to_copy) ((frag, page) :: acc_frags) rest
        in
        
        map_and_copy data 0 [] reqs
  
  let write_packet_to_ring t packet =
    match t.kind with
    | Frontend ->
        Assemble.TX_IO.write_packet
          ~get_slot:(fun () ->
            let id = Ring_ops.next_req_id t.tx_ring in
            Ring_ops.slot t.tx_ring id)
          ~packet
    
    | Backend ->
        Assemble.RX_IO.write_packet
          ~get_slot:(fun () ->
            let id = Ring_ops.next_req_id t.rx_ring in
            Ring_ops.slot t.rx_ring id)
          ~packet
  
  let notify_if_needed t =
    match t.kind with
      | Frontend ->
        if Ring_ops.push_and_check_notify t.tx_ring then begin
          (*Log.debug (fun f -> f "[%s.TX] Sending notification"
            (match t.kind with Frontend -> "Frontend" | Backend -> "Backend"));*)
          Xen_os.Eventchn.notify h t.evtchn
        end
      | Backend ->
        if Ring_ops.push_and_check_notify t.rx_ring then begin
          (*Log.debug (fun f -> f "[%s.TX] Sending notification"
            (match t.kind with Frontend -> "Frontend" | Backend -> "Backend"));*)
          Xen_os.Eventchn.notify h t.evtchn
        end
  
  let release_fragments _t _fragments = Lwt.return_unit
  let get_stats t = t.stats
end

module Unified_RX_Ops = struct
  (* type nonrec t = t *)
  
  let read_packets nf =
    match nf.t.kind with
    | Frontend ->
        Assemble.RX_IO.read_packets ~ack_fn:(Ring_ops.ack nf.t.rx_ring)
    | Backend ->
        Assemble.TX_IO.read_packets ~ack_fn:(Ring_ops.ack nf.t.tx_ring)
  
  (* Helper to clear a page (zero it out) *)
  external unsafe_fill_bigstring : Io_page.t -> int -> int -> int -> unit = "caml_fill_bigstring" [@@noalloc]
  
  let return_page nf page =
    (* Zero out the page before returning it to the pool for security *)
    unsafe_fill_bigstring page 0 Io_page.page_size 0;
    (* let before = List.length nf.t.free_pages in *)
    nf.t.free_pages <- page :: nf.t.free_pages;
    (* let after = List.length nf.t.free_pages in *)
    (* Log.debug (fun f -> f "[Frontend.RX] return_page: free_pages %d -> %d" before after); *)
    ()

  let get_page nf frag =
    match nf.t.kind with
    | Frontend ->
        let rx_map = Option.get nf.t.rx_map in
        let id = frag.Assemble.id in
        (* Log.debug (fun f -> f "[Frontend.RX] get_page: id=%d, free_pages=%d" id (List.length nf.t.free_pages)); *)
        
        let gref, page = Hashtbl.find rx_map id in
        let cs = Io_page.to_cstruct page in
        
        (* Copy the data BEFORE releasing the grant and returning the page *)
        let data_copy = Cstruct.sub_copy cs 0 (Cstruct.length cs) in
        
        Hashtbl.remove rx_map id;
        Export.end_access ~release_ref:true gref >>= fun () ->
        
        (* Return the page to the free pool for reuse *)
        return_page nf page;
        
        Lwt.return data_copy
    
    | Backend ->
        let gnt = {Import.domid = nf.t.peer_domid; ref = Gntref.of_int32 frag.Assemble.gref} in
        Import.with_mapping gnt ~writable:false (fun mapping ->
          let cs = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
          let cpy = Cstruct.sub_copy cs 0 (Cstruct.length cs) in
          
          (match nf.t.tx_ring with
           | Back_ring bring ->
               let slot = Ring.Rpc.Back.(slot bring (next_res_id bring)) in
               let resp = {TX.Response.id = frag.id; status = TX.Response.OKAY} in
               TX.Response.write resp slot
           | _ -> ());
          
          Lwt.return cpy
        ) >>= function
        | Error (`Msg m) -> Lwt.fail_with m
        | Ok page -> Lwt.return page
  
  let get_evtchn nf = nf.t.evtchn
  let get_stats nf = nf.t.stats
  
  let notify_if_needed nf =
    match nf.t.kind with
      | Frontend ->
        if Ring_ops.push_and_check_notify nf.t.rx_ring then begin
          (*Log.debug (fun f -> f "[%s.RX] Sending notification"
            (match nf.t.kind with Frontend -> "Frontend" | Backend -> "Backend"));*)
          Xen_os.Eventchn.notify h nf.t.evtchn
        end
      | Backend ->
        if Ring_ops.push_and_check_notify nf.t.tx_ring then begin
          (*Log.debug (fun f -> f "[%s.RX] Sending notification"
            (match nf.t.kind with Frontend -> "Frontend" | Backend -> "Backend"));*)
          Xen_os.Eventchn.notify h nf.t.evtchn
        end
  
  let post_receive nf =
    match nf.t.kind with
    | Frontend ->
        let rx_map = Option.get nf.t.rx_map in
        let free_slots = Ring_ops.get_free_slots nf.t.rx_ring in
        
        (* Log.debug (fun f -> f "[Frontend.RX] refill_requests: %d free slots available" free_slots); *)
        
        if free_slots > 0 then
          let available_pages = List.length nf.t.free_pages in
          let to_refill = min free_slots available_pages in
          (*Log.debug (fun f -> f "[Frontend.RX] refill_requests: have %d pages, will refill %d slots" 
            available_pages to_refill);*)
          
          if to_refill > 0 then
            nf.grant_ops.get_rx_grants nf.t to_refill >>= fun grants ->
            (* Log.debug (fun f -> f "[Frontend.RX] Got %d grants, adding to ring" (List.length grants)); *)
          
            List.iter (fun (gnt, page) ->
              let id = nf.t.rx_id in
              nf.t.rx_id <- (nf.t.rx_id + 1) mod 65536;
              Hashtbl.add rx_map id (gnt, page);
              let id = Ring_ops.next_req_id nf.t.rx_ring in
              let slot = Ring_ops.slot nf.t.rx_ring id in
              RX.Request.(write {RX.Request.id; gref = Gntref.to_int32 gnt}) slot
            ) grants;
            
            (* Log.debug (fun f -> f "[Frontend.RX] refill_requests: pushed %d requests" (List.length grants)); *)
            
            Lwt.return_unit
          else
            Lwt.return_unit
        else
          Lwt.return_unit
    
    | Backend -> Lwt.return_unit
end

(* ============================================================================
   PUBLIC API
   ============================================================================ *)

module Make(C: S.CONFIGURATION) = struct
  type error = Mirage_net.Net.error
  let pp_error = Mirage_net.Net.pp_error
  
  type nonrec t = t
  type nonrec transport = transport

  (** Set of active block devices *)
  let devices : (int, t) Hashtbl.t = Hashtbl.create 1

  let create_frontend ~vif_id ~backend_id ~mac ~mtu =
    Log.info (fun f -> f "[Frontend] Creating: id=%d domid=%d" vif_id backend_id);
    
    frontend_create_ring ~domid:backend_id ~idx_size:TX.total_size 
      (Printf.sprintf "Netif.TX.%d" vif_id) 
    >>= fun (tx_gnt, tx_ring, _tx_page) ->
    
    frontend_create_ring ~domid:backend_id ~idx_size:RX.total_size 
      (Printf.sprintf "Netif.RX.%d" vif_id) 
    >>= fun (rx_gnt, rx_ring, _rx_page) ->
    
    let evtchn = Xen_os.Eventchn.bind_unbound_port h backend_id in
    let evtchn_port = Xen_os.Eventchn.to_int evtchn in
    
    Log.info (fun f -> f "[Frontend] Event channel: %d" evtchn_port);
    
    Xen_os.Eventchn.unmask h evtchn;
    
    let grant_tx_page = Export.grant_access ~domid:backend_id ~writable:false in
    let tx_pool = Shared_page_pool.make grant_tx_page in
    
    let rx_map = Hashtbl.create 256 in
    let free_pages = Io_page.to_pages (Io_page.get 256) in
    let stats = Mirage_net.Stats.create () in

    let transport = {
      kind = Frontend;
      vif_id = vif_id;
      peer_domid = backend_id;
      mac; peer_mac = None; mtu;
      tx_ring; tx_gnt; tx_mutex = Lwt_mutex.create (); tx_pool = Some tx_pool;
      rx_ring; rx_gnt; rx_grants = None; rx_map = Some rx_map; rx_id = 0; free_pages;
      evtchn; stats;
    } in
    
    Log.info (fun f -> f "[Frontend] Transport created successfully");
    return transport
  
  let create_backend ~domid ~device_id ~frontend_mac ~mac ~mtu ~tx_ring_ref ~rx_ring_ref ~event_channel =
    Log.info (fun f -> f "[Backend] Creating: domid=%d device_id=%d" domid device_id);
    
    let frontend_id = domid in
    
    backend_import_ring ~domid:frontend_id ~gntref:(Gntref.of_int32 tx_ring_ref) 
      ~idx_size:TX.total_size "Netif.Backend.TX" true
    >>= fun (tx_ring, _tx_mapping) ->
    
    backend_import_ring ~domid:frontend_id ~gntref:(Gntref.of_int32 rx_ring_ref) 
      ~idx_size:RX.total_size "Netif.Backend.RX" true
    >>= fun (rx_ring, _rx_mapping) ->
    
    let channel = Xen_os.Eventchn.bind_interdomain h frontend_id (int_of_string event_channel) in
    
    Log.info (fun f -> f "[Backend] Bound to event channel: %s" event_channel);
    
    Xen_os.Eventchn.unmask h channel;
    
    let rx_grants = Lwt_dllist.create () in
    let stats = Mirage_net.Stats.create () in
    
    let transport = {
      kind = Backend;
      vif_id = device_id;
      peer_domid = frontend_id;
      mac; peer_mac = Some frontend_mac; mtu;
      tx_ring; tx_gnt = Gntref.of_int32 tx_ring_ref; tx_mutex = Lwt_mutex.create (); tx_pool = None;
      rx_ring; rx_gnt = Gntref.of_int32 rx_ring_ref; rx_grants = Some rx_grants; rx_map = None; rx_id = 0; free_pages = [];
      evtchn = channel; stats;
    } in
    
    Log.info (fun f -> f "[Backend] Transport created successfully");
    return transport
  
  let plug_frontend vif_id =
    let id = `Client vif_id in
    C.read_backend id >>= fun backend_conf ->
    let backend_id = backend_conf.S.backend_id in
    
    C.read_frontend_mac id >>= fun mac ->
    C.read_mtu id >>= fun mtu ->
    
    create_frontend ~vif_id ~backend_id ~mac ~mtu >>= fun transport ->
    
    let front_conf = { S.
      tx_ring_ref = Gntref.to_int32 transport.tx_gnt;
      rx_ring_ref = Gntref.to_int32 transport.rx_gnt;
      event_channel = string_of_int (Xen_os.Eventchn.to_int transport.evtchn);
      feature_requests = Features.supported;
    } in
    C.write_frontend_configuration id front_conf >>= fun () ->
    C.connect id >>= fun () ->
    
    C.wait_until_backend_connected backend_conf >>= fun () ->
    
    (* packets are dropped until listen is called *)
    Log.info (fun f -> f "[Frontend] Connected to backend");

    let get_tx_grants = fun _t _n -> return [] in
  
    let get_rx_grants = (fun t n ->
      (* Log.debug (fun f -> f "[Frontend.get_rx_grants] BEFORE: free_pages points to list with %d pages" (List.length t.free_pages)); *)
      
      if List.length t.free_pages < n then (
        Log.warn (fun f -> f "[Frontend] Not enough free pages for RX: need %d, have %d" 
          n (List.length t.free_pages));
        return []
      ) else (
        let to_grant, remaining = 
          let rec take acc n = function
            | [] -> (List.rev acc, [])
            | _ when n = 0 -> (List.rev acc, t.free_pages) (* TODO: really need to List.rev? *)
            | hd :: tl -> take (hd :: acc) (n - 1) tl
          in
          take [] n t.free_pages
        in
        t.free_pages <- remaining;
        (* Log.debug (fun f -> f "[Frontend.get_rx_grants] we consider now a grant list of %d pages and free_pages is %d pages" (List.length to_grant) (List.length t.free_pages)); *)
        
        Lwt_list.map_s (fun page ->
          Export.get () >>= fun gnt ->
          Export.grant_access ~domid:backend_id ~writable:true gnt page;
          return (gnt, page)
        ) to_grant
      )
    ) in
  
    let release_grant = (fun _t gnt -> Export.end_access ~release_ref:true gnt) in

    return {
      t = transport;
      l = Lwt_mutex.create ();
      c = Lwt_condition.create ();
      grant_ops = {get_tx_grants; get_rx_grants; release_grant; }
    }

  let connect id =
    (* If [id] is an integer, use it. Otherwise, return an error message
       which enumerates the available interfaces. *)
    let id' =
      try Some (int_of_string id) with _ -> None
    in
    match id' with
    | Some id' -> begin
        if Hashtbl.mem devices id' then
          return (Hashtbl.find devices id')
        else begin
          Log.info (fun f -> f "connect %d" id');
          plug_frontend id' >>= fun dev ->
          Hashtbl.add devices id' dev;
          return dev
        end
      end
    | None ->
      C.enumerate () >>= fun all ->
      let msg =
        Printf.sprintf "device %s not found (available = [ %s ])"
          id (String.concat ", " all)
      in
      Lwt.fail_with msg

  let make_backend ~domid ~device_id =
    let id = `Server (domid, device_id) in
    
    C.read_backend_mac id >>= fun mac ->
    C.read_frontend_mac id >>= fun frontend_mac ->
    C.init_backend id Features.supported >>= fun _backend_configuration(*TODO*) ->
    C.read_frontend_configuration id >>= fun f ->
    C.read_mtu id >>= fun mtu ->
    
    create_backend 
      ~domid ~device_id ~frontend_mac ~mac ~mtu 
      ~tx_ring_ref:f.S.tx_ring_ref 
      ~rx_ring_ref:f.S.rx_ring_ref 
      ~event_channel:f.S.event_channel
    >>= fun transport ->
    
    C.connect id >>= fun () ->
    
    Log.info (fun f -> f "[Backend] Connected to frontend");

    let get_tx_grants = (fun t n ->
      let rec take rx_grants acc = function
        | 0 -> return (List.rev acc)
        | n ->
            if Lwt_dllist.is_empty rx_grants then
              return (List.rev acc)
            else
              let req = Lwt_dllist.take_l rx_grants in
              let gnt = Gntref.of_int32 req.RX.Request.gref in
              let grant = {Import.domid; ref = gnt} in
              let mapping = Import.map_exn grant ~writable:true in
              let page = Import.Local_mapping.to_buf mapping |> Io_page.to_pages |> List.hd in
              take rx_grants ((gnt, page) :: acc) (n - 1)
      in
      match t.rx_grants with
      | Some rx_grants ->
        take rx_grants [] n
      | None -> Lwt.return []
    ) in
  
    let get_rx_grants = (fun _t _n -> return []) in
    let release_grant = (fun _t _gnt -> Lwt.return_unit) in

    return {
      t = transport;
      l = Lwt_mutex.create ();
      c = Lwt_condition.create ();
      grant_ops = {get_tx_grants; get_rx_grants; release_grant; }
    }

  let write nf ~size fillf =
    let data = Cstruct.create size in
    let len = fillf data in
    if len > size then failwith "length exceeds total size";
    let buf = Cstruct.sub data 0 len in
    Lwt_mutex.with_lock nf.t.tx_mutex (fun () ->
      let total_size = Cstruct.length buf in
      (* Log.debug (fun f -> f "[TX] write: starting, buf size=%d" total_size); *)
      Unified_TX_Ops.fragment_data nf.t buf >>= fun fragments ->
      let frags_only = List.map fst fragments in
      (* Log.debug (fun f -> f "[TX] Fragmented into %d fragments" (List.length fragments)); *)
      let packet = Assemble.{
        total_size;
        fragments = frags_only;
      } in
      (* Log.debug (fun f -> f "[TX] Writing packet to ring, total_size=%d" total_size); *)
      Unified_TX_Ops.write_packet_to_ring nf.t packet;
      (* Log.debug (fun f -> f "[TX] Notifying if needed"); *)
      Unified_TX_Ops.notify_if_needed nf.t;
      (* Log.debug (fun f -> f "[TX] Notification done, releasing fragments"); *)
      Stats.tx (Unified_TX_Ops.get_stats nf.t) (Int64.of_int total_size);
      Unified_TX_Ops.release_fragments nf.t fragments
    ) >|= fun () -> Ok ()

  let assemble_packet packet get_page_fn =
    let open Assemble in
    let data = Cstruct.create packet.total_size in
    let next = ref 0 in
    packet.fragments |> Lwt_list.iter_s (fun frag ->
      get_page_fn frag >>= fun buf ->
      Cstruct.blit buf frag.offset data !next frag.size;
      (* TODO: return page to free pool... *)
      next := !next + frag.size;
      Lwt.return_unit
    ) >|= fun () ->
    assert (!next = Cstruct.length data);
    data

  let rx_poll t callback =
    let packets = Unified_RX_Ops.read_packets t in
    (* Log.debug (fun f -> f "[RX] rx_poll: read %d packets" (List.length packets)); *)
    (* Process packets in parallel with Lwt.async, and track them with the lock semaphore
       so we can wait for completion before re-checking. *)
    packets |> List.iter (fun packet ->
      (* Launch callback in parallel *)
      Lwt.async (fun () ->
        Lwt.catch (fun () ->
          assemble_packet packet (Unified_RX_Ops.get_page t) >>= fun data ->
          Stats.rx (Unified_RX_Ops.get_stats t) (Int64.of_int packet.total_size);
          (* Log.debug (fun f -> f "[RX] Callback starting for packet size=%d" packet.total_size); *)
          (* Execute the callback *)
          callback data >>= fun () ->
          (* Log.debug (fun f -> f "[RX] Callback COMPLETED for packet size=%d" packet.total_size); *)
          Lwt.return_unit
        )
        (fun ex ->
          Log.err (fun f -> f "[RX] Callback FAILED with exception: %s" (Printexc.to_string ex));
           Lwt.return_unit
         )
      )
    );
    Lwt.return_unit

  let listen nf ~header_size:_(*TODO*) callback =
    let rec loop after =
      let evtchn = Unified_RX_Ops.get_evtchn nf in
      (* Process all available packets (launches callbacks with Lwt.async for performance) *)
      (* Log.debug (fun f -> f "[RX] Event received on evtchn %d, processing..."
        (Xen_os.Eventchn.to_int evtchn));*)
      rx_poll nf callback >>= fun () ->
      (* CRITICAL: We need to Wait for all callbacks to complete before continuing.
         This prevents the race condition where:
         1. Callbacks are still running
         2. We do the re-check too early
         3. We miss packets that were written during callback execution *)
      (* wait_for_callbacks () >>= fun () -> *)
      (* Post-processing (refill for frontend) *)
      Unified_RX_Ops.post_receive nf >>= fun () ->
      (* Log.debug (fun f -> f "[RX] post_receive done, notifying if needed"); *)
      Unified_RX_Ops.notify_if_needed nf;
      (* Now that callbacks have completed, check if new packets arrived 
         while we were processing. This handles the race condition. *)
      let new_packets = Unified_RX_Ops.read_packets nf in
      if List.length new_packets > 0 then begin
        (* Log.debug (fun f -> f "[RX] Found %d new packets after processing, re-polling immediately" (List.length new_packets)); *)
        loop after
      end else begin
        (*Log.debug (fun f -> f "[RX] No new packets, waiting for event on evtchn %d" 
          (Xen_os.Eventchn.to_int evtchn));*)
        Xen_os.Activations.after evtchn after >>= loop
      end
    in
    loop Xen_os.Activations.program_start
  
  let frontend_mac nf =
    match nf.t.peer_mac with
    | Some mac -> mac (* Only Backend has peer_mac *)
    | None -> nf.t.mac

  let mac nf = nf.t.mac
  let mtu nf = nf.t.mtu
  let get_stats_counters nf = nf.t.stats
  let reset_stats_counters nf = Mirage_net.Stats.reset nf.t.stats

  (* Unplug shouldn't block, although the Xen one might need to due
     to Xenstore? XXX *)
  let disconnect nf = 
    match nf.t.kind, nf.t.tx_pool with
    | Frontend, Some tx_pool ->
      Log.info (fun f -> f "disconnect");
      (* TODO: free pages still in [nf.t.rx_map] *)
      Shared_page_pool.shutdown tx_pool;
      Hashtbl.remove devices nf.t.vif_id;
      return ()
    | Frontend, None (* Should not exists, but we have an optional type *)
    | Backend, _ -> (* what we need to do here? If the Backend disconnects, the client will lose its network interface... *)
      failwith "disconnect"
end
