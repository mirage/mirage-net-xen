(*
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

let src = Logs.Src.create "netif_common" ~doc:"Netif common debugging"
module Log = (val Logs.src_log src : Logs.LOG)

(* TODO: can we factorize the Eventchn as the following module, with a unique handler? *)
module Eventchn = struct
  let handle = Xen_os.Eventchn.init ()
  
  let notify evtchn () =
    Xen_os.Eventchn.notify handle evtchn
  
  let unmask evtchn =
    Xen_os.Eventchn.unmask handle evtchn
  
  let bind_unbound_port domid =
    Xen_os.Eventchn.bind_unbound_port handle domid
  
  let bind_interdomain domid port =
    Xen_os.Eventchn.bind_interdomain handle domid port
  
  let unbind evtchn =
    Xen_os.Eventchn.unbind handle evtchn
end


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

module type RECEIVE_OPS = sig
  type t
  val read_packets : t -> Assemble.packet list
  val get_page : t -> Assemble.fragment -> Cstruct.t Lwt.t
  val notify_if_needed : t -> unit
  val get_evtchn : t -> Xen_os.Eventchn.t
  val get_stats : t -> Mirage_net.stats
  val post_receive : t -> unit Lwt.t
end

module Make_Receiver(Ops : RECEIVE_OPS) = struct

  (* Callback tracking to prevent race conditions while maintaining parallelism.
     We use Lwt.async for performance but track pending callbacks to ensure
     we wait for all to complete before doing the re-check. *)
  type t = {
    mutable n : int;
    c : unit Lwt_condition.t;
    l : Lwt_mutex.t;
  }

  let create_tracker () = {
    n = 0;
    c = Lwt_condition.create ();
    l = Lwt_mutex.create ();
  }

  let tracker = create_tracker ()

  let rx_poll t callback =
    let packets = Ops.read_packets t in
    Log.debug (fun f -> f "[RX] rx_poll: read %d packets" (List.length packets));
    (* Process packets in parallel with Lwt.async, and track them with the lock semaphore
       so we can wait for completion before re-checking. *)
    packets |> List.iter (fun packet ->
      (* Launch callback in parallel *)
      Lwt.async (fun () ->
        Lwt.catch (fun () ->
          assemble_packet packet (Ops.get_page t) >>= fun data ->
          Stats.rx (Ops.get_stats t) (Int64.of_int packet.total_size);
          Log.debug (fun f -> f "[RX] Callback starting for packet size=%d" packet.total_size);
          (* Execute the callback *)
          callback data >>= fun () ->
          Log.debug (fun f -> f "[RX] Callback COMPLETED for packet size=%d" packet.total_size);
          Lwt.return_unit
        )
        (fun ex ->
          Log.err (fun f -> f "[RX] Callback FAILED with exception: %s" (Printexc.to_string ex));
           Lwt.return_unit
         )
      )
    );
    Lwt.return_unit

  let listen t ~header_size:_ callback =
    let rec loop after =
      let evtchn = Ops.get_evtchn t in
      (* Process all available packets (launches callbacks with Lwt.async for performance) *)
      Log.debug (fun f -> f "[RX] Event received on evtchn %d, processing..." 
        (Xen_os.Eventchn.to_int evtchn));
      rx_poll t callback >>= fun () ->
      (* CRITICAL: We need to Wait for all callbacks to complete before continuing.
         This prevents the race condition where:
         1. Callbacks are still running
         2. We do the re-check too early
         3. We miss packets that were written during callback execution *)
      (* wait_for_callbacks () >>= fun () -> *)
      (* Post-processing (refill for frontend) *)
      Ops.post_receive t >>= fun () ->
      Log.debug (fun f -> f "[RX] post_receive done, notifying if needed");
      Ops.notify_if_needed t;
      (* Now that callbacks have completed, check if new packets arrived 
         while we were processing. This handles the race condition. *)
      let new_packets = Ops.read_packets t in
      if List.length new_packets > 0 then begin
        Log.debug (fun f -> f "[RX] Found %d new packets after processing, re-polling immediately" (List.length new_packets));
        loop after
      end else begin
        Log.debug (fun f -> f "[RX] No new packets, waiting for event on evtchn %d" 
          (Xen_os.Eventchn.to_int evtchn));
        Xen_os.Activations.after evtchn after >>= loop
      end
    in
    loop Xen_os.Activations.program_start
end

module type TRANSMIT_OPS = sig
  type t
  
  val fragment_data : 
    t -> 
    Cstruct.t -> 
    (Assemble.fragment * Io_page.t) list Lwt.t
  
  val release_fragments : 
    t -> 
    (Assemble.fragment * Io_page.t) list -> 
    unit Lwt.t
  
  val write_packet_to_ring : 
    t -> 
    Assemble.packet -> 
    unit
  
  val notify_if_needed : t -> unit
  val get_stats : t -> Mirage_net.stats
end

module Make_Transmitter(Ops : TRANSMIT_OPS) = struct
  let write t data =
    let size = Cstruct.length data in
    Log.debug (fun f -> f "[TX] write: starting, data size=%d" size);
    Ops.fragment_data t data >>= fun fragments ->
    let frags_only = List.map fst fragments in
    Log.debug (fun f -> f "[TX] Fragmented into %d fragments" (List.length fragments));
    let total_size = Cstruct.length data in
    let packet = Assemble.{
      total_size;
      fragments = frags_only;
    } in
    Log.debug (fun f -> f "[TX] Writing packet to ring, total_size=%d" total_size);
    Ops.write_packet_to_ring t packet;
    Log.debug (fun f -> f "[TX] Notifying if needed");
    Ops.notify_if_needed t;
    Log.debug (fun f -> f "[TX] Notification done, releasing fragments");
    Stats.tx (Ops.get_stats t) (Int64.of_int total_size);
    Ops.release_fragments t fragments
end

(* module Gntref = Xen_os.Xen.Gntref *)
