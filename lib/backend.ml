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

open Lwt.Infix
open Mirage_net

module Gntref = Xen_os.Xen.Gntref
module Import = Xen_os.Xen.Import

let src = Logs.Src.create "net-xen backend" ~doc:"Mirage's Xen netback"
module Log = (val Logs.src_log src : Logs.LOG)

let return = Lwt.return

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

module Make(C: S.CONFIGURATION) = struct
  exception Netback_shutdown

  type error = Mirage_net.Net.error
  let pp_error = Mirage_net.Net.pp_error

  type t = {
    channel: Xen_os.Eventchn.t;
    frontend_id: int;
    mac: Macaddr.t;
    frontend_mac: Macaddr.t;
    mtu: int;
    backend_configuration: S.backend_configuration;
    mutable to_netfront: (RX.Response.t,int) Ring.Rpc.Back.t option;
    rx_reqs: RX.Request.t Lwt_dllist.t;         (* Grants we can write into *)
    mutable from_netfront: (TX.Response.t,int) Ring.Rpc.Back.t option;
    stats: Mirage_net.stats;
    write_mutex: Lwt_mutex.t;
    get_free_mutex: Lwt_mutex.t;
  }

  let h = Xen_os.Eventchn.init ()

  let create ~switch ~domid ~device_id =
    let id = `Server (domid, device_id) in
    let cleanup = Cleanup.create () in
    Lwt_switch.add_hook (Some switch) (fun () -> Cleanup.perform cleanup);
    Cleanup.push cleanup (fun () -> C.disconnect_backend id);
    C.read_backend_mac id >>= fun mac ->
    C.read_frontend_mac id >>= fun frontend_mac ->
    C.init_backend id Features.supported >>= fun backend_configuration ->
    let frontend_id = backend_configuration.S.frontend_id in
    C.read_frontend_configuration id >>= fun f ->
    let channel = Xen_os.Eventchn.bind_interdomain h frontend_id (int_of_string f.S.event_channel) in
    Cleanup.push cleanup (fun () -> Xen_os.Eventchn.unbind h channel; return ());
    (* Note: TX and RX are from netfront's point of view (e.g. we receive on TX). *)    
    let from_netfront =
      let tx_gnt = {Import.domid = frontend_id; ref = Gntref.of_int32 f.S.tx_ring_ref} in
      let mapping = Import.map_exn tx_gnt ~writable:true in
      Cleanup.push cleanup (fun () -> Import.Local_mapping.unmap_exn mapping; return ());
      let buf = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
      let sring = Ring.Rpc.of_buf_no_init ~buf ~idx_size:TX.total_size
        ~name:("Netif.Backend.TX." ^ backend_configuration.S.backend) in
      Ring.Rpc.Back.init ~sring in
    let to_netfront =
      let rx_gnt = {Import.domid = frontend_id; ref = Gntref.of_int32 f.S.rx_ring_ref} in
      let mapping = Import.map_exn rx_gnt ~writable:true in
      Cleanup.push cleanup (fun () -> Import.Local_mapping.unmap_exn mapping; return ());
      let buf = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
      let sring = Ring.Rpc.of_buf_no_init ~buf ~idx_size:RX.total_size
        ~name:("Netif.Backend.RX." ^ backend_configuration.S.backend) in
      Ring.Rpc.Back.init ~sring in
    let stats = Stats.create () in
    let rx_reqs = Lwt_dllist.create () in
    Xen_os.Eventchn.unmask h channel;
    C.connect id >>= fun () ->
    let write_mutex = Lwt_mutex.create () in
    let get_free_mutex = Lwt_mutex.create () in
    C.read_mtu id >>= fun mtu ->
    let t = {
      channel; frontend_id; backend_configuration;
      to_netfront = Some to_netfront; from_netfront = Some from_netfront; rx_reqs;
      get_free_mutex; write_mutex;
      stats; mac; frontend_mac; mtu; } in
    Cleanup.push cleanup (fun () ->
      t.to_netfront <- None;
      t.from_netfront <- None;
      return ()
    );
    Lwt.async (fun () ->
      C.wait_for_frontend_closing id >>= fun () ->
      Log.info (fun f -> f "Frontend closing dom:%d/vif:%d" domid device_id);
      Lwt_switch.turn_off switch
    );
    return t

  let make ~domid ~device_id =
    let switch = Lwt_switch.create () in
    Lwt.catch
      (fun () -> create ~switch ~domid ~device_id)
      (fun ex -> Lwt_switch.turn_off switch >>= fun () -> Lwt.fail ex)

  let from_netfront t =
    match t.from_netfront with
    | None -> raise Netback_shutdown
    | Some x -> x

  let to_netfront t =
    match t.to_netfront with
    | None -> raise Netback_shutdown
    | Some x -> x

  let map_and_respond t frag =
    let gnt = { Import.domid = t.frontend_id; ref = Gntref.of_int32 frag.Assemble.gref } in
    Import.with_mapping gnt ~writable:false (fun mapping ->
      let cs = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
      (* We must do a copy here otherwise the page is claimed back by the other side... *)
      let cpy = Cstruct.sub_copy cs 0 (Cstruct.length cs) in
      let slot = 
        let ring = from_netfront t in
        Ring.Rpc.Back.(slot ring (next_res_id ring))
      in
      let resp = { TX.Response.id = frag.id; status = TX.Response.OKAY } in
      TX.Response.write resp slot;
      Lwt.return cpy
    ) >>= function
    | Error (`Msg m) -> Lwt.fail_with m
    | Ok page -> Lwt.return page

  module Backend_RX_Ops = struct
    type nonrec t = t
    let read_packets t =
      Log.debug (fun f -> f "[Backend.RX] read_packets: reading from ring");
      Assemble.TX_IO.read_packets 
        ~ack_fn:(Ring.Rpc.Back.ack_requests (from_netfront t))
    let get_page t frag = map_and_respond t frag
    let notify_if_needed t =
      let should_notify = Ring.Rpc.Back.push_responses_and_check_notify (from_netfront t) in
      Log.debug (fun f -> f "[Backend.RX] notify_if_needed: should_notify=%b" should_notify);
      
      if should_notify then begin
        Log.debug (fun f -> f "[Backend.RX] Sending notification on evtchn");
        Xen_os.Eventchn.notify h t.channel
      end
    let get_evtchn t = t.channel
    let get_stats t = t.stats
    let post_receive _t = Lwt.return_unit
  end

  (* We need [n] pages to send a packet to the frontend. The Ring.Back API
     gives us all the requests that are available at once. Since we may need
     fewer of this, stash them in the t.rx_reqs sequence.
     Raises [Netback_shutdown] if the interface has been shut down. *)
  let get_n_grefs t n =
    let rec take seq = function
      | 0 -> []
      | n -> Lwt_dllist.take_l seq :: (take seq (n - 1))
    in
    let rec loop after =
      let n' = Lwt_dllist.length t.rx_reqs in
      Log.debug (fun f -> f "[Backend.TX] get_n_grefs: need %d, have %d" n n');
      if n' >= n then return (take t.rx_reqs n)
      else begin
        Log.debug (fun f -> f "[Backend.TX] Not enough grefs, acking requests from ring");
        Ring.Rpc.Back.ack_requests (to_netfront t)
          (fun slot ->
            let req = RX.Request.read slot in
            Log.debug (fun f -> f "[Backend.TX] Got RX request: id=%d gref=%ld" 
              req.RX.Request.id req.RX.Request.gref);
            ignore(Lwt_dllist.add_r req t.rx_reqs)
          );
        let new_n = Lwt_dllist.length t.rx_reqs in
        Log.debug (fun f -> f "[Backend.TX] After acking: had %d, now have %d grefs" n' new_n);
        if Lwt_dllist.length t.rx_reqs <> n'
        then loop after
        else begin
          Log.debug (fun f -> f "[Backend.TX] No new grefs, waiting for event on channel");
          Xen_os.Activations.after t.channel after >>= loop
        end
      end
    in
    (* We lock here so that we handle one frame at a time.
       Otherwise, we might divide the free pages among lots of
       waiters and deadlock. *)
    Lwt_mutex.with_lock t.get_free_mutex (fun () ->
      Log.debug (fun f -> f "[Backend.TX] get_n_grefs: acquired lock, starting");
      loop Xen_os.Activations.program_start
    )

  module Backend_TX_Ops = struct
    type nonrec t = t
    
    let fragment_data t data =
      let size = Cstruct.length data in
      let pages_needed = max 1 @@ Io_page.round_to_page_size size / Io_page.page_size in      
      Log.debug (fun f -> f "[Backend.TX] fragment_data: size=%d, pages_needed=%d" 
        size pages_needed);
      get_n_grefs t pages_needed >>= fun reqs ->
      Log.debug (fun f -> f "[Backend.TX] Got %d grant refs, mapping and copying" (List.length reqs));
      let rec map_and_copy src offset acc_frags = function
        | [] -> return (List.rev acc_frags)
        | req :: rest ->
            let gnt = {Import.domid = t.frontend_id; ref = Gntref.of_int32 req.RX.Request.gref} in
            let mapping = Import.map_exn gnt ~writable:true in
            let dst = Import.Local_mapping.to_buf mapping |> Io_page.to_cstruct in
            Cstruct.memset dst 0;
            let to_copy = min (Cstruct.length dst) (Cstruct.length src - offset) in
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
      Assemble.RX_IO.write_packet
        ~get_slot:(fun () ->
          let ring = to_netfront t in
          Ring.Rpc.Back.(slot ring (next_res_id ring))
        )
        ~packet
    
    let notify_if_needed t =
      let should_notify = Ring.Rpc.Back.push_responses_and_check_notify (to_netfront t) in
      Log.debug (fun f -> f "[Backend.TX] notify_if_needed: should_notify=%b" should_notify);
      
      if should_notify then begin
        Log.debug (fun f -> f "[Backend.TX] Sending notification on evtchn");
        Xen_os.Eventchn.notify h t.channel
      end
    
    let release_fragments _t _fragments =
      Lwt.return_unit
    
    let get_stats t = t.stats
  end

  module Receiver = Netif_common.Make_Receiver(Backend_RX_Ops)
  module Transmitter = Netif_common.Make_Transmitter(Backend_TX_Ops)

  let write t ~size fillf =
    Lwt.catch
      (fun () ->
        let data = Cstruct.create size in
        let len = fillf data in
        if len > size then failwith "length exceeds total size";
        let buf = Cstruct.sub data 0 len in
        
        Lwt_mutex.with_lock t.write_mutex (fun () ->
          Transmitter.write t buf
        ) >|= fun () -> Ok ()
      )
      (function
        | Netback_shutdown -> Lwt.return (Error `Disconnected)
        | ex -> Lwt.fail ex
      )

  let listen (t: t) ~header_size fn : (unit, error) result Lwt.t =
    Lwt.catch
      (fun () -> 
        Receiver.listen t ~header_size fn >|= fun `Never_returns -> 
        assert false
      )
      (function
        | Netback_shutdown -> Lwt.return (Ok ())
        | ex -> Lwt.fail ex
      )

  let mac t = t.mac
  let mtu t = t.mtu
  let get_stats t = t.stats
  let get_stats_counters t = get_stats t
  let reset_stats_counters t = Stats.reset (get_stats t)
  let disconnect _t = failwith "TODO: disconnect"
  let frontend_mac t = t.frontend_mac
end
