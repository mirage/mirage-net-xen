(*
 * Copyright (c) 2010-2013 Anil Madhavapeddy <anil@recoil.org>
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

open Lwt.Infix

module Gntref = Xen_os.Xen.Gntref
module Export = Xen_os.Xen.Export

let src = Logs.Src.create "net-xen frontend" ~doc:"Mirage's Xen netfront"
module Log = (val Logs.src_log src : Logs.LOG)

let return = Lwt.return

let allocate_ring ~domid =
  let page = Io_page.get 1 in
  let x = Io_page.to_cstruct page in
  Export.get ()
  >>= fun gnt ->
  (* IO_page already returns a zeroed page, no need to write 0s *)
  Export.grant_access ~domid ~writable:true gnt page;
  return (gnt, x)

let create_ring ~domid ~idx_size name =
  allocate_ring ~domid
  >>= fun (gnt, buf) ->
  let sring = Ring.Rpc.of_buf ~buf ~idx_size ~name in
  let fring = Ring.Rpc.Front.init ~sring in
  let client = Lwt_ring.Front.init string_of_int fring in
  return (gnt, fring, client)

let create_rx (id, domid) =
  create_ring ~domid ~idx_size:RX.total_size (Printf.sprintf "Netif.RX.%d" id)
let create_tx (id, domid) =
  create_ring ~domid ~idx_size:TX.total_size (Printf.sprintf "Netif.TX.%d" id)

module Make(C: S.CONFIGURATION) = struct
  type error = Mirage_net.Net.error
  let pp_error = Mirage_net.Net.pp_error

  type transport = {
    vif_id: int;
    backend_id: int;
    backend: string;      (* Path in XenStore *)
    mac: Macaddr.t;
    mtu: int;

    (* To transmit, we take half-pages from [Shared_page_pool], copy the data to them,
       and push the ref to the ring. *)
    tx_fring: (TX.Response.t,int) Ring.Rpc.Front.t;
    tx_client: (TX.Response.t,int) Lwt_ring.Front.t;
    tx_gnt: Gntref.t;
    tx_mutex: Lwt_mutex.t;
    tx_pool: Shared_page_pool.t;

    (* To receive, we share set of whole pages with the backend. We put the details of
       these grants in the rx_ring and wait to be notified that they've been used. *)
    rx_fring: (RX.Response.t,int) Ring.Rpc.Front.t;
    rx_client: (RX.Response.t,int) Lwt_ring.Front.t;
    rx_map: (int, Gntref.t * Io_page.t) Hashtbl.t;
    rx_gnt: Gntref.t;
    mutable rx_id: Cstruct.uint16;
    mutable free_pages: Io_page.t list;

    evtchn: Xen_os.Eventchn.t;
    features: Features.t;
    stats : Mirage_net.stats;
  }

  type t = {
    mutable t: transport;
    l : Lwt_mutex.t;
    c : unit Lwt_condition.t;
  }

  let h = Xen_os.Eventchn.init ()

  (* Process TX responses to free up space in the TX ring *)
  let rec process_tx_responses nf =
    Ring.Rpc.Front.ack_responses nf.tx_fring (fun slot ->
      match TX.Response.read slot with
      | { TX.Response.id; status = TX.Response.OKAY } ->
          Log.debug (fun f -> f "[Frontend.TX] Response OK for id=%d" id)
      | { TX.Response.id; status } ->
          Log.warn (fun f -> f "[Frontend.TX] Response status=%s for id=%d" 
            (match status with
             | TX.Response.ERROR -> "ERROR"
             | TX.Response.DROPPED -> "DROPPED"
             | TX.Response.NULL -> "NULL"
             | TX.Response.OKAY -> "OKAY") id)
    )

  (* Given a VIF ID, construct a netfront record for it *)
  let plug_inner vif_id =
    let id = `Client vif_id in
    (* Read details about the device *)
    C.read_backend id >>= fun backend_conf ->
    let backend_id = backend_conf.S.backend_id in
    Log.info (fun f -> f "create: id=%d domid=%d" vif_id backend_id);
    let features = backend_conf.S.features_available in
    Log.info Features.(fun f -> f " sg:%b gso_tcpv4:%b rx_copy:%b rx_flip:%b smart_poll:%b"
      features.sg features.gso_tcpv4 features.rx_copy features.rx_flip features.smart_poll);
    C.read_frontend_mac id >>= fun mac ->
    Log.info (fun f -> f "MAC: %s" (Macaddr.to_string mac));
    (* Allocate a transmit and receive ring, and event channel *)
    create_rx (vif_id, backend_id)
    >>= fun (rx_gnt, rx_fring, rx_client) ->
    create_tx (vif_id, backend_id)
    >>= fun (tx_gnt, tx_fring, tx_client) ->
    let tx_mutex = Lwt_mutex.create () in
    let evtchn = Xen_os.Eventchn.bind_unbound_port h backend_id in
    let evtchn_port = Xen_os.Eventchn.to_int evtchn in
    (* Write Xenstore info and set state to Connected *)
    let front_conf = { S.
      tx_ring_ref = Gntref.to_int32 tx_gnt;
      rx_ring_ref = Gntref.to_int32 rx_gnt;
      event_channel = string_of_int evtchn_port;
      feature_requests = Features.supported;
    } in
    C.write_frontend_configuration id front_conf >>= fun () ->
    C.connect id >>= fun () ->
    (* Wait for backend to accept connection *)
    let rx_map = Hashtbl.create 1 in
    C.wait_until_backend_connected backend_conf >>= fun () ->
    Xen_os.Eventchn.unmask h evtchn;
    let stats = Stats.create () in
    let grant_tx_page = Export.grant_access ~domid:backend_id ~writable:false in
    let tx_pool = Shared_page_pool.make grant_tx_page in
    (* Register callback activation *)
    let backend = backend_conf.S.backend in
    C.read_mtu id >>= fun mtu ->
    return { vif_id; backend_id; tx_fring; tx_client; tx_gnt; tx_mutex; tx_pool;
             rx_gnt; rx_fring; rx_client; rx_map; rx_id = 0; stats;
             evtchn; mac; mtu; backend; features;
             free_pages = Io_page.to_pages (Io_page.get 256); (* Allocate 256*4kB=1MB of free_pages*)
           }

  (** Set of active block devices *)
  let devices : (int, t) Hashtbl.t = Hashtbl.create 1

  let notify nf () =
    Xen_os.Eventchn.notify h nf.evtchn

  let _take_pages t n =
    (* returns the first n elements of l, and l without them, assumes than l is long enough *)
    let rec split_list l n acc = match n, l with
        | 0, _ -> acc, l
        | n, [] -> failwith (Printf.sprintf "Frontend wants %d pages, this is too much, fail." n) (* We assume l is long enough *)
        | n, hd::tl -> split_list tl (n-1) (hd::acc)
    in
    let fp = t.free_pages in
    let pages, new_free_pages = split_list fp n [] in
    t.free_pages <- new_free_pages ;
    pages

  external unsafe_fill_bigstring : Io_page.t -> int -> int -> int -> unit = "caml_fill_bigstring" [@@noalloc]

  let _return_page t p =
    unsafe_fill_bigstring p 0 Io_page.page_size 0 ;
    t.free_pages <- p::t.free_pages

  let refill_requests nf =
    let num = Ring.Rpc.Front.get_free_requests nf.rx_fring in
    Log.debug (fun f -> f "[Frontend.RX] refill_requests: %d free slots available" num);
    if num > 0 then
      Export.get_n num
      >>= fun grefs ->
      Log.debug (fun f -> f "[Frontend.RX] Got %d grants, adding to ring" num);
      let pages = Io_page.to_pages (Io_page.get num) in (* TEMP: as we don't currently return pages, we need to allocate new pages each time *)
      List.iter
        (fun (gref, page) ->
           let rec next () =
             let id = nf.rx_id in
             nf.rx_id <- (succ nf.rx_id) mod (1 lsl 16);
             if Hashtbl.mem nf.rx_map id then next () else id
           in
           let id = next () in
           Export.grant_access ~domid:nf.backend_id ~writable:true gref page;
           Hashtbl.add nf.rx_map id (gref, page);
           let slot_id = Ring.Rpc.Front.next_req_id nf.rx_fring in
           let slot = Ring.Rpc.Front.slot nf.rx_fring slot_id in
           ignore(RX.Request.(write {id; gref = Gntref.to_int32 gref}) slot)
        ) (List.combine grefs pages);
      let should_notify = Ring.Rpc.Front.push_requests_and_check_notify nf.rx_fring in
      Log.debug (fun f -> f "[Frontend.RX] refill_requests: pushed %d requests, notify=%b" 
        num should_notify);
      if Ring.Rpc.Front.push_requests_and_check_notify nf.rx_fring
      then notify nf ();
      return ()
    else return ()

  (* returns the Cstruct based on the page from the fragment *)
  let pop_rx_page nf frag =
    let id = frag.Assemble.id in
    let gref, page = Hashtbl.find nf.rx_map id in
    let cs = Io_page.to_cstruct page in
    Hashtbl.remove nf.rx_map id;
    Export.end_access ~release_ref:true gref >>= fun () ->
    Lwt.return cs

  module Frontend_RX_Ops = struct
    type t = transport
    let read_packets nf =
      Assemble.RX_IO.read_packets 
        ~ack_fn:(Ring.Rpc.Front.ack_responses nf.rx_fring)
    let get_page nf frag = pop_rx_page nf frag
    let notify_if_needed nf =
      let should_notify = Ring.Rpc.Front.push_requests_and_check_notify nf.rx_fring in
      Log.debug (fun f -> f "[Frontend.RX] notify_if_needed: should_notify=%b" should_notify);
      
      if should_notify then begin
        Log.debug (fun f -> f "[Frontend.RX] Sending notification on evtchn %d" 
          (Xen_os.Eventchn.to_int nf.evtchn));
        notify nf ()
      end
    let get_evtchn nf = nf.evtchn
    let get_stats nf = nf.stats
    let post_receive nf = refill_requests nf
  end

  module Frontend_TX_Ops = struct
    type t = transport
    
    let fragment_data nf data =
      let size = Cstruct.length data in
      let numneeded = Shared_page_pool.blocks_needed size in
      let free_slots = Ring.Rpc.Front.get_free_requests nf.tx_fring in
      Log.debug (fun f -> f "[Frontend.TX] fragment_data: size=%d, need %d blocks, ring has %d free slots" 
        size numneeded free_slots);
      
      Lwt_ring.Front.wait_for_free nf.tx_client numneeded >>= fun () ->
      Log.debug (fun f -> f "[Frontend.TX] wait_for_free completed, proceeding with copy");
      
      let rec copy_to_pages datav offset acc_frags = function
        | 0 -> return (List.rev acc_frags)
        | n ->
            Shared_page_pool.use nf.tx_pool (fun ~id gref shared_block ->
              let len, datav' = Cstruct.fillv ~src:datav ~dst:shared_block in
              let frag = Assemble.{
                id;
                offset = shared_block.Cstruct.off;
                size = len;
                gref = Gntref.to_int32 gref;
              } in
            (* TODO: check return value... *)
              return ((datav', frag, Io_page.get 1), Lwt.return_unit)
            ) >>= fun ((datav', frag, page), _) ->
            copy_to_pages datav' (offset + frag.size) ((frag, page) :: acc_frags) (n - 1)
      in
      
      copy_to_pages [data] 0 [] numneeded
    
    let write_packet_to_ring nf packet =
      Assemble.TX_IO.write_packet
        ~get_slot:(fun () ->
          let slot_id = Ring.Rpc.Front.next_req_id nf.tx_fring in
          Ring.Rpc.Front.slot nf.tx_fring slot_id
        )
        ~packet
    
    let notify_if_needed nf =
      let should_notify = Ring.Rpc.Front.push_requests_and_check_notify nf.tx_fring in
      Log.debug (fun f -> f "[Frontend.TX] notify_if_needed: should_notify=%b" should_notify);
      
      if should_notify then begin
        Log.debug (fun f -> f "[Frontend.TX] Sending notification on evtchn %d" 
          (Xen_os.Eventchn.to_int nf.evtchn));
        notify nf ()
      end
    
    let release_fragments nf _fragments =
      (* CRITICAL: Process TX responses to free up ring space.
         Without this, the TX ring fills up and blocks forever. *)
      process_tx_responses nf;
      (* Check if there's now free space *)
      let free_slots = Ring.Rpc.Front.get_free_requests nf.tx_fring in
      Log.debug (fun f -> f "[Frontend.TX] After processing responses: %d free slots" free_slots);      
      Lwt.return_unit
    
    let get_stats nf = nf.stats
  end

  module Receiver = Netif_common.Make_Receiver(Frontend_RX_Ops)
  module Transmitter = Netif_common.Make_Transmitter(Frontend_TX_Ops)

  let write nf ~size fillf =
    let data = Cstruct.create size in
    let len = fillf data in
    if len > size then failwith "length exceeds total size" ;
    let buf = Cstruct.sub data 0 len in
    Lwt_mutex.with_lock nf.t.tx_mutex (fun () ->
      Transmitter.write nf.t buf
    ) >|= fun () -> Ok ()

  let listen nf ~header_size receive_callback =
    Receiver.listen nf.t ~header_size receive_callback

  (* The Xenstore MAC address is colon separated, very helpfully *)
  let mac nf = nf.t.mac
  let mtu nf = nf.t.mtu
  let get_stats nf = nf.t.stats
  let get_stats_counters t = get_stats t
  let reset_stats_counters t = Stats.reset (get_stats t)

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
          plug_inner id' >>= fun t ->
          let l = Lwt_mutex.create () in
          let c = Lwt_condition.create () in
          (* packets are dropped until listen is called *)
          let dev = { t; l; c } in
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

  (* Unplug shouldn't block, although the Xen one might need to due
     to Xenstore? XXX *)
  let disconnect t =
    Log.info (fun f -> f "disconnect");
    (* TODO: free pages still in [t.rx_map] *)
    Shared_page_pool.shutdown t.t.tx_pool;
    Hashtbl.remove devices t.t.vif_id;
    return ()
end
