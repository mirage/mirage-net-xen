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

(* One implementation for both ends of a Xen network channel.

   TX and RX are named from the frontend's point of view throughout, so the
   backend receives on TX and transmits on RX. The frontend owns every shared
   page; the backend allocates none and reaches them through grants. That
   asymmetry is what [ending] distinguishes. *)

open Lwt.Infix

let src = Logs.Src.create "net-xen channel" ~doc:"mirage-net-xen.netif"
module Log = (val Logs.src_log src : Logs.LOG)

exception Netback_shutdown

(* NETIF_RSP_ERROR: the response slot could not be filled and the peer must
   discard the frame. *)
let netif_rsp_error = -1

type ending =
  | Front of {
      tx_pool: Shared_page_pool.t ;
      rx_map: (int, Xen_os.Xen.Gntref.t * Io_page.t) Hashtbl.t ;
      tx_ring : (TX.Response.t, int) Ring.Rpc.Front.t * (TX.Response.t, int) Lwt_ring.Front.t ;
      rx_ring : (RX.Response.t, int) Ring.Rpc.Front.t * (RX.Response.t, int) Lwt_ring.Front.t ;
    }
  | Back of {
      peer_mac: Macaddr.t ;
      rx_grants: RX.Request.t Lwt_dllist.t ;
      tx_ring : (TX.Response.t, int) Ring.Rpc.Back.t ;
      rx_ring : (RX.Response.t, int) Ring.Rpc.Back.t ;
      (* Page aligned scratch for the transmit path. A grant copy names each
         endpoint as a frame plus an offset, so the local source has to be page
         aligned, which Cstruct.create does not promise. Reused across frames,
         so unlike a fresh Io_page it does not arrive zeroed and must be
         cleared: the marshallers expect zeroed memory. Only touched under
         tx_mutex. *)
      tx_scratch: Io_page.t ;
      (* The mirror of tx_scratch, where a received fragment lands. It needs no
         clearing: frag.size bytes go in and exactly those come out. *)
      rx_scratch: Io_page.t ;
    }

(* Cheap counters for working out where the per-packet cost goes. Only integer
   increments happen on the packet path; the summary is emitted on a timer, so
   this must not become another hot-path logger. *)
type counters = {
  mutable polls: int;          (* listen iterations *)
  mutable rx_frames: int;
  mutable rx_fragments: int;
  mutable rx_dropped: int;
  mutable tx_frames: int;
  mutable tx_fragments: int;
  mutable reported_at: int;    (* rx_frames + tx_frames at the last summary *)
  (* Time spent inside grant hypercalls, which only the backend performs.
     grant_access on the frontend is a plain grant table write and costs
     nothing comparable, so it is not counted. *)
  mutable grant_ns: int64;
  mutable grant_ops: int;
  mutable last_ns: int64;      (* clock at the last summary, for exact rates *)
}

(* On a timer rather than every N frames, so the counters keep coming when
   throughput collapses, which is exactly when they are wanted. *)
let report_interval_ns = 1_000_000_000L

(* solo5_clock_monotonic, already linked in by mirage-xen's clock_stubs.c. Not
   re-exported through Xen_os, hence the direct declaration. *)
external monotonic_ns : unit -> int64 = "caml_get_monotonic_time"

let new_counters () = {
  polls = 0; rx_frames = 0; rx_fragments = 0; rx_dropped = 0;
  tx_frames = 0; tx_fragments = 0; reported_at = 0;
  grant_ns = 0L; grant_ops = 0; last_ns = monotonic_ns ();
}

(* Charge the time since [before] to the grant total. Call sites read the clock
   themselves rather than passing a closure, so nothing is allocated here. *)
let account_grant c ~before ~ops =
  c.grant_ns <- Int64.add c.grant_ns (Int64.sub (monotonic_ns ()) before);
  c.grant_ops <- c.grant_ops + ops

type transport = {
  vif_id: int;
  peer_domid: int;
  mac: Macaddr.t;
  mtu: int;

  tx_gnt: Xen_os.Xen.Gntref.t;
  tx_mutex: Lwt_mutex.t;

  rx_gnt: Xen_os.Xen.Gntref.t;
  mutable rx_id: int;
  mutable free_pages: Io_page.t list;

  evtchn: Xen_os.Eventchn.t;
  stats: Mirage_net.stats;
  counters: counters;
  (* Set once the rings have been unmapped. The backend rings are the peer's
     pages and touching them after that is a use after free. *)
  mutable closed: bool;
  ending : ending;
}

type t = {
  mutable t: transport;
  l: Lwt_mutex.t;
  c: unit Lwt_condition.t;
  (* Only the frontend has anything to do here: it owns the pages behind the
     receive ring and grants fresh ones as the ring is refilled. *)
  get_rx_grants: transport -> int -> (Xen_os.Xen.Gntref.t * Io_page.t) list Lwt.t;
}

let check_open t = if t.closed then raise Netback_shutdown

