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

let src = Logs.Src.create "assemble" ~doc:"mirage-net-xen.assemble"
module Log = (val Logs.src_log src : Logs.LOG)

type fragment = {
  id: int;
  offset: int;
  size: int;
  gref: int32;
}

type packet = {
  total_size: int;
  fragments: fragment list;
}

(* [Error frags] reports the fragments of a packet that could not be assembled,
   so the caller can release their pages and grants rather than leak them. *)
type assembled = (packet, fragment list) result

(* The rings differ in the first message only. A transmit request announces the
   whole packet, since the sender knows it; a receive response cannot, being
   written as its page is filled, so it carries its own size like the rest.
   https://github.com/xen-project/xen/blob/RELEASE-4.19.4/xen/include/public/io/netif.h#L757-L781 *)
module type SIZE_STRATEGY = sig
  val name : string

  val compute_sizes_read :
    declared_size:int -> rest_sizes:int list -> (int * int)
end

module RX_Size_Strategy : SIZE_STRATEGY = struct
  let name = "RX"

(* Every response reports the bytes written in its own page, the first one
   included, so the packet is their sum.
   https://github.com/xen-project/xen/blob/RELEASE-4.19.4/xen/include/public/io/netif.h#L834-L839 *)
  let compute_sizes_read ~declared_size ~rest_sizes =
    let total = declared_size + List.fold_left (+) 0 rest_sizes in
    (total, declared_size)
end

module TX_Size_Strategy : SIZE_STRATEGY = struct
  let name = "TX"

(* Here declared_size is the whole packet and the following requests carry only
   their own fragment, so the first fragment is what remains. Same subtraction
   as netback, first->size -= txp->size.
   https://github.com/xen-project/xen/blob/RELEASE-4.19.4/xen/include/public/io/netif.h#L776-L781
   https://github.com/torvalds/linux/blob/v6.12/drivers/net/xen-netback/netback.c#L304 *)
  let compute_sizes_read ~declared_size ~rest_sizes =
    let total = declared_size in
    let first_frag = declared_size - List.fold_left (+) 0 rest_sizes in
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
end

module Make_Reader(Msg : MESSAGE)(Size : SIZE_STRATEGY) = struct

  let collect_messages ack_fn =
    let messages = ref [] in
    ack_fn (fun slot ->
      match Msg.read slot with
      | Error e -> Log.warn (fun f -> f "[%s] Bad msg: %s" Size.name e)
      | Ok msg -> messages := msg :: !messages
    );
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
      let sizes = List.map (function Ok s -> s | Error _ -> assert false) sizes in
      let declared_size::rest_sizes = sizes in
      let total_size, first_fragment_size =
        Size.compute_sizes_read ~declared_size ~rest_sizes in
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

        Ok { total_size; fragments = first_fragment :: rest_fragments }

  let read_packets ack_fn =
    let messages = collect_messages ack_fn in
    let packets = group_into_packets messages in
    Log.debug (fun f -> f "[%s.Reader] read_packets: %d messages -> %d packets (%d dropped)"
      Size.name (List.length messages) (List.length packets)
      (List.length (List.filter Result.is_error packets)));
    packets
end

module RX_Reader = Make_Reader(RX_Message)(RX_Size_Strategy)
module TX_Reader = Make_Reader(TX_Message)(TX_Size_Strategy)

module type IO = sig
  val read_packets : ack_fn:((Cstruct.t -> unit) -> unit) -> assembled list
end

module RX_IO : IO = struct
  let read_packets ~ack_fn = RX_Reader.read_packets ack_fn
end

module TX_IO : IO = struct
  let read_packets ~ack_fn = TX_Reader.read_packets ack_fn
end
