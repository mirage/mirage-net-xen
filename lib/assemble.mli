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

(** Assemble complete network packets from Xen network messages. *)

type fragment = {
  id: int;      (** Ring id of the message this came from. *)
  offset: int;  (** Where the data starts in the page behind it. *)
  size: int;
  gref: int32;  (** The grant naming that page, or [0l] where the page is the
                    reader's own and [id] finds it. *)
}

type packet = {
  total_size: int;
  fragments: fragment list;
  extra_ids: int list;
      (** Ring ids of slots consumed by extra_info descriptors. Such a slot cost
          the reader whatever a slot costs, a page on the receive ring, but
          carries no data and yields no fragment, so a caller that does not
          release these leaks one per aggregated frame.

          Derived by position, which is only sound where the reader assigned the
          ids: valid for a frontend reading responses to its own requests, not
          for a backend reading ids its peer chose. *)
}

val extras_seen : int ref
(** Extra_info descriptors parsed off a ring since boot, across every reader. *)

type assembled = (packet, fragment list) result
(** [Error frags] reports the fragments of a packet that could not be assembled,
    so the caller can release their pages and grants rather than leak them.
    Reading never raises on peer-controlled data. *)

module type IO = sig
  val read_packets :
    with_extras:bool -> ack_fn:((Cstruct.t -> unit) -> unit) -> assembled list
  (** Drains the ring through [ack_fn], which hands over each slot in turn.
      [with_extras] says whether extra_info descriptors may follow a message,
      which is only so once this end has advertised a feature that uses them. *)
end

module RX_IO : IO
(** Receive ring: every response carries the size of its own fragment. *)

module TX_IO : IO
(** Transmit ring: the first request announces the whole packet, and its own
    fragment is what remains once the others are subtracted. *)
