(*
 * Copyright (c) 2010-2013 Anil Madhavapeddy <anil@recoil.org>
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
open Printf
open OS
open Result

let return = Lwt.return

let allocate_ring ~domid =
  let page = Io_page.get 1 in
  let x = Io_page.to_cstruct page in
  Gnt.Gntshr.get ()
  >>= fun gnt ->
  for i = 0 to Cstruct.len x - 1 do
    Cstruct.set_uint8 x i 0
  done;
  Gnt.Gntshr.grant_access ~domid ~writable:true gnt page;
  return (gnt, x)

let create_ring ~domid ~idx_size name =
  allocate_ring ~domid
  >>= fun (rx_gnt, buf) ->
  let sring = Ring.Rpc.of_buf ~buf ~idx_size ~name in
  let fring = Ring.Rpc.Front.init ~sring in
  let client = Lwt_ring.Front.init string_of_int fring in
  return (rx_gnt, fring, client)

let create_rx (id, domid) = create_ring ~domid ~idx_size:RX.total_size (sprintf "Netif.RX.%d" id)
let create_tx (id, domid) = create_ring ~domid ~idx_size:TX.total_size (sprintf "Netif.TX.%d" id)

module Make(C: S.CONFIGURATION with type 'a io = 'a Lwt.t) = struct
  type 'a io = 'a Lwt.t
  type page_aligned_buffer = Io_page.t
  type buffer = Cstruct.t
  type macaddr = Macaddr.t

  (** IO operation errors *)
  type error = [
    | `Unknown of string (** an undiagnosed error *)
    | `Unimplemented     (** operation not yet implemented in the code *)
    | `Disconnected      (** the device has been previously disconnected *)
  ]

  type stats = Stats.t = {
    mutable rx_bytes : int64;
    mutable rx_pkts : int32;
    mutable tx_bytes : int64;
    mutable tx_pkts : int32;
  }

  type transport = {
    vif_id: int;
    backend_id: int;
    backend: string;      (* Path in XenStore *)
    mac: Macaddr.t;

    (* To transmit, we take half-pages from [Shared_page_pool], copy the data to them,
       and push the ref to the ring. *)
    tx_client: (TX.Response.t,int) Lwt_ring.Front.t;
    tx_gnt: Gnt.gntref;
    tx_mutex: Lwt_mutex.t; (* Held to avoid signalling between fragments *)
    tx_pool: Shared_page_pool.t;

    (* To receive, we share set of whole pages with the backend. We put the details of
       these grants in the rx_ring and wait to be notified that they've been used. *)
    rx_fring: (RX.Response.t,int) Ring.Rpc.Front.t;
    rx_client: (RX.Response.t,int) Lwt_ring.Front.t;
    rx_map: (int, Gnt.gntref * Io_page.t) Hashtbl.t;
    rx_gnt: Gnt.gntref;
    mutable rx_id: Cstruct.uint16;

    evtchn: Eventchn.t;
    features: Features.t;
    stats : stats;
  }

  type t = {
    mutable t: transport;
    mutable resume_fns: (t -> unit Lwt.t) list;
    l : Lwt_mutex.t;
    c : unit Lwt_condition.t;
  }

  type id = string

  let h = Eventchn.init ()

  (* Given a VIF ID, construct a netfront record for it *)
  let plug_inner vif_id =
    let id = `Client vif_id in
    (* Read details about the device *)
    C.read_backend id >>= fun backend_conf ->
    let backend_id = backend_conf.S.backend_id in
    Printf.printf "Netfront.create: id=%d domid=%d\n%!" vif_id backend_id;
    let features = backend_conf.S.features_available in
    Features.(Printf.printf " sg:%b gso_tcpv4:%b rx_copy:%b rx_flip:%b smart_poll:%b\n"
      features.sg features.gso_tcpv4 features.rx_copy features.rx_flip features.smart_poll);
    C.read_mac id >>= fun mac ->
    printf "MAC: %s\n%!" (Macaddr.to_string mac);
    (* Allocate a transmit and receive ring, and event channel *)
    create_rx (vif_id, backend_id)
    >>= fun (rx_gnt, rx_fring, rx_client) ->
    create_tx (vif_id, backend_id)
    >>= fun (tx_gnt, _tx_fring, tx_client) ->
    let tx_mutex = Lwt_mutex.create () in
    let evtchn = Eventchn.bind_unbound_port h backend_id in
    let evtchn_port = Eventchn.to_int evtchn in
    (* Write Xenstore info and set state to Connected *)
    let front_conf = { S.
      tx_ring_ref = Int32.of_int tx_gnt;
      rx_ring_ref = Int32.of_int rx_gnt;
      event_channel = string_of_int (evtchn_port);
      feature_requests = { Features.
        rx_copy = true;
        rx_flip = false;
        rx_notify = true;
        sg = true;
        gso_tcpv4 = false;
        smart_poll = false;
      };
    } in
    C.write_frontend_configuration id front_conf >>= fun () ->
    C.connect id >>= fun () ->
    (* Wait for backend to accept connection *)
    let rx_map = Hashtbl.create 51 in
    C.wait_until_backend_connected backend_conf >>= fun () ->
    Eventchn.unmask h evtchn;
    let stats = Stats.create () in
    let grant_tx_page = Gnt.Gntshr.grant_access ~domid:backend_id ~writable:false in
    let tx_pool = Shared_page_pool.make grant_tx_page in
    (* Register callback activation *)
    let backend = backend_conf.S.backend in
    return { vif_id; backend_id; tx_client; tx_gnt; tx_mutex; tx_pool;
             rx_gnt; rx_fring; rx_client; rx_map; rx_id = 0 ; stats;
             evtchn; mac; backend; features; 
           }

  (** Set of active block devices *)
  let devices : (int, t) Hashtbl.t = Hashtbl.create 1

  let notify nf () =
    Eventchn.notify h nf.evtchn

  let refill_requests nf =
    let num = Ring.Rpc.Front.get_free_requests nf.rx_fring in
    if num > 0 then
      Gnt.Gntshr.get_n num
      >>= fun grefs ->
      let pages = Io_page.pages num in
      List.iter
        (fun (gref, page) ->
           let rec next () =
             let id = nf.rx_id in
             nf.rx_id <- (succ nf.rx_id) mod (1 lsl 16) ;
             if Hashtbl.mem nf.rx_map id then next () else id
           in
           let id = next () in
           Gnt.Gntshr.grant_access ~domid:nf.backend_id ~writable:true gref page;
           Hashtbl.add nf.rx_map id (gref, page);
           let slot_id = Ring.Rpc.Front.next_req_id nf.rx_fring in
           let slot = Ring.Rpc.Front.slot nf.rx_fring slot_id in
           ignore(RX.Request.(write {id; gref = Int32.of_int gref}) slot)
        ) (List.combine grefs pages);
      if Ring.Rpc.Front.push_requests_and_check_notify nf.rx_fring
      then notify nf ();
      return ()
    else return ()

  let pop_rx_page nf id =
    let gref, page = Hashtbl.find nf.rx_map id in
    Hashtbl.remove nf.rx_map id;
    Gnt.Gntshr.end_access gref;
    Gnt.Gntshr.put gref;
    page

  let rx_poll nf fn =
    let module Recv = Assemble.Make(RX.Response) in
    MProf.Trace.label "Netchannel.Frontend.rx_poll";
    let q = ref [] in
    Ring.Rpc.Front.ack_responses nf.rx_fring (fun slot ->
      match RX.Response.read slot with
      | Error msg -> failwith msg
      | Ok req -> q := req :: !q
    );
    List.rev !q
    |> Recv.group_frames
    |> List.iter (function
      | Error (e, msgs) ->
          msgs |> List.iter (fun msg ->
            let _ : Io_page.t = pop_rx_page nf msg.RX.Response.id in
            ()
          );
          printf "Netif: received error: %d" e
      | Ok frame ->
          let data = Cstruct.create frame.Recv.total_size in
          let next = ref 0 in
          frame.Recv.fragments |> List.iter (fun {Recv.size; msg} ->
            let {RX.Response.id; size = _; flags = _; offset} = msg in
            let page = pop_rx_page nf id in
            let buf = Io_page.to_cstruct page in
            Cstruct.blit buf offset data !next size;
            next := !next + size
          );
          assert (!next = Cstruct.len data);
          Lwt.async (fun () ->
            Stats.rx nf.stats (Int64.of_int (Cstruct.len data));
            fn data
          )
    )

  let tx_poll nf =
    MProf.Trace.label "Netif.tx_poll";
    Lwt_ring.Front.poll nf.tx_client (fun slot ->
      let resp = TX.Response.read slot in
      (resp.TX.Response.id, resp)
    )

  let listen nf receive_callback =
    MProf.Trace.label "Netchannel.Frontend.listen";
    let rec loop from =
      rx_poll nf.t receive_callback;
      refill_requests nf.t >>= fun () ->
      tx_poll nf.t;
      Activations.after nf.t.evtchn from >>= fun from ->
      loop from
    in
    loop Activations.program_start

  let connect id =
    (* If [id] is an integer, use it. Otherwise, return an error message
       which enumerates the available interfaces. *)
    let id' =
      try Some (int_of_string id) with _ -> None
    in
    match id' with
    | Some id' -> begin
        if Hashtbl.mem devices id' then
          return (`Ok (Hashtbl.find devices id'))
        else begin
          printf "Netif.connect %d\n%!" id';
          Lwt.catch
          (fun () ->
            plug_inner id'
            >>= fun t ->
            let l = Lwt_mutex.create () in
            let c = Lwt_condition.create () in
            (* packets are dropped until listen is called *)
            let dev = { t; resume_fns=[]; l; c } in
            Hashtbl.add devices id' dev;
            return (`Ok dev)
          ) (fun exn ->
            return (`Error (`Unknown (Printexc.to_string exn))))
        end
      end
    | None ->
      C.enumerate () >>= fun all ->
      printf "Netif.connect %s: could not find device\n" id;
      return (`Error (`Unknown
                        (Printf.sprintf "device %s not found (available = [ %s ])"
                           id (String.concat ", " all))))

  (* Unplug shouldn't block, although the Xen one might need to due
     to Xenstore? XXX *)
  let disconnect t =
    printf "Netif: disconnect\n%!";
    (* TODO: free pages still in [t.rx_map] *)
    Shared_page_pool.shutdown t.t.tx_pool;
    Hashtbl.remove devices t.t.vif_id;
    return ()

  (* Push up to one page's worth of data to the ring, but without sending an
   * event notification. Once the data has been added to the ring, returns the
   * remaining (unsent) data and a thread which will return when the data has
   * been ack'd by netback. *)
  let write_request ?size ~flags nf datav =
    Shared_page_pool.use nf.t.tx_pool (fun ~id gref shared_block ->
      let len, datav = Cstruct.fillv ~src:datav ~dst:shared_block in
      (* [size] includes extra pages to follow later *)
      let size = match size with |None -> len |Some s -> s in
      Stats.tx nf.t.stats (Int64.of_int size);
      let request = { TX.Request.
        id;
        gref = Int32.of_int gref;
        offset = shared_block.Cstruct.off;
        flags;
        size
      } in
      Lwt_ring.Front.write nf.t.tx_client
          (fun slot -> TX.Request.write request slot; id)
      >>= fun replied ->
      (* request has been written; when replied returns we have a reply *)
      let release = replied >>= fun reply ->
        let open TX.Response in
        match reply.status with
        | DROPPED -> failwith "Netif: backend dropped our frame"
        | NULL -> failwith "Netif: NULL response"
        | ERROR -> failwith "Netif: ERROR response"
        | OKAY -> return () in
      return (datav, release)
    )

  (* Transmit a packet from buffer, with offset and length.
   * The buffer's data must fit in a single block. *)
  let write_already_locked nf datav =
    write_request ~flags:Flags.empty nf datav
    >>= fun (remaining, th) ->
    assert (Cstruct.lenv remaining = 0);
    Lwt_ring.Front.push nf.t.tx_client (notify nf.t);
    return th

  (* Transmit a packet from a list of pages *)
  let writev_no_retry nf datav =
    let size = Cstruct.lenv datav in
    let numneeded = Shared_page_pool.blocks_needed size in
    Lwt_mutex.with_lock nf.t.tx_mutex
      (fun () ->
         Lwt_ring.Front.wait_for_free nf.t.tx_client numneeded
         >>= fun () ->
         match numneeded with
         | 0 -> return (return ())
         | 1 ->
           (* If there is only one block, then just write it normally *)
           write_already_locked nf datav
         | n ->
           (* For Xen Netfront, the first fragment contains the entire packet
            * length, which the backend will use to consume the remaining
            * fragments until the full length is satisfied *)
           write_request ~flags:Flags.more_data ~size nf datav
           >>= fun (datav, first_th) ->
           let rec xmit datav = function
             | 0 -> return []
             | 1 ->
                 write_request ~flags:Flags.empty nf datav
                 >>= fun (datav, th) ->
                 assert (Cstruct.lenv datav = 0);
                 return [ th ]
             | n ->
                 write_request ~flags:Flags.more_data nf datav
                 >>= fun (datav, next_th) ->
                 xmit datav (n - 1)
                 >>= fun rest ->
                 return (next_th :: rest) in
           xmit datav (n - 1)
           >>= fun rest_th ->
           (* All fragments are now written, we can now notify the backend *)
           Lwt_ring.Front.push nf.t.tx_client (notify nf.t);
           return (Lwt.join (first_th :: rest_th))
      )

  let rec writev nf datav =
    Lwt.catch
      (fun () -> writev_no_retry nf datav)
      (function
       | Lwt_ring.Shutdown -> return (Lwt.fail Lwt_ring.Shutdown)
       | e -> Lwt.fail e)
    >>= fun released ->
    Lwt.on_failure released (function
      | Lwt_ring.Shutdown -> ignore (writev nf datav)
      | ex -> raise ex
    );
    return ()

  let write nf data = writev nf [data]

  let resume (id,t) =
    plug_inner id
    >>= fun transport ->
    let old_transport = t.t in
    t.t <- transport;
    Lwt_list.iter_s (fun fn -> fn t) t.resume_fns
    >>= fun () ->
    Lwt_mutex.with_lock t.l
        (fun () -> Lwt_condition.broadcast t.c (); return ())
    >>= fun () ->
    Lwt_ring.Front.shutdown old_transport.rx_client;
    Lwt_ring.Front.shutdown old_transport.tx_client;
    return ()

  let resume () =
    let devs = Hashtbl.fold (fun k v acc -> (k,v)::acc) devices [] in
    Lwt_list.iter_p (fun (k,v) -> resume (k,v)) devs

  (* The Xenstore MAC address is colon separated, very helpfully *)
  let mac nf = nf.t.mac

  let get_stats_counters t = t.t.stats

  let reset_stats_counters t = Stats.reset t.t.stats

  let () =
    printf "Netif: add resume hook\n%!";
    Sched.add_resume_hook resume
end
