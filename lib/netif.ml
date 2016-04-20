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

open Lwt
open Printf
open OS

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

let allocate_ring ~domid =
  let page = Io_page.get 1 in
  let x = Io_page.to_cstruct page in
  lwt gnt = Gnt.Gntshr.get () in
  for i = 0 to Cstruct.len x - 1 do
    Cstruct.set_uint8 x i 0
  done;
  Gnt.Gntshr.grant_access ~domid ~writable:true gnt page;
  return (gnt, x)

module RX = struct

  module Proto_64 = struct
    cstruct req {
      uint16_t       id;
      uint16_t       _padding;
      uint32_t       gref
    } as little_endian

    let write ~id ~gref slot =
      set_req_id slot id;
      set_req_gref slot gref;
      id

        cstruct resp {
        uint16_t       id;
        uint16_t       offset;
        uint16_t       flags;
        uint16_t       status
      } as little_endian

    let read slot =
      get_resp_id slot,
      (get_resp_offset slot, get_resp_flags slot, get_resp_status slot)

    let total_size = max sizeof_req sizeof_resp
    let _ = assert(total_size = 8)
  end

  type response = int * int * int

  let create (id, domid) =
    let name = sprintf "Netif.RX.%d" id in
    lwt rx_gnt, buf = allocate_ring ~domid in
    let sring = Ring.Rpc.of_buf ~buf ~idx_size:Proto_64.total_size ~name in
    let fring = Ring.Rpc.Front.init ~sring in
    let client = Lwt_ring.Front.init string_of_int fring in
    return (rx_gnt, fring, client)

end

module TX = struct

  type response = int

  module Proto_64 = struct
    cstruct req {
      uint32_t       gref;
      uint16_t       offset;
      uint16_t       flags;
      uint16_t       id;
      uint16_t       size
    } as little_endian

    type flags =
      |Checksum_blank (* 1 *)
      |Data_validated (* 2 *)
      |More_data      (* 4 *)
      |Extra_info     (* 8 *)

    let flag_more_data = 4

    let write ~gref ~offset ~flags ~id ~size slot =
      set_req_gref slot gref;
      set_req_offset slot offset;
      set_req_flags slot flags;
      set_req_id slot id;
      set_req_size slot size;
      id

        cstruct resp {
        uint16_t       id;
        uint16_t       status
      } as little_endian

    let read slot =
      get_resp_id slot, get_resp_status slot

    let total_size = max sizeof_req sizeof_resp
    let _ = assert(total_size = 12)
  end

  let create (id, domid) =
    let name = sprintf "Netif.TX.%d" id in
    lwt rx_gnt, buf = allocate_ring ~domid in
    let sring = Ring.Rpc.of_buf ~buf ~idx_size:Proto_64.total_size ~name in
    let fring = Ring.Rpc.Front.init ~sring in
    let client = Lwt_ring.Front.init string_of_int fring in
    return (rx_gnt, fring, client)
end

