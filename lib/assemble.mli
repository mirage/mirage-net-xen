(*
 * Copyright (c) 2015 Thomas Leonard <talex5@gmail.com>
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
  id: int;
  offset: int;
  size: int;
  gref: int32;
}

type packet = {
  total_size: int;
  fragments: fragment list;
}


module type SIZE_STRATEGY = sig
  val name : string
  
  val compute_sizes_read : 
    first_size:int -> rest_sizes:int list -> (int * int)
  
  val compute_first_size_write :
    total_size:int -> rest_sizes:int list -> int
end

module type MESSAGE = sig
  type t
  type error
  
  val read : Cstruct.t -> (t, string) result
  val write : t -> Cstruct.t -> unit
  val id : t -> int
  val offset : t -> int
  val flags : t -> Flags.t
  val size : t -> (int, error) result
  val gref : t -> int32
  val make : id:int -> offset:int -> flags:Flags.t -> size:int -> gref:int32 -> t
end

module type IO = sig
  val read_packets : ack_fn:((Cstruct.t -> unit) -> unit) -> packet list
  val write_packet : get_slot:(unit -> Cstruct.t) -> packet:packet -> unit
end

module RX_IO : IO
module TX_IO : IO