module Cleanup : sig
  type t
  (** A stack of (cleanup) actions to perform.
      This is a bit like [Lwt_switch], but ensures things happen in order. *)

  val create : unit -> t

  val push : t -> (unit -> unit Lwt.t) -> unit
  (** [push t fn] adds [fn] to the stack of clean-up operations to perform. *)

  val perform : t -> unit Lwt.t
  (** [perform t] pops and performs actions from the stack until it is empty. *)
end = struct
  type t = (unit -> unit Lwt.t) Stack.t

  let create = Stack.create

  let push t fn = Stack.push fn t

  let rec perform t =
    if Stack.is_empty t then Lwt.return_unit
    else (
      let fn = Stack.pop t in
      fn () >>= fun () ->
      perform t
    )
end

let h = Xen_os.Eventchn.init ()

let frontend_allocate_ring ~domid =
  let page = Io_page.get 1 in
  let x = Io_page.to_cstruct page in
  Xen_os.Xen.Export.get () >>= fun gnt ->
  Cstruct.memset x 0;
  Xen_os.Xen.Export.grant_access ~domid ~writable:true gnt page;
  Lwt.return (gnt, x)

let frontend_create_ring ~domid ~idx_size name =
  frontend_allocate_ring ~domid >>= fun (gnt, buf) ->
  let sring = Ring.Rpc.of_buf ~buf ~idx_size ~name in
  let fring = Ring.Rpc.Front.init ~sring in
  let client = Lwt_ring.Front.init string_of_int fring in
  Lwt.return (gnt, (fring, client))

let backend_import_ring ~domid ~gntref ~idx_size name writable =
  let grant = {Xen_os.Xen.Import.domid; ref = gntref} in
  let mapping = Xen_os.Xen.Import.map_exn grant ~writable in
  let buf = Xen_os.Xen.Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
  let sring = Ring.Rpc.of_buf_no_init ~buf ~idx_size ~name in
  let bring = Ring.Rpc.Back.init ~sring in
  Lwt.return (bring, mapping)

(* Collect [n] receive requests the peer has posted, waiting on the event
   channel for more if it has not posted enough yet. *)
let backend_get_n_grefs t rx_ring rx_grants n =
  (* Bind the head before recursing. OCaml evaluates the arguments of a
     constructor right to left, so [take_l seq :: take seq (n - 1)] drains the
     queue from the far end first and hands the requests back reversed. The peer
     pairs a response with a request by ring position alone. *)
  let rec take seq = function
    | 0 -> []
    | n ->
        let head = Lwt_dllist.take_l seq in
        head :: take seq (n - 1)
  in

  let rec loop after =
    check_open t;
    let n' = Lwt_dllist.length rx_grants in
    if n' >= n then Lwt.return (take rx_grants n)
    else begin
      Ring.Rpc.Back.ack_requests rx_ring (fun slot ->
        let req = RX.Request.read slot in
        ignore(Lwt_dllist.add_r req rx_grants)
      );
      if Lwt_dllist.length rx_grants <> n'
      then loop after
      else Xen_os.Activations.after t.evtchn after >>= loop
    end
  in
  loop Xen_os.Activations.program_start