module Shared_page_pool : sig
  type t
  val make : (Gnt.gntref -> Io_page.t -> unit) -> t
  val block_size : int

  val use : t -> (id:Cstruct.uint16 -> Gnt.gntref -> Cstruct.t -> ('a * unit Lwt.t) Lwt.t) -> ('a * unit Lwt.t) Lwt.t
  (** [use t fn] calls [fn ~id gref block] with a free shared block of memory.
   * The function should return a thread that indicates when the request has
   * been added to the queue, by returning a result value and a second thread
   * indicating when the block can be returned to the pool. *)

  val blocks_needed : int -> int

  val shutdown : t -> unit
end = struct
  let max_pages = 256

  type block = {
    id : Cstruct.uint16;
    gref : Gnt.gntref;
    data : Cstruct.t;
  }
  type t = {
    grant : Gnt.gntref -> Io_page.t -> unit;
    mutable next_id : Cstruct.uint16;
    mutable blocks : block list;
    mutable in_use : int;
    mutable shutdown : bool;
    avail : unit Lwt_condition.t; (* Fires when free list becomes non-empty *)
  }

  let page_size = Io_page.round_to_page_size 1
  let block_size = page_size / 2

  let make grant = { next_id = 0; grant; blocks = []; shutdown = false; in_use = 0; avail = Lwt_condition.create () }

  let shutdown t =
    t.shutdown <- true;
    Lwt_condition.broadcast t.avail (); (* Wake anyone who's still waiting for free pages *)
    if t.in_use = 0 then (
      t.blocks |> List.iter (fun {id=_; gref; data} ->
        if data.Cstruct.off = 0 then (
          Gnt.Gntshr.end_access gref;
          Gnt.Gntshr.put gref;
        )
      );
      t.blocks <- []
    )
    (* Otherwise, shutdown gets called again when in_use becomes 0 *)

  let alloc t =
    let page = Io_page.get 1 in
    (* (the Xen version of caml_alloc_pages clears the page, so we don't have to) *)
    lwt gnt = Gnt.Gntshr.get () in
    t.grant gnt page;
    return (gnt, Io_page.to_cstruct page)

  let put t block =
    let was_empty = (t.blocks = []) in
    t.blocks <- block :: t.blocks;
    t.in_use <- t.in_use - 1;
    if was_empty then Lwt_condition.broadcast t.avail ();
    if t.in_use = 0 && t.shutdown then shutdown t

  let use_block t fn block =
    let {id; gref; data} = block in
    t.in_use <- t.in_use + 1;
    Lwt.try_bind
      (fun () -> fn ~id gref data)
      (fun (_, release as result) ->
         Lwt.on_termination release (fun () -> put t block);
         return result
      )
      (fun ex -> put t block; Lwt.fail ex)

  let rec use t fn =
    if t.shutdown then
      failwith "Shared_page_pool.use after shutdown";
    match t.blocks with
    | [] when t.next_id >= max_pages ->
      MProf.Trace.label "Shared_page_pool waiting for free";
      Lwt_condition.wait t.avail >>= fun () -> use t fn
    | [] ->
      (* Frames normally fit within 2048 bytes, so we split each page in half. *)
      alloc t >>= fun (gref, page) ->
      let b1 = Cstruct.sub page 0 block_size in
      let b2 = Cstruct.shift page block_size in
      let id1 = t.next_id in
      let id2 = t.next_id + 1 in
      t.next_id <- t.next_id + 2;
      t.blocks <- {id = id2; gref; data = b2} :: t.blocks;
      Lwt_condition.broadcast t.avail ();
      use_block t fn {id = id1; gref; data = b1}
    | hd :: tl ->
      t.blocks <- tl;
      use_block t fn hd

  let blocks_needed bytes =
    (bytes + block_size - 1) / block_size
end

type features = {
  sg: bool;
  gso_tcpv4: bool;
  rx_copy: bool;
  rx_flip: bool;
  smart_poll: bool;
}

type stats = {
  mutable rx_bytes : int64;
  mutable rx_pkts : int32;
  mutable tx_bytes : int64;
  mutable tx_pkts : int32; 
}

type transport = {
  id: int;
  backend_id: int;
  backend: string;
  mac: Macaddr.t;
  tx_client: (TX.response,int) Lwt_ring.Front.t;
  tx_gnt: Gnt.gntref;
  tx_mutex: Lwt_mutex.t; (* Held to avoid signalling between fragments *)
  tx_pool: Shared_page_pool.t;
  rx_fring: (RX.response,int) Ring.Rpc.Front.t;
  rx_client: (RX.response,int) Lwt_ring.Front.t;
  rx_map: (int, Gnt.gntref * Io_page.t) Hashtbl.t;
  rx_gnt: Gnt.gntref;
  evtchn: Eventchn.t;
  features: features;
  stats : stats;
}

type t = {
  mutable t: transport;
  mutable resume_fns: (t -> unit Lwt.t) list;
  mutable receive_callback: Cstruct.t -> unit Lwt.t;
  l : Lwt_mutex.t;
  c : unit Lwt_condition.t;
}

type id = string

let id t = string_of_int t.t.id
let backend_id t = t.t.backend_id

let devices : (id, t) Hashtbl.t = Hashtbl.create 1

let h = Eventchn.init ()

(* Given a VIF ID and backend domid, construct a netfront record for it *)
let plug_inner id =
  lwt xsc = Xs.make () in
  lwt backend_id =
    Xs.(immediate xsc 
          (fun h -> 
             read h (sprintf "device/vif/%d/backend-id" id)))
    >|= int_of_string in
  Printf.printf "Netfront.create: id=%d domid=%d\n%!" id backend_id;
  (* Allocate a transmit and receive ring, and event channel for them *)
  lwt (rx_gnt, rx_fring, rx_client) = RX.create (id, backend_id) in
  lwt (tx_gnt, _tx_fring, tx_client) = TX.create (id, backend_id) in
  let tx_mutex = Lwt_mutex.create () in
  let evtchn = Eventchn.bind_unbound_port h backend_id in
  let evtchn_port = Eventchn.to_int evtchn in
  (* Read Xenstore info and set state to Connected *)
  let node = sprintf "device/vif/%d/" id in
  lwt backend = Xs.(immediate xsc (fun h -> read h (node ^ "backend"))) in
  lwt mac =
    Xs.(immediate xsc (fun h -> read h (node ^ "mac"))) 
    >|= Macaddr.of_string
    >>= function
    | None -> Lwt.fail (Failure "invalid mac")
    | Some m -> return m 
  in
  printf "MAC: %s\n%!" (Macaddr.to_string mac);
  Xs.(transaction xsc (fun h ->
      let wrfn k v = write h (node ^ k) v in
      wrfn "tx-ring-ref" (string_of_int tx_gnt) >>
      wrfn "rx-ring-ref" (string_of_int rx_gnt) >>
      wrfn "event-channel" (string_of_int (evtchn_port)) >>
      wrfn "request-rx-copy" "1" >>
      wrfn "feature-rx-notify" "1" >>
      wrfn "feature-sg" "1" >>
      wrfn "state" Device_state.(to_string Connected)
    )) >>
  (* Read backend features *)
  lwt features = Xs.(transaction xsc (fun h ->
      let rdfn k =
        try_lwt
          read h (sprintf "%s/feature-%s" backend k) >>= 
          function
          |"1" -> return true
          |_ -> return false
        with exn -> return false in
      lwt sg = rdfn "sg" in
      lwt gso_tcpv4 = rdfn "gso-tcpv4" in
      lwt rx_copy = rdfn "rx-copy" in
      lwt rx_flip = rdfn "rx-flip" in
      lwt smart_poll = rdfn "smart-poll" in
      return { sg; gso_tcpv4; rx_copy; rx_flip; smart_poll }
    )) in
  let rx_map = Hashtbl.create 1 in
  Printf.printf " sg:%b gso_tcpv4:%b rx_copy:%b rx_flip:%b smart_poll:%b\n"
    features.sg features.gso_tcpv4 features.rx_copy features.rx_flip features.smart_poll;
  lwt () = Xs.(wait xsc (fun h ->
    try_lwt
      lwt state = read h (backend ^ "/state") in
      if state = Device_state.(to_string Connected)
      then return ()
      else raise Xs_protocol.Eagain
    with Xs_protocol.Enoent _ -> raise Xs_protocol.Eagain
  )) in
  Eventchn.unmask h evtchn;
  let stats = { rx_pkts=0l;rx_bytes=0L;tx_pkts=0l;tx_bytes=0L } in
  let grant_tx_page = Gnt.Gntshr.grant_access ~domid:backend_id ~writable:false in
  let tx_pool = Shared_page_pool.make grant_tx_page in
  (* Register callback activation *)
  return { id; backend_id; tx_client; tx_gnt; tx_mutex; tx_pool;
           rx_gnt; rx_fring; rx_client; rx_map; stats;
           evtchn; mac; backend; features; 
         }

(** Set of active block devices *)
let devices : (int, t) Hashtbl.t = Hashtbl.create 1

let devices_waiters : (int, t Lwt.u Lwt_sequence.t) Hashtbl.t = Hashtbl.create 1

(** Return a list of valid VIFs *)
let enumerate () =
  lwt xs = Xs.make () in
  try_lwt
    Xs.(immediate xs (fun h -> directory h "device/vif"))
  with
  | Xs_protocol.Enoent _ ->
    return []
  | e ->
    printf "Netif.enumerate caught exception: %s\n" (Printexc.to_string e);
    return []

let notify nf () =
  Eventchn.notify h nf.evtchn

let refill_requests nf =
  let num = Ring.Rpc.Front.get_free_requests nf.rx_fring in
  if num > 0 then
    lwt grefs = Gnt.Gntshr.get_n num in
    let pages = Io_page.pages num in
    List.iter
      (fun (gref, page) ->
         let id = gref mod (1 lsl 16) in
         Gnt.Gntshr.grant_access ~domid:nf.backend_id ~writable:true gref page;
         Hashtbl.add nf.rx_map id (gref, page);
         let slot_id = Ring.Rpc.Front.next_req_id nf.rx_fring in
         let slot = Ring.Rpc.Front.slot nf.rx_fring slot_id in
         ignore(RX.Proto_64.write ~id ~gref:(Int32.of_int gref) slot)
      ) (List.combine grefs pages);
    if Ring.Rpc.Front.push_requests_and_check_notify nf.rx_fring
    then notify nf ();
    return ()
  else return ()

let rx_poll nf (fn: Cstruct.t -> unit Lwt.t) =
  MProf.Trace.label "Netif.rx_poll";
  Ring.Rpc.Front.ack_responses nf.rx_fring (fun slot ->
      let id,(offset,flags,status) = RX.Proto_64.read slot in
      let gref, page = Hashtbl.find nf.rx_map id in
      Hashtbl.remove nf.rx_map id;
      Gnt.Gntshr.end_access gref;
      Gnt.Gntshr.put gref;
      match status with
      |sz when status > 0 ->
        let packet = Cstruct.sub (Io_page.to_cstruct page) 0 sz in
        nf.stats.rx_pkts <- Int32.succ nf.stats.rx_pkts;
        nf.stats.rx_bytes <- Int64.add nf.stats.rx_bytes (Int64.of_int sz);
        ignore_result 
          (try_lwt fn packet
           with exn -> return (printf "RX exn %s\n%!" (Printexc.to_string exn)))
      |err -> printf "RX error %d\n%!" err
    )

let tx_poll nf =
  MProf.Trace.label "Netif.tx_poll";
  Lwt_ring.Front.poll nf.tx_client TX.Proto_64.read

let poll_thread (nf: t) : unit Lwt.t =
  let rec loop from =
    rx_poll nf.t nf.receive_callback;
    refill_requests nf.t >>= fun () ->
    tx_poll nf.t;
    Activations.after nf.t.evtchn from >>= fun from ->
    loop from
  in
  loop Activations.program_start

let connect id =
  (* If [id] is an integer, use it. Otherwise default to the first
     available disk. *)
  lwt id' =
    let id = try Some (int_of_string id) with _ -> None in
    match id with 
    | Some id -> 
      return (Some id)
    | None -> 
      enumerate ()
      >>= function
      | [] -> return None 
      | hd::_ -> return (Some (int_of_string hd))
  in
  match id' with
  | Some id' -> begin
      if Hashtbl.mem devices id' then
        return (`Ok (Hashtbl.find devices id'))
      else begin
        printf "Netif.connect %d\n%!" id';
        try_lwt
          lwt t = plug_inner id' in
          let l = Lwt_mutex.create () in
          let c = Lwt_condition.create () in
          (* packets are dropped until listen is called *)
          let receive_callback = fun _ -> return () in
          let dev = { t; resume_fns=[]; receive_callback; l; c } in
          let (_: unit Lwt.t) = poll_thread dev in
          Hashtbl.add devices id' dev;
          return (`Ok dev)
        with exn ->
          return (`Error (`Unknown (Printexc.to_string exn)))
      end
    end
  | None ->
    lwt all = enumerate () in
    printf "Netif.connect %s: could not find device\n" id;
    return (`Error (`Unknown
                      (Printf.sprintf "device %s not found (available = [ %s ])"
                         id (String.concat ", " all))))

(* Unplug shouldn't block, although the Xen one might need to due
   to Xenstore? XXX *)
let disconnect t =
  printf "Netif: disconnect\n%!";
  Shared_page_pool.shutdown t.t.tx_pool;
  Hashtbl.remove devices t.t.id;
  return ()

(** Copy from src to dst until src is exhausted or dst is full.
 * Returns the number of bytes copied and the remaining data from src, if any. *)
(* TODO: replace this with Cstruct.buffer once that's released. *)
let blitv src dst =
  let rec aux dst n = function
    | [] -> n, []
    | hd::tl ->
        let avail = Cstruct.len dst in
        let first = Cstruct.len hd in
        if first <= avail then (
          Cstruct.blit hd 0 dst 0 first;
          aux (Cstruct.shift dst first) (n + first) tl
        ) else (
          Cstruct.blit hd 0 dst 0 avail;
          let rest_hd = Cstruct.shift hd first in
          (n + avail, rest_hd :: tl)
        ) in
  aux dst 0 src

(* Push up to one page's worth of data to the ring, but without sending an
 * event notification. Once the data has been added to the ring, returns the
 * remaining (unsent) data and a thread which will return when the data has
 * been ack'd by netback. *)
let write_request ?size ~flags nf datav =
  Shared_page_pool.use nf.t.tx_pool (fun ~id gref shared_block ->
    let len, datav = blitv datav shared_block in
    (* [size] includes extra pages to follow later *)
    let size = match size with |None -> len |Some s -> s in
    nf.t.stats.tx_pkts <- Int32.succ nf.t.stats.tx_pkts;
    nf.t.stats.tx_bytes <- Int64.add nf.t.stats.tx_bytes (Int64.of_int size);
    lwt replied = Lwt_ring.Front.write nf.t.tx_client
        (TX.Proto_64.write ~id ~gref:(Int32.of_int gref) ~offset:shared_block.Cstruct.off ~flags ~size) in
    (* request has been written; when replied returns we have a reply *)
    let release = replied >>= fun _ -> return () in
    return (datav, release)
  )

(* Transmit a packet from buffer, with offset and length.
 * The buffer's data must fit in a single block. *)
let write_already_locked nf datav =
  lwt remaining, th = write_request ~flags:0 nf datav in
  assert (Cstruct.lenv remaining = 0);
  Lwt_ring.Front.push nf.t.tx_client (notify nf.t);
  return th

(* Transmit a packet from a list of pages *)
let writev_no_retry nf datav =
  let size = Cstruct.lenv datav in
  let numneeded = Shared_page_pool.blocks_needed size in
  Lwt_mutex.with_lock nf.t.tx_mutex
    (fun () ->
       lwt () = Lwt_ring.Front.wait_for_free nf.t.tx_client numneeded in
       match numneeded with
       | 0 -> return (return ())
       | 1 ->
         (* If there is only one block, then just write it normally *)
         write_already_locked nf datav
       | n ->
         (* For Xen Netfront, the first fragment contains the entire packet
          * length, which the backend will use to consume the remaining
          * fragments until the full length is satisfied *)
         lwt datav, first_th =
           write_request ~flags:TX.Proto_64.flag_more_data ~size nf datav in
         let rec xmit datav = function
           | 0 -> return []
           | 1 ->
               lwt datav, th = write_request ~flags:0 nf datav in
               assert (Cstruct.lenv datav = 0);
               return [ th ]
           | n ->
               lwt datav, next_th = write_request ~flags:TX.Proto_64.flag_more_data nf datav in
               lwt rest = xmit datav (n - 1) in
               return (next_th :: rest) in
         lwt rest_th = xmit datav (n - 1) in
         (* All fragments are now written, we can now notify the backend *)
         Lwt_ring.Front.push nf.t.tx_client (notify nf.t);
         return (Lwt.join (first_th :: rest_th))
    )

let rec writev nf datav =
  lwt released =
    try_lwt writev_no_retry nf datav
    with Lwt_ring.Shutdown -> return (fail Lwt_ring.Shutdown) in
  Lwt.on_failure released (function
    | Lwt_ring.Shutdown -> ignore (writev nf datav)
    | ex -> raise ex
  );
  return ()

let write nf data = writev nf [data]

let wait_for_plug nf =
  Printf.printf "Wait for plug...\n";
  Lwt_mutex.with_lock nf.l (fun () ->
      while_lwt not (Eventchn.is_valid nf.t.evtchn) do
        MProf.Trace.label "Netif.wait_for_plug";
        Lwt_condition.wait ~mutex:nf.l nf.c
      done)

let listen nf fn =
  (* packets received from this point on will go to [fn]. Historical
     packets have not been stored: we don't want to buffer the network *)
  nf.receive_callback <- fn;
  let t, _ = MProf.Trace.named_task "Netif.listen" in
  t (* never return *)

(** Return a list of valid VIFs *)
let enumerate () =
  Xs.make ()
  >>= fun xsc ->
  catch
    (fun () -> 
       Xs.(immediate xsc 
             (fun h -> directory h "device/vif")) 
       >|= (List.map int_of_string) )
    (fun _ -> return [])

let resume (id,t) =
  lwt transport = plug_inner id in
  let old_transport = t.t in
  t.t <- transport;
  lwt () = Lwt_list.iter_s (fun fn -> fn t) t.resume_fns in
  lwt () = Lwt_mutex.with_lock t.l
      (fun () -> Lwt_condition.broadcast t.c (); return ()) in
  Lwt_ring.Front.shutdown old_transport.rx_client;
  Lwt_ring.Front.shutdown old_transport.tx_client;
  return ()

let resume () =
  let devs = Hashtbl.fold (fun k v acc -> (k,v)::acc) devices [] in
  Lwt_list.iter_p (fun (k,v) -> resume (k,v)) devs

let add_resume_hook t fn =
  t.resume_fns <- fn::t.resume_fns

(* Type of callback functions for [create]. *)
type callback = id -> t -> unit Lwt.t

(* The Xenstore MAC address is colon separated, very helpfully *)
let mac nf = nf.t.mac

let get_stats_counters t = t.t.stats

let reset_stats_counters t =
  t.t.stats.rx_bytes <- 0L;
  t.t.stats.rx_pkts  <- 0l;
  t.t.stats.tx_bytes <- 0L;
  t.t.stats.tx_pkts  <- 0l

let _ =
  printf "Netif: add resume hook\n%!";
  Sched.add_resume_hook resume
