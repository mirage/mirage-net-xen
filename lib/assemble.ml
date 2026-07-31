(*
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

let src = Logs.Src.create "assemble" ~doc:"Packet assembly debugging"
module Log = (val Logs.src_log src : Logs.LOG)

(* Extra_info descriptors parsed off a ring since boot, across every reader.
   Tells a caller whether the peer really sends aggregated frames, which the
   fragment count alone cannot say. *)
let extras_seen = ref 0

type fragment = {
  id: int;
  offset: int;
  size: int;
  gref: int32;
}

type packet = {
  total_size: int;
  fragments: fragment list;
  (* Ring ids of the slots that extra_info descriptors consumed. Such a slot
     cost the reader whatever a slot costs, a page on the receive ring, but
     carries no data and yields no fragment, so nothing else would give it back.

     Derived by position: a descriptor sits in the slot after the message it
     qualifies and ids run consecutively. That only holds where the reader
     assigned the ids, so a backend reading ids its peer chose must not use
     these. *)
  extra_ids: int list;
}

(* [Error frags] reports the fragments of a packet that could not be assembled,
   so the caller can release their pages and grants rather than leak them. *)
type assembled = (packet, fragment list) result

(* The rings differ in the first message only. A transmit request announces the
   whole packet, since the sender knows it; a receive response cannot, being
   written as its page is filled, so it carries its own size like the rest. *)
module type SIZE_STRATEGY = sig
  val name : string

  val compute_sizes_read :
    first_size:int -> rest_sizes:int list -> (int * int)
end

module RX_Size_Strategy : SIZE_STRATEGY = struct
  let name = "RX"

  let compute_sizes_read ~first_size ~rest_sizes =
    let total = first_size + List.fold_left (+) 0 rest_sizes in
    (total, first_size)
end

module TX_Size_Strategy : SIZE_STRATEGY = struct
  let name = "TX"

  let compute_sizes_read ~first_size ~rest_sizes =
    let total = first_size in
    let first_frag = first_size - List.fold_left (+) 0 rest_sizes in
    (total, first_frag)
end

module type MESSAGE = sig
  type t
  type error

  val read : Cstruct.t -> (t, string) result
  val id : t -> int
  val offset : t -> int
  val flags : t -> Flags.t
  val size : t -> (int, error) result
  val gref : t -> int32

  val set_extras : t -> Extra.t list -> t
  val extras : t -> Extra.t list
end

module RX_Message : MESSAGE with type t = RX.Response.t
                             and type error = int = struct
  type t = RX.Response.t
  type error = int

  let read = RX.Response.read
  let id msg = msg.RX.Response.id
  let offset msg = msg.RX.Response.offset
  let flags msg = msg.RX.Response.flags
  let size msg = msg.RX.Response.size
  (* The page is the reader's own, found from the id. *)
  let gref _msg = 0l

  let set_extras msg extras = {msg with RX.Response.extras = extras}
  let extras msg = msg.RX.Response.extras
end

module TX_Message : MESSAGE with type t = TX.Request.t
                             and type error = TX.Request.error = struct
  type t = TX.Request.t
  type error = TX.Request.error

  let read = TX.Request.read
  let id msg = msg.TX.Request.id
  let offset msg = msg.TX.Request.offset
  let flags msg = msg.TX.Request.flags
  let size msg = TX.Request.size msg
  let gref msg = msg.TX.Request.gref

  let set_extras msg extras = {msg with TX.Request.extras = extras}
  let extras msg = msg.TX.Request.extras
end

module Make_Reader(Msg : MESSAGE)(Size : SIZE_STRATEGY) = struct

  (* A descriptor sits in the slot after the message it qualifies and carries no
     data, so it has to be recognised rather than read as another message. *)
  let collect_messages ?(with_extras=false) ack_fn =
    let messages = ref [] in
    let pending_msg = ref None in
    let pending_extras = ref [] in

    ack_fn (fun slot ->
      if with_extras then (
        match !pending_msg with
        | Some base_msg ->
            begin match Extra.read slot with
            | Error e ->
                Log.warn (fun f -> f "[%s] Drop bad extra_info: %s" Size.name e);
                messages := base_msg :: !messages;
                pending_msg := None;
                pending_extras := []
            | Ok extra ->
                incr extras_seen;
                pending_extras := extra :: !pending_extras;
                (* Bit 0 of flags: 0 = last extra, 1 = more extras *)
                if extra.Extra.flags land 1 = 0 then (
                  messages := Msg.set_extras base_msg (List.rev !pending_extras) :: !messages;
                  pending_msg := None;
                  pending_extras := []
                )
            end
        | None ->
            match Msg.read slot with
            | Error e -> Log.warn (fun f -> f "[%s] Bad msg: %s" Size.name e)
            | Ok msg ->
                if Flags.(mem extra_info) (Msg.flags msg) then
                  pending_msg := Some msg
                else
                  messages := msg :: !messages
      ) else (
        match Msg.read slot with
        | Error e -> Log.warn (fun f -> f "[%s] Bad msg: %s" Size.name e)
        | Ok msg -> messages := msg :: !messages
      )
    );
    if with_extras then (
      match !pending_msg with
      | Some base_msg ->
          Log.warn (fun f -> f "[%s] Orphan message recovered" Size.name);
          messages := Msg.set_extras base_msg (List.rev !pending_extras) :: !messages
      | None -> ());
    List.rev !messages

  (* Enough to release the page and grant, without trusting the size field. *)
  let fragment_of_msg msg =
    { id = Msg.id msg; offset = Msg.offset msg; size = 0; gref = Msg.gref msg }

  let rec group_into_packets = function
    | [] -> []
    | msg :: rest ->
        if Flags.(mem more_data) (Msg.flags msg) then begin
          match collect_fragments rest with
          | Ok (frags, remaining) ->
              make_packet msg frags :: group_into_packets remaining
          | Error frags ->
              (* Nothing left to resynchronise on: report what we hold and stop. *)
              Log.warn (fun f -> f "[%s] Truncated fragment chain, dropping %d messages"
                Size.name (1 + List.length frags));
              [ Error (List.map fragment_of_msg (msg :: frags)) ]
        end else
          make_packet msg [] :: group_into_packets rest

  and collect_fragments = function
    | [] -> Error []
    | msg :: rest ->
        if Flags.(mem more_data) (Msg.flags msg) then begin
          match collect_fragments rest with
          | Ok (more, remaining) -> Ok (msg :: more, remaining)
          | Error frags -> Error (msg :: frags)
        end else Ok ([msg], rest)

  and make_packet first_msg continuation_msgs =
    let msgs = first_msg :: continuation_msgs in
    let sizes = List.map Msg.size msgs in
    (* A non-positive status is a normal outcome, not a reason to abort the poll. *)
    if List.exists Result.is_error sizes then begin
      Log.warn (fun f -> f "[%s] Dropping packet: %d/%d messages carry an error status"
        Size.name
        (List.length (List.filter Result.is_error sizes))
        (List.length sizes));
      Error (List.map fragment_of_msg msgs)
    end else
      let extra_ids =
        List.mapi
          (fun k _ -> (Msg.id first_msg + k + 1) land 0xffff)
          (Msg.extras first_msg)
      in
      let sizes = List.map (function Ok s -> s | Error _ -> assert false) sizes in
      let first_size = List.hd sizes in
      let rest_sizes = List.tl sizes in
      let total_size, first_fragment_size =
        Size.compute_sizes_read ~first_size ~rest_sizes in
      (* The TX subtraction goes negative if the peer announces sizes that do
         not add up. *)
      if total_size < 0 || first_fragment_size < 0 then begin
        Log.warn (fun f -> f "[%s] Dropping packet with inconsistent sizes (total=%d first=%d)"
          Size.name total_size first_fragment_size);
        Error (List.map fragment_of_msg msgs)
      end else
        let first_fragment = {
          id = Msg.id first_msg;
          offset = Msg.offset first_msg;
          size = first_fragment_size;
          gref = Msg.gref first_msg;
        } in

        let rest_fragments = List.map2 (fun msg size ->
          { id = Msg.id msg; offset = Msg.offset msg; size; gref = Msg.gref msg }
        ) continuation_msgs rest_sizes in

        Ok { total_size; fragments = first_fragment :: rest_fragments; extra_ids }

  let read_packets ?with_extras ack_fn =
    let messages = collect_messages ?with_extras ack_fn in
    let packets = group_into_packets messages in
    Log.debug (fun f -> f "[%s.Reader] read_packets: %d messages -> %d packets (%d dropped)"
      Size.name (List.length messages) (List.length packets)
      (List.length (List.filter Result.is_error packets)));
    packets
end

module RX_Reader = Make_Reader(RX_Message)(RX_Size_Strategy)
module TX_Reader = Make_Reader(TX_Message)(TX_Size_Strategy)

module type IO = sig
  val read_packets :
    with_extras:bool -> ack_fn:((Cstruct.t -> unit) -> unit) -> assembled list
end

module RX_IO : IO = struct
  let read_packets ~with_extras ~ack_fn = RX_Reader.read_packets ~with_extras ack_fn
end

module TX_IO : IO = struct
  let read_packets ~with_extras ~ack_fn = TX_Reader.read_packets ~with_extras ack_fn
end
