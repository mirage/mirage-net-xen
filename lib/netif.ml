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
 *)

(*
 * Unified Xen network channel implementation for both frontend and backend.
 *
 * To future reader, here are some findings from the interface rewrite:
 * TX/RX naming is always from the Frontend perspective. The Frontend owns
 * all shared pages and allocates them; the Backend never allocates shared
 * memory and only temporarily maps Frontend pages via grant references.
 * 
 * I.e. there is two rings per connection:
 * - TX ring (Frontend POV):
 *     Frontend writes TX.Request (send to Backend)
 *     Backend  writes TX.Response
 * - RX ring (Frontend POV):
 *     Frontend writes RX.Request (grants to empty pages)
 *     Backend  writes RX.Response (data length after copy)
 * 
 * Frontend TX:
 *     Allocate pages from tx_pool, copy data, write TX.Request
 *     Must wait for TX.Response before reusing pages using promises
 * Backend TX (= Frontend RX):
 *     Wait for RX.Request grants, map writable, copy, unmap immediately,
 *     write RX.Response. No post-response wait required
 * Backend RX (= Frontend TX):
 *     Read TX.Request, map pages, process data, write TX.Response
 * 
 * We can distinguish Frontend from Backend with the logic:
 *     tx_pool = Some _ => Frontend
 *     tx_pool = None   => Backend
 * 
 * Flow control:
 *     Frontend TX waits for ring space + TX.Response
 *     Backend TX waits only for RX.Request grants
 *     Notifications via event channels (push_and_check_notify + activation)
 *)

open Lwt.Infix

module Gntref = Xen_os.Xen.Gntref
module Export = Xen_os.Xen.Export
module Import = Xen_os.Xen.Import

let src = Logs.Src.create "net-xen channel" ~doc:"Unified Xen network channel"
module Log = (val Logs.src_log src : Logs.LOG)

let return = Lwt.return