module Unified_TX_Ops = struct
  (* Frame lengths count this, mtu does not. The two are not interchangeable. *)
  let ethernet_header_size = 14

  (* The peer answers every transmit request, and a status other than OKAY means
     the frame did not go out. *)
  let check_reply replied =
    replied >>= fun reply ->
    let open TX.Response in
    match reply.status with
    | DROPPED -> failwith "Netif: backend dropped our frame"
    | NULL -> failwith "Netif: NULL response"
    | ERROR -> failwith "Netif: ERROR response"
    | OKAY -> Lwt.return_unit

  (* Split [data] over as many ring slots as it needs, and describe each one to
     the peer. Returns the fragments, each paired with a thread that completes
     once the peer has answered for it. *)
  let fragment_data t ?src_page data =
    let size = Cstruct.length data in
    match t.ending with
    | Front { tx_pool ; tx_ring = (_, client) ; _ } -> (* Frontend *)
        let nfrags = Shared_page_pool.blocks_needed size in
        Lwt_ring.Front.wait_for_free client nfrags >>= fun () ->

        let rec copy_to_pages datav is_first acc_frags = function
          | 0 -> Lwt.return (List.rev acc_frags)
          | n ->
              Shared_page_pool.use tx_pool (fun ~id gref shared_block ->
                let len, datav' = Cstruct.fillv ~src:datav ~dst:shared_block in
                let frag = Assemble.{
                  id; offset = shared_block.Cstruct.off; size = len;
                  gref = Xen_os.Xen.Gntref.to_int32 gref;
                } in
                let has_more = n > 1 in
                (* The first request announces the whole frame, the others
                   their own fragment. *)
                let request_size = if is_first && nfrags > 1 then size else len in
                let flags = if has_more then Flags.more_data else Flags.empty in
                let request = { TX.Request.id; gref = Xen_os.Xen.Gntref.to_int32 gref;
                                offset = shared_block.Cstruct.off; flags;
                                size = request_size; extras = [] } in
                Lwt_ring.Front.write client (fun slot ->
                    TX.Request.write request slot; id
                  ) >>= fun replied ->
                Lwt.return ((datav', frag), check_reply replied))
              >>= fun ((datav', frag), release) ->
              copy_to_pages datav' false ((frag, release) :: acc_frags) (n - 1)
        in
        copy_to_pages [data] true [] nfrags

    | Back { rx_grants ; rx_ring ; _ } -> (* Backend *)
        let src_page =
          match src_page with
          | Some page -> page
          | None ->
              (* write always hands the backend a page aligned buffer. *)
              invalid_arg
                "Netif.fragment_data: the backend needs a page aligned source"
        in
        let pages_needed = max 1 @@ Io_page.round_to_page_size size / Io_page.page_size in
        backend_get_n_grefs t rx_ring rx_grants pages_needed >>= fun reqs ->

        let rec copy_to_peer offset acc_frags = function
          | [] -> return (List.rev acc_frags)
          | req :: rest ->
              let to_copy = min Io_page.page_size (size - offset) in
              (* One hypercall where map, copy and unmap took two plus the page
                 table work. Both endpoints stay inside one page: the source is
                 aligned and offset advances a page at a time. *)
              let before = monotonic_ns () in
              let copied =
                Xen_os.Xen.Import.copy_to
                  ~src:src_page ~src_off:(data.Cstruct.off + offset)
                  ~domid:t.peer_domid
                  ~gref:(Xen_os.Xen.Gntref.of_int32 req.RX.Request.gref)
                  ~dst_off:0 ~len:to_copy
              in
              account_grant t.counters ~before ~ops:1;
              (* A refused copy leaves the peer's page holding whatever was
                 there, so announcing to_copy bytes would hand it a stale frame.
                 Report the failure instead. *)
              let resp_size =
                match copied with
                | Ok () -> Ok to_copy
                | Error (`Msg m) ->
                    Log.err (fun f ->
                        f "[Backend-TX] grant copy failed for id %d: %s"
                          req.RX.Request.id m);
                    Error netif_rsp_error
              in

              let frag = Assemble.{
                id = req.RX.Request.id; offset = 0; size = to_copy;
                gref = req.RX.Request.gref;
              } in
              let has_more = (rest <> []) in
              let flags = if has_more then Flags.more_data else Flags.empty in

              let slot = Ring.Rpc.Back.(slot rx_ring (next_res_id rx_ring)) in
              (* Each RX response carries the size of its own fragment. *)
              let resp = { RX.Response.id = req.RX.Request.id; offset = 0;
                           flags; size = resp_size; extras = [] } in
              RX.Response.write resp slot
              copy_to_peer (offset + to_copy) ((frag, Lwt.return_unit) :: acc_frags) rest
        in
        copy_to_peer 0 [] reqs

  (* Fast path for a frame that fits in a single pool block: let the caller fill
     the shared block rather than fill a private buffer and copy it in. At an
     MTU of 1500 every frame takes this path. *)
  let write_single_block t ~size fillf =
    match t.ending with
    | Front { tx_pool ; tx_ring = _, client ; _ } ->
        Lwt_ring.Front.wait_for_free client 1 >>= fun () ->
        Shared_page_pool.use tx_pool (fun ~id gref shared_block ->
          (* Blocks are recycled and the whole page is granted to the peer, so
             what the previous frame left behind would otherwise be readable by
             it. The marshallers also assume zeroed memory. *)
          Cstruct.memset shared_block 0;
          let len = fillf (Cstruct.sub shared_block 0 size) in
          if len > size then failwith "length exceeds size";
          let frag = Assemble.{
            id; offset = shared_block.Cstruct.off; size = len;
            gref = Xen_os.Xen.Gntref.to_int32 gref;
          } in
          let request = { TX.Request.id; gref = Xen_os.Xen.Gntref.to_int32 gref;
                          offset = shared_block.Cstruct.off;
                          flags = Flags.empty; size = len; extras = [] } in
          Lwt_ring.Front.write client (fun slot ->
              TX.Request.write request slot; id
            ) >>= fun replied ->
          Lwt.return ((len, frag), check_reply replied)
          ) >|= fun ((len, frag), release) ->
        (len, [ (frag, release) ])
    | Back _ -> assert false (* guarded by the caller *)

  let notify_if_needed t =
    match t.ending with
    | Front { tx_ring = _, client ; _ } -> (* Frontend *)
      Lwt_ring.Front.push client (fun () -> Xen_os.Eventchn.notify h t.evtchn)
    | Back { rx_ring ; _ } -> (* Backend *)
      if Ring.Rpc.Back.push_responses_and_check_notify rx_ring then
        Xen_os.Eventchn.notify h t.evtchn

end

module Unified_RX_Ops = struct
  let read_packets nf =
    check_open nf.t;
    match nf.t.ending with
    | Front { rx_ring = ring, _ ; _}  -> (* Frontend reads responses on RX *)
      let ack_fn = Ring.Rpc.Front.ack_responses ring in
      Assemble.RX_IO.read_packets ~ack_fn ~with_extras:Features.supported.gso_tcpv4
    | Back { tx_ring ; _ } -> (* Backend reads requests on TX *)
      let ack_fn = Ring.Rpc.Back.ack_requests tx_ring in
      Assemble.TX_IO.read_packets ~ack_fn ~with_extras:Features.supported.gso_tcpv4

  external unsafe_fill_bigstring : Io_page.t -> int -> int -> int -> unit
    = "caml_fill_bigstring" [@@noalloc]

  (* Zero a page before it can be granted to the peer again. *)
  let return_page nf page =
    unsafe_fill_bigstring page 0 Io_page.page_size 0;
    nf.t.free_pages <- page :: nf.t.free_pages

  (* Release what is behind a packet we are not going to deliver. Otherwise an
     error response leaks its page on the frontend, and leaves the peer waiting
     for an acknowledgement on the backend. *)
  let discard_fragments nf frags =
    match nf.t.ending with
    | Front { rx_map ; _ } -> (* Frontend: the pages are ours, take them back *)
      frags |> Lwt_list.iter_s (fun frag ->
        let id = frag.Assemble.id in
        match Hashtbl.find_opt rx_map id with
        | None ->
          Log.warn (fun f -> f "[Frontend-RX] No page registered for id %d" id);
          Lwt.return_unit
        | Some (gref, page) ->
          Hashtbl.remove rx_map id;
          Xen_os.Xen.Export.end_access ~release_ref:true gref >|= fun () ->
          return_page nf page)
    | Back { tx_ring ; _ } -> (* Backend: answer so the peer can reuse its blocks *)
      List.iter (fun frag ->
          let slot = Ring.Rpc.Back.(slot tx_ring (next_res_id tx_ring)) in
          TX.Response.write
            { TX.Response.id = frag.Assemble.id; status = TX.Response.ERROR } slot)
        frags;
      Lwt.return_unit

  (* A descriptor occupies a ring slot without carrying data, so it never becomes
     a fragment and nothing on the assembly path accounts for it. Both roles owe
     something for that slot and neither is optional.

     As a frontend, the slot was one of our requests, so a page of ours is behind
     it and nothing will ask for that page again: hand it back, or the pool
     drains by one per aggregated frame until the ring can no longer be refilled.

     As a backend, the slot belongs to the peer, which attached no resource to
     it, but it is only returned once our response index passes it. Leave that
     undone and the peer's transmit ring fills up and it stops sending. A NULL
     status is what says "nothing here". *)
  let release_extra_slots nf ids =
    match nf.t.tx_pool with
    | Some _ -> (* Frontend: the page is ours *)
      let rx_map = Option.get nf.t.rx_map in
      ids |> Lwt_list.iter_s (fun id ->
        match Hashtbl.find_opt rx_map id with
        | None ->
          Log.warn (fun f -> f "[Frontend-RX] no page for descriptor slot %d" id);
          Lwt.return_unit
        | Some (gref, page) ->
          Hashtbl.remove rx_map id;
          Export.end_access ~release_ref:true gref >|= fun () ->
          return_page nf page)
    | None -> (* Backend: only the slot, answered so the peer reclaims it *)
      List.iter (fun _id ->
        match nf.t.tx_ring with
        | Back_ring bring ->
          let slot = Ring.Rpc.Back.(slot bring (next_res_id bring)) in
          TX.Response.write
            { TX.Response.id = 0; status = TX.Response.NULL } slot
        | _ -> ()) ids;
      Lwt.return_unit

  (* [read] is handed the page the fragment sits in and must take what it needs
     before this returns, since the page goes back to the pool or the mapping is
     torn down straight after. That is what keeps the fragment from having to be
     copied to a buffer of its own first. *)
  let with_page nf frag read =
    match nf.t.ending with
    | Front { rx_map ; _ } -> (* Frontend: the page is ours, found from the id *)
      let id = frag.Assemble.id in
      (match Hashtbl.find_opt rx_map id with
       | None ->
         Log.err (fun f -> f "[Frontend-RX] No page registered for id %d" id);
         Lwt.fail_with (Printf.sprintf "Netif: no RX page registered for id %d" id)
       | Some (gref, page) ->
         read (Io_page.to_cstruct page);
         Hashtbl.remove rx_map id;
         Xen_os.Xen.Export.end_access ~release_ref:true gref >|= fun () ->
         return_page nf page)

    | Back { tx_ring ; rx_scratch ; _ } -> (* Backend: the page is the peer's, reached through its grant *)
      let before = monotonic_ns () in
      (* Only frag.size bytes move, where the mapping cost a whole page plus the
         page table work. It lands at the offset it had in the peer's page, so
         the caller reads it exactly where it would have. *)
      let copied =
        Xen_os.Xen.Import.copy_from ~domid:nf.t.peer_domid
          ~gref:(Xen_os.Xen.Gntref.of_int32 frag.Assemble.gref)
          ~src_off:frag.Assemble.offset ~dst:scratch
          ~dst_off:frag.Assemble.offset ~len:frag.Assemble.size
      in
      account_grant nf.t.counters ~before ~ops:1;
      (match copied with
        | Ok () -> read (Io_page.to_cstruct scratch)
        | Error _ -> ());
      (* Answer either way, so the peer can reuse the block whether or not we
         managed to read it. *)
      let slot = Ring.Rpc.Back.(slot tx_ring (next_res_id tx_ring)) in
      let status =
        match copied with Ok () -> TX.Response.OKAY | Error _ -> TX.Response.ERROR in
      TX.Response.write {TX.Response.id = frag.Assemble.id; status} slot
      (match copied with
        | Error (`Msg m) -> Lwt.fail_with m
        | Ok () -> Lwt.return_unit)

  let notify_if_needed nf =
    match nf.t.ending with
    | Front { rx_ring = ring, _ ; _ } -> (* Frontend pushes its refilled RX requests *)
      if Ring.Rpc.Front.push_requests_and_check_notify ring then
        Xen_os.Eventchn.notify h nf.t.evtchn
    | Back { tx_ring ; _ } -> (* Backend pushes the TX responses it just wrote *)
      if Ring.Rpc.Back.push_responses_and_check_notify tx_ring then
        Xen_os.Eventchn.notify h nf.t.evtchn

  (* Frontend: hand the peer more pages to fill. Backend: bank the requests the
     peer has posted, so a later write has grants to copy into. *)
  let post_receive nf =
    match nf.t.ending with
    | Front { rx_map ; rx_ring = ring, _ ; _ } ->
      let free_slots = Ring.Rpc.Front.get_free_requests ring in
      (* Bounded by both: a slot with no page behind it is a promise we cannot
         keep, and a page with no slot has nowhere to go. *)
      let to_refill = min free_slots (List.length nf.t.free_pages) in
      if to_refill <= 0 then Lwt.return_unit
      else
        nf.get_rx_grants nf.t to_refill >>= fun grants ->
        List.iter (fun (gnt, page) ->
          (* The id is ours to choose and is only sixteen bits wide, so skip any
             the peer has not answered for yet. *)
          let rec next () =
            let id = nf.t.rx_id in
            nf.t.rx_id <- (succ nf.t.rx_id) mod (1 lsl 16);
            if Hashtbl.mem rx_map id then next () else id
          in
          let id = next () in
          let slot = Ring.Rpc.Front.slot ring (Ring.Rpc.Front.next_req_id ring) in
          Hashtbl.add rx_map id (gnt, page);
          RX.Request.(write {RX.Request.id; gref = Xen_os.Xen.Gntref.to_int32 gnt}) slot
        ) grants;
        Lwt.return_unit
    | Back { rx_grants ; rx_ring ; _ } ->
      (* backend_get_n_grefs drains the same way before it waits, so this only
         moves the work to the wake-up. The list is bounded by the ring. *)
      Ring.Rpc.Back.ack_requests rx_ring (fun slot ->
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
    >>= fun (tx_gnt, tx_ring) ->
    frontend_create_ring ~domid:backend_id ~idx_size:RX.total_size
      (Printf.sprintf "Netif.RX.%d" vif_id)
    >>= fun (rx_gnt, rx_ring) ->
    let evtchn = Xen_os.Eventchn.bind_unbound_port h backend_id in
    Log.info (fun f -> f "[Frontend] Event channel: %d"
      (Xen_os.Eventchn.to_int evtchn));
    Xen_os.Eventchn.unmask h evtchn;
    let grant_tx_page = Xen_os.Xen.Export.grant_access ~domid:backend_id ~writable:false in
    let tx_pool = Shared_page_pool.make grant_tx_page in
    let ending = Front { tx_pool ; rx_map = Hashtbl.create 256 ; rx_ring ; tx_ring } in
    Lwt.return {
      vif_id; peer_domid = backend_id;
      mac; mtu;
      tx_gnt; tx_mutex = Lwt_mutex.create ();
      rx_gnt;
      rx_id = 0;
      free_pages = Io_page.to_pages (Io_page.get 256);
      evtchn; stats = Mirage_net.Stats.create (); counters = new_counters (); closed = false;
      ending;
    }

  let create_backend ~cleanup ~domid ~device_id ~frontend_mac ~mac ~mtu
      ~tx_ring_ref ~rx_ring_ref ~event_channel =
    Log.info (fun f -> f "[Backend] Creating: domid=%d device_id=%d" domid device_id);
    backend_import_ring ~domid ~gntref:(Xen_os.Xen.Gntref.of_int32 tx_ring_ref)
      ~idx_size:TX.total_size "Netif.Backend.TX" true
    >>= fun (tx_ring, tx_mapping) ->
    Cleanup.push cleanup (fun () -> Xen_os.Xen.Import.Local_mapping.unmap_exn tx_mapping; Lwt.return_unit);
    backend_import_ring ~domid ~gntref:(Xen_os.Xen.Gntref.of_int32 rx_ring_ref)
      ~idx_size:RX.total_size "Netif.Backend.RX" true
    >>= fun (rx_ring, rx_mapping) ->
    Cleanup.push cleanup (fun () -> Xen_os.Xen.Import.Local_mapping.unmap_exn rx_mapping; Lwt.return_unit);
    let channel = Xen_os.Eventchn.bind_interdomain h domid
        (int_of_string event_channel) in
    Cleanup.push cleanup (fun () -> Xen_os.Eventchn.unbind h channel; Lwt.return_unit);
    Log.info (fun f -> f "[Backend] Bound to event channel: %s" event_channel);
    Xen_os.Eventchn.unmask h channel;
    let ending = Back { peer_mac = frontend_mac ; rx_grants = Lwt_dllist.create () ; tx_ring ; rx_ring ;
                        tx_scratch = Io_page.get 1 ; rx_scratch = Io_page.get 1 } in
    Lwt.return {
      vif_id = device_id; peer_domid = domid;
      mac; mtu;
      tx_gnt = Xen_os.Xen.Gntref.of_int32 tx_ring_ref;
      tx_mutex = Lwt_mutex.create ();
      rx_gnt = Xen_os.Xen.Gntref.of_int32 rx_ring_ref;
      rx_id = 0;
      free_pages = [];
      evtchn = channel; stats = Mirage_net.Stats.create (); counters = new_counters (); closed = false;
      ending;
    }

  let plug_frontend vif_id =
    let id = `Client vif_id in
    C.read_backend id >>= fun backend_conf ->
    let backend_id = backend_conf.S.backend_id in
    C.read_frontend_mac id >>= fun mac ->
    C.read_mtu id >>= fun mtu ->
    create_frontend ~vif_id ~backend_id ~mac ~mtu >>= fun transport ->
    let front_conf = { S.
      tx_ring_ref = Xen_os.Xen.Gntref.to_int32 transport.tx_gnt;
      rx_ring_ref = Xen_os.Xen.Gntref.to_int32 transport.rx_gnt;
      event_channel = string_of_int (Xen_os.Eventchn.to_int transport.evtchn);
      feature_requests = Features.supported;
    } in
    C.write_frontend_configuration id front_conf >>= fun () ->
    C.connect id >>= fun () ->
    C.wait_until_backend_connected backend_conf >>= fun () ->
    (* packets are dropped until listen is called *)
    Log.info (fun f -> f "[Frontend] Connected to backend dom:%d/vif:%d"
      backend_id vif_id);
    let get_rx_grants t n =
      let rec take acc n l = match n, l with
        | 0, rest -> (acc, rest)
        | _, [] -> (acc, [])
        | n, hd :: tl -> take (hd :: acc) (n - 1) tl
      in
      let to_grant, remaining = take [] n t.free_pages in
      t.free_pages <- remaining;
      Lwt_list.map_s (fun page ->
        Xen_os.Xen.Export.get () >>= fun gnt ->
        Xen_os.Xen.Export.grant_access ~domid:backend_id ~writable:true gnt page;
        Lwt.return (gnt, page)
      ) to_grant
    in
    Lwt.return {
      t = transport;
      l = Lwt_mutex.create ();
      c = Lwt_condition.create ();
      get_rx_grants;
    }

  let connect id =
    (* If [id] is an integer, use it. Otherwise, return an error message
       which enumerates the available interfaces. *)
    match int_of_string_opt id with
    | Some id' -> begin
        if Hashtbl.mem devices id' then
          Lwt.return (Hashtbl.find devices id')
        else begin
          Log.info (fun f -> f "connect %d" id');
          plug_frontend id' >>= fun dev ->
          Hashtbl.add devices id' dev;
          Lwt.return dev
        end
      end
    | None ->
      C.enumerate () >>= fun all ->
      let msg =
        Printf.sprintf "device %s not found (available = [ %s ])"
          id (String.concat ", " all)
      in
      Lwt.fail_with msg

  let create_backend_device ~switch ~domid ~device_id =
    let id = `Server (domid, device_id) in
    let cleanup = Cleanup.create () in
    Lwt_switch.add_hook (Some switch) (fun () -> Cleanup.perform cleanup);
    Cleanup.push cleanup (fun () -> C.disconnect_backend id);
    C.read_backend_mac id >>= fun mac ->
    C.read_frontend_mac id >>= fun frontend_mac ->
    C.init_backend id Features.supported >>= fun _backend_configuration ->
    C.read_frontend_configuration id >>= fun f ->
    C.read_mtu id >>= fun mtu ->
    create_backend ~cleanup ~domid ~device_id ~frontend_mac ~mac ~mtu
      ~tx_ring_ref:f.S.tx_ring_ref
      ~rx_ring_ref:f.S.rx_ring_ref
      ~event_channel:f.S.event_channel
    >>= fun transport ->
    C.connect id >>= fun () ->
    Log.info (fun f -> f "[Backend] Connected to frontend");
    (* The backend owns no shared pages: the peer grants them and we copy into
       them, so the ring is never refilled from this side. *)
    let dev = {
      t = transport;
      l = Lwt_mutex.create ();
      c = Lwt_condition.create ();
      get_rx_grants = (fun _t _n -> Lwt.return []);
    } in
    (* Last pushed, first performed: stop anyone touching the rings before they
       are unmapped. *)
    Cleanup.push cleanup (fun () -> transport.closed <- true; Lwt.return_unit);
    Lwt.async (fun () ->
      C.wait_for_frontend_closing id >>= fun () ->
      Log.info (fun f -> f "Frontend asked to close network device dom:%d/vif:%d"
        domid device_id);
      Lwt_switch.turn_off switch
    );
    Lwt.return dev

  let make_backend ~domid ~device_id =
    let switch = Lwt_switch.create () in
    Lwt.catch
      (fun () -> create_backend_device ~switch ~domid ~device_id)
      (fun ex -> Lwt_switch.turn_off switch >>= fun () -> Lwt.fail ex)

  (* Returns a thread that completes once the peer has answered for every
     fragment. Nothing waits on it here: the caller decides. *)
  let write_locked nf ~size fillf =
    Lwt_mutex.with_lock nf.t.tx_mutex (fun () ->
      check_open nf.t;
      (match nf.t.ending with
       | Front _ when Shared_page_pool.blocks_needed size = 1 ->
         Unified_TX_Ops.write_single_block nf.t ~size fillf
       | _ ->
         (* Several blocks, or the backend, which writes into the peer's pages:
            marshal into a private buffer first, then split it. *)
         (* fillf writes into data. The backend also needs the page data sits
            in: copy_to identifies its source by page number, so the buffer
            must start on a page boundary, which only Io_page.t promises. *)
         let data, src_page =
           match nf.t.ending with
           | Front _ -> (Cstruct.create size, None)
           | Back { tx_scratch ; _ } when size <= Io_page.page_size ->
               (* Reused, so clear what fillf is about to write over. Only len
                  bytes ever reach the peer, so this is about the marshallers,
                  not about leaking. *)
               let cs = Cstruct.sub (Io_page.to_cstruct page) 0 size in
               Cstruct.memset cs 0;
               (cs, Some page)
           | Back _ ->
               (* Larger than the scratch, which needs an MTU above 4 kB. A
                  fresh Io_page is aligned and comes zeroed. *)
               let pages = Io_page.round_to_page_size size / Io_page.page_size in
               let page = Io_page.get pages in
               (Cstruct.sub (Io_page.to_cstruct page) 0 size, Some page)
         in
         let len = fillf data in
         if len > size then failwith "length exceeds total size";
         Unified_TX_Ops.fragment_data nf.t ?src_page (Cstruct.sub data 0 len)
         >|= fun fragments -> (len, fragments)) >|= fun (total_size, fragments) ->
      nf.t.counters.tx_frames <- nf.t.counters.tx_frames + 1;
      nf.t.counters.tx_fragments <- nf.t.counters.tx_fragments + List.length fragments;
      Unified_TX_Ops.notify_if_needed nf.t;
      Stats.tx nf.t.stats (Int64.of_int total_size);
      Lwt.join (List.map snd fragments))

  let rec write nf ~size fillf =
    match nf.t.ending with
    | Back _ ->
      (* The backend has already answered its peer by the time write_locked
         returns, so there is nothing to wait for. *)
      Lwt.catch
        (fun () -> write_locked nf ~size fillf >|= fun _released -> Ok ())
        (function
          | Netback_shutdown -> Lwt.return (Error `Disconnected)
          | ex -> Lwt.fail ex)
    | Front _ ->
      Lwt.catch
        (fun () -> write_locked nf ~size fillf)
        (function
          | Lwt_ring.Shutdown -> Lwt.return (Lwt.fail Lwt_ring.Shutdown)
          | e -> Lwt.fail e)
      >>= fun released ->
      Lwt.on_failure released (function
          | Lwt_ring.Shutdown -> ignore (write nf ~size fillf)
          | ex -> raise ex
        );
      Lwt.return (Ok ())

  let assemble_packet packet with_page_fn =
    let open Assemble in
    let data = Cstruct.create packet.total_size in
    let next = ref 0 in
    packet.fragments |> Lwt_list.iter_s (fun frag ->
      with_page_fn frag (fun buf ->
        Cstruct.blit buf frag.offset data !next frag.size;
        next := !next + frag.size)
    ) >|= fun () ->
    data

  let direction nf = match nf.t.ending with Front _ -> "Frontend" | Back _ -> "Backend"

  let rx_poll nf callback =
    (* Reading must not take the listen loop down: everything here is driven by
       data the peer controls. *)
    match Unified_RX_Ops.read_packets nf with
    | exception Netback_shutdown -> Lwt.fail Netback_shutdown
    | exception ex ->
      Log.err (fun f -> f "[%s-RX] Failed to read the ring: %s"
        (direction nf) (Printexc.to_string ex));
      Lwt.return_unit
    | packets ->
    packets |> Lwt_list.iter_s (function
      | Error frags ->
        Log.warn (fun f -> f "[%s-RX] Dropping unassembled packet (%d fragments)"
          (direction nf) (List.length frags));
        nf.t.counters.rx_dropped <- nf.t.counters.rx_dropped + 1;
        Unified_RX_Ops.discard_fragments nf frags
      | Ok packet ->
        Lwt.catch (fun () ->
          Lwt.async (fun () -> callback data)
          assemble_packet packet (Unified_RX_Ops.with_page nf) >>= fun data ->
          Unified_RX_Ops.release_extra_slots nf packet.Assemble.extra_ids
          >>= fun () ->
          nf.t.counters.rx_frames <- nf.t.counters.rx_frames + 1;
          nf.t.counters.rx_fragments <- nf.t.counters.rx_fragments + List.length packet.Assemble.fragments;
          Stats.rx nf.t.stats (Int64.of_int packet.Assemble.total_size);
          (* Lwt.async here would let the next frame start before this one has
             finished, and would put the callback outside the catch below. The
             pages are already back in the pool, so waiting holds nothing. *)
          callback data
        ) (fun ex ->
          Log.err (fun f -> f "[%s-RX] Callback FAILED with exception: %s"
            (direction nf) (Printexc.to_string ex));
          Lwt.return_unit))

  (* frames/poll is the batching factor: close to 1 means a full event channel
     wake-up per frame. fragments/frame is how many ring slots and page copies
     each frame costs. grant_share is the fraction of wall time spent inside
     grant hypercalls, which is the cost this driver can actually act on. *)
  let report_counters nf =
    let c = nf.t.counters in
    let ratio a b = if b = 0 then 0.0 else float_of_int a /. float_of_int b in
    let now = monotonic_ns () in
    let elapsed_ns = Int64.sub now c.last_ns in
    let elapsed_s = Int64.to_float elapsed_ns /. 1e9 in
    let frames_this_round = c.rx_frames + c.tx_frames - c.reported_at in
    let ops_per_s =
      if elapsed_s > 0.0 then float_of_int frames_this_round /. elapsed_s else 0.0 in
    let grant_us = Int64.to_float c.grant_ns /. 1e3 in
    let grant_share =
      if elapsed_ns > 0L then Int64.to_float c.grant_ns /. Int64.to_float elapsed_ns
      else 0.0 in
    Log.info (fun f -> f
      "[%s] counters: polls=%d rx_frames=%d frags/frame=%.2f frames/poll=%.2f \
       rx_dropped=%d tx_frames=%d tx_frags/frame=%.2f free_pages=%d \
       ops/s=%.0f grant_ops=%d grant_us/op=%.2f grant_share=%.1f%%"
      (direction nf) c.polls c.rx_frames
      (ratio c.rx_fragments c.rx_frames)
      (ratio c.rx_frames c.polls)
      c.rx_dropped c.tx_frames
      (ratio c.tx_fragments c.tx_frames)
      (List.length nf.t.free_pages)
      ops_per_s c.grant_ops
      (if c.grant_ops = 0 then 0.0 else grant_us /. float_of_int c.grant_ops)
      (grant_share *. 100.0));
    (* grant_ns and grant_ops are per round, so the share is of this round. *)
    c.reported_at <- c.rx_frames + c.tx_frames;
    c.last_ns <- now;
    c.grant_ns <- 0L;
    c.grant_ops <- 0

  let listen nf ~header_size:_ callback =
    let rec loop after =
      let c = nf.t.counters in
      c.polls <- c.polls + 1;
      rx_poll nf callback >>= fun () ->
      Unified_RX_Ops.post_receive nf >>= fun () ->
      Unified_RX_Ops.notify_if_needed nf;
      if Int64.sub (monotonic_ns ()) c.last_ns >= report_interval_ns then
        report_counters nf;
      (match nf.t.ending with
       | Front { tx_ring = _fring, client ; _ } ->
           Lwt_ring.Front.poll client (fun slot ->
             let resp = TX.Response.read slot in
             (resp.TX.Response.id, resp))
       | _ -> ());
      Xen_os.Activations.after nf.t.evtchn after >>= loop
    in
    Lwt.catch
      (fun () -> loop Xen_os.Activations.program_start)
      (function
        | Netback_shutdown -> Lwt.return (Ok ())
        | ex -> Lwt.fail ex)

  let frontend_mac nf =
    match nf.t.ending with
    | Back { peer_mac ; _ } -> peer_mac
    | Front _ -> nf.t.mac

  let mac nf = nf.t.mac
  let mtu nf = nf.t.mtu

  (* A frame length, header included, which mtu is not. See netif.mli. *)
  let max_frame_size nf = nf.t.mtu + Unified_TX_Ops.ethernet_header_size

  let get_stats_counters nf = nf.t.stats
  let reset_stats_counters nf = Mirage_net.Stats.reset nf.t.stats

  (* Unplug shouldn't block, although the Xen one might need to due
     to Xenstore? XXX *)
  let disconnect nf =
    match nf.t.ending with
    | Front { tx_pool ; _ } ->
      Log.info (fun f -> f "disconnect");
      (* TODO: free pages still in [rx_map] *)
      Shared_page_pool.shutdown tx_pool;
      Hashtbl.remove devices nf.t.vif_id;
      Lwt.return_unit
    | Back _ ->
      (* The switch created by [make_backend] performs the teardown. *)
      nf.t.closed <- true;
      Lwt.return_unit
end