type 'a ring_side =
  | Front_ring of ('a, int) Ring.Rpc.Front.t * ('a, int) Lwt_ring.Front.t
  | Back_ring of ('a, int) Ring.Rpc.Back.t

type transport = {
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

let backend_get_n_grefs t n =
  let rx_grants = Option.get t.rx_grants in
  let rec take seq = function
    | 0 -> []
    | _n(*TODO*) when Lwt_dllist.is_empty seq -> []
    | n -> Lwt_dllist.take_l seq :: (take seq (n - 1))
  in
  
  let rec loop after =
    let n' = Lwt_dllist.length rx_grants in
    if n' >= n then return (take rx_grants n)
    else begin
      Ring_ops.ack t.rx_ring (fun slot ->
        let req = RX.Request.read slot in
        ignore(Lwt_dllist.add_r req rx_grants)
      );
      let new_n = Lwt_dllist.length rx_grants in
      if new_n <> n' then
        loop after
      else
        Xen_os.Activations.after t.evtchn after >>= loop
    end
  in
  loop Xen_os.Activations.program_start

module Unified_TX_Ops = struct
  let fragment_data t data =
    let size = Cstruct.length data in
    
    match t.tx_pool with
    | Some tx_pool -> (* Frontend *)
        let numneeded = Shared_page_pool.blocks_needed size in
        Ring_ops.wait_for_free t.tx_ring numneeded >>= fun () ->

        let rec copy_to_pages datav offset acc_frags = function
          | 0 -> return (List.rev acc_frags)
          | n ->
              Shared_page_pool.use tx_pool (fun ~id gref shared_block ->
                let len, datav' = Cstruct.fillv ~src:datav ~dst:shared_block in
                let frag = Assemble.{
                  id; offset = shared_block.Cstruct.off; size = len;
                  gref = Gntref.to_int32 gref;
                } in
                (match t.tx_ring with
                 | Front_ring (_, client) ->
                     let request = { TX.Request.id; gref = Gntref.to_int32 gref;
                                     offset = shared_block.Cstruct.off; flags = Flags.empty; size = len } in
                     Lwt_ring.Front.write client (fun slot ->
                       TX.Request.write request slot; id
                     ) >>= fun replied ->
                     let release = replied >|= fun _reply -> () in
                     return ((datav', frag), release)
                 | _ ->
                     return ((datav', frag), Lwt.return_unit))
              ) >>= fun ((datav', frag), release) ->
              copy_to_pages datav' (offset + frag.size) ((frag, release) :: acc_frags) (n - 1)
        in
        copy_to_pages [data] 0 [] numneeded
    
    | None -> (* Backend *)
        let pages_needed = max 1 @@ Io_page.round_to_page_size size / Io_page.page_size in
        backend_get_n_grefs t pages_needed >>= fun reqs ->

        let rec map_and_copy src offset acc_frags = function
          | [] -> return (List.rev acc_frags)
          | req :: rest ->
              let gnt = {Import.domid = t.peer_domid; ref = Gntref.of_int32 req.RX.Request.gref} in
              let mapping = Import.map_exn gnt ~writable:true in
              let dst = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in

              (* Do we need that or can we set to 0 only [size,Cstruct.length dst]? *)
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
              (match t.rx_ring with
               | Back_ring bring ->
                   let slot_id = Ring.Rpc.Back.next_res_id bring in
                   let slot = Ring.Rpc.Back.slot bring slot_id in
                   let resp = { RX.Response.id = req.RX.Request.id;
                                offset = 0;
                                flags = Flags.empty;
                                size = Ok to_copy } in
                   RX.Response.write resp slot
               | _ -> assert false);
              Import.Local_mapping.unmap_exn mapping;
              map_and_copy src (offset + to_copy) ((frag, Lwt.return_unit) :: acc_frags) rest
        in
        map_and_copy data 0 [] reqs

  let notify_if_needed t =
    match t.tx_pool with
    | Some _ -> (* Frontend *)
      (match t.tx_ring with
       | Front_ring (_, client) ->
           Lwt_ring.Front.push client (fun () -> Xen_os.Eventchn.notify h t.evtchn)
       | _ ->
         if Ring_ops.push_and_check_notify t.tx_ring then
           Xen_os.Eventchn.notify h t.evtchn
      )
    | None -> (* Backend *)
      if Ring_ops.push_and_check_notify t.rx_ring then
        Xen_os.Eventchn.notify h t.evtchn

  let release_fragments _t _fragments = Lwt.return_unit
  let get_stats t = t.stats
end

module Unified_RX_Ops = struct
  let read_packets nf =
    match nf.t.tx_pool with
    | Some _ -> (* Frontend *)
      let acked = ref 0 in
      let packets = Assemble.RX_IO.read_packets ~ack_fn:(fun f ->
        Ring_ops.ack nf.t.rx_ring (fun slot ->
          incr acked;
          f slot
        )
      ) in
      packets
    | None -> (* Backend *)
      let acked = ref 0 in
      let packets = Assemble.TX_IO.read_packets ~ack_fn:(fun f ->
        Ring_ops.ack nf.t.tx_ring (fun slot ->
          incr acked;
          f slot
        )
      ) in
      packets
  
  (* Helper to clear a page (zero it out) *)
  external unsafe_fill_bigstring : Io_page.t -> int -> int -> int -> unit = "caml_fill_bigstring" [@@noalloc]
  
  let return_page nf page =
    (* Zero out the page before returning it to the pool for security *)
    unsafe_fill_bigstring page 0 Io_page.page_size 0;
    nf.t.free_pages <- page :: nf.t.free_pages;
    ()

  let get_page nf frag =
    match nf.t.tx_pool with
    | Some _ -> (* Frontend *)
      let rx_map = Option.get nf.t.rx_map in
      let id = frag.Assemble.id in
      let gref, page = Hashtbl.find rx_map id in
      let cs = Io_page.to_cstruct page in
      (* Copy the data BEFORE releasing the grant and returning the page *)
      let data_copy = Cstruct.sub_copy cs 0 (Cstruct.length cs) in
      Hashtbl.remove rx_map id;
      Export.end_access ~release_ref:true gref >>= fun () ->
      (* Return the page to the free pool for reuse *)
      return_page nf page;
      Lwt.return data_copy

    | None -> (* Backend *)
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
    match nf.t.tx_pool with
    | Some _ -> (* Frontend *)
      if Ring_ops.push_and_check_notify nf.t.rx_ring then
        Xen_os.Eventchn.notify h nf.t.evtchn
    | None -> (* Backend *)
      if Ring_ops.push_and_check_notify nf.t.tx_ring then
        Xen_os.Eventchn.notify h nf.t.evtchn
  
  let post_receive nf =
    match nf.t.tx_pool with
    | Some _ -> (* Frontend *)
      let rx_map = Option.get nf.t.rx_map in
      let free_slots = Ring_ops.get_free_slots nf.t.rx_ring in
      if free_slots > 0 then
        let available_pages = List.length nf.t.free_pages in
        let to_refill = min free_slots available_pages in
        if to_refill > 0 then
          nf.grant_ops.get_rx_grants nf.t to_refill >>= fun grants ->
          List.iter (fun (gnt, page) ->
            let id = Ring_ops.next_req_id nf.t.rx_ring mod (1 lsl 16) in (* we have 1 page of grants IDs  *)
            let slot = Ring_ops.slot nf.t.rx_ring id in
            Hashtbl.add rx_map id (gnt, page);
            RX.Request.(write {RX.Request.id; gref = Gntref.to_int32 gnt}) slot
          ) grants;
          Lwt.return_unit
        else
          Lwt.return_unit
      else
        Lwt.return_unit

    | None -> (* Backend *)
      let rx_grants = Option.get nf.t.rx_grants in
      Ring_ops.ack nf.t.rx_ring (fun slot ->
        let req = RX.Request.read slot in
        ignore(Lwt_dllist.add_r req rx_grants)
      );
      Lwt.return_unit
end

module Make(C: S.CONFIGURATION) = struct
  type error = Mirage_net.Net.error
  let pp_error = Mirage_net.Net.pp_error
  
  type nonrec t = t

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
      if List.length t.free_pages < n then (
        Log.warn (fun f -> f "[Frontend] Not enough free pages for RX: need %d, have %d" 
          n (List.length t.free_pages));
        return []
      ) else (
        let to_grant, remaining = 
          let rec take acc n = function
            | [] -> (acc, [])
            | _ when n = 0 -> (acc, t.free_pages)
            | hd :: tl -> take (hd :: acc) (n - 1) tl
          in
          take [] n t.free_pages
        in
        t.free_pages <- remaining;
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
      Unified_TX_Ops.fragment_data nf.t buf >>= fun fragments ->
      let releases = List.map (fun (_, release) -> release) fragments in
      Unified_TX_Ops.notify_if_needed nf.t;
      Stats.tx (Unified_TX_Ops.get_stats nf.t) (Int64.of_int total_size);
      (* Wait for all TX responses before releasing (Frontend only) *)
      (match nf.t.tx_pool with
       | Some _ -> (* Frontend *)
         (* Don't block - release in background to avoid init deadlock *)
         Lwt.async (fun () ->
           Lwt.join releases >>= fun () ->
           Unified_TX_Ops.release_fragments nf.t []
         );
         Lwt.return ()
       | None -> (* Backend *)
         Unified_TX_Ops.release_fragments nf.t []
      )
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

  let rx_poll nf callback =
    let packets = Unified_RX_Ops.read_packets nf in
    (* Process packets sequentially, launch callback async AFTER (like legacy) *)
    packets |> Lwt_list.iter_s (fun packet ->
      Lwt.catch (fun () ->
        (* Assemble packet - pages returned HERE *)
        assemble_packet packet (Unified_RX_Ops.get_page nf) >>= fun data ->
        Stats.rx (Unified_RX_Ops.get_stats nf) (Int64.of_int packet.total_size);
        (* Pages now free - launch callback async *)
        Lwt.async (fun () -> callback data);
        Lwt.return_unit
      ) (fun ex ->
        Log.err (fun f -> f "[%s-RX] Callback FAILED with exception: %s" (match nf.t.tx_pool with | Some _ -> "Frontend" | None -> "Backend") (Printexc.to_string ex));
        Lwt.return_unit
         )
      )

  let listen nf ~header_size:_(*TODO*) callback =
    let rec loop after =
      let evtchn = Unified_RX_Ops.get_evtchn nf in
      rx_poll nf callback >>= fun () ->
      Unified_RX_Ops.post_receive nf >>= fun () ->
      Unified_RX_Ops.notify_if_needed nf;
      (match nf.t.tx_ring with
       | Front_ring (_fring, client) ->
           Lwt_ring.Front.poll client (fun slot ->
             let resp = TX.Response.read slot in
             (resp.TX.Response.id, resp))
       | _ -> ());
      Xen_os.Activations.after evtchn after >>= loop
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
    match nf.t.tx_pool with
    | Some tx_pool ->
      Log.info (fun f -> f "disconnect");
      (* TODO: free pages still in [nf.t.rx_map] *)
      Shared_page_pool.shutdown tx_pool;
      Hashtbl.remove devices nf.t.vif_id;
      return ()
    | None ->
      failwith "disconnect"
end
