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

module RX_Size_Strategy : SIZE_STRATEGY = struct
  let name = "RX"
  
  let compute_sizes_read ~first_size ~rest_sizes =
    let total = first_size + List.fold_left (+) 0 rest_sizes in
    (total, first_size)
  
  let compute_first_size_write ~total_size:_ ~rest_sizes:_ =
    failwith "RX write uses actual fragment sizes"
end

module TX_Size_Strategy : SIZE_STRATEGY = struct
  let name = "TX"
  
  let compute_sizes_read ~first_size ~rest_sizes =
    let total = first_size in
    let first_frag = first_size - List.fold_left (+) 0 rest_sizes in
    (total, first_frag)
  
  let compute_first_size_write ~total_size ~rest_sizes:_ =
    total_size
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

module RX_Message : MESSAGE with type t = RX.Response.t 
                             and type error = int = struct
  type t = RX.Response.t
  type error = int
  
  let read = RX.Response.read
  let write = RX.Response.write
  let id msg = msg.RX.Response.id
  let offset msg = msg.RX.Response.offset
  let flags msg = msg.RX.Response.flags
  let size msg = msg.RX.Response.size
  let gref _msg = 0l
  let make ~id ~offset ~flags ~size ~gref:_ =
    { RX.Response.id; offset; flags; size = Ok size }
end

module TX_Message : MESSAGE with type t = TX.Request.t 
                             and type error = TX.Request.error = struct
  type t = TX.Request.t
  type error = TX.Request.error
  
  let read = TX.Request.read
  let write = TX.Request.write
  let id msg = msg.TX.Request.id
  let offset msg = msg.TX.Request.offset
  let flags msg = msg.TX.Request.flags
  let size msg = TX.Request.size msg
  let gref msg = msg.TX.Request.gref
  let make ~id ~offset ~flags ~size ~gref =
    { TX.Request.gref; offset; flags; id; size }
end

module Make_Reader(Msg : MESSAGE)(Size : SIZE_STRATEGY) = struct
  
  let collect_messages ack_fn =
    let messages = ref [] in
    
    ack_fn (fun slot ->
      match Msg.read slot with
      | Error e -> Logs.warn (fun f -> f "[%s] Bad msg: %s" Size.name e)
      | Ok msg -> messages := msg :: !messages
    );
    let result = List.rev !messages in
    Log.debug (fun f -> f "[%s.Reader] collect_messages: collected %d messages" 
      Size.name (List.length result));
    result
  
  let rec group_into_packets = function
    | [] -> []
    | msg :: rest ->
        if Flags.(mem more_data) (Msg.flags msg) then
          let frags, remaining = collect_fragments rest in
          make_packet msg frags :: group_into_packets remaining
        else
          make_packet msg [] :: group_into_packets rest
  
  and collect_fragments = function
    | [] -> failwith "Expected more fragments"
    | msg :: rest ->
        if Flags.(mem more_data) (Msg.flags msg) then
          let more, remaining = collect_fragments rest in
          (msg :: more, remaining)
        else ([msg], rest)
  
  and make_packet first_msg continuation_msgs =
    let get_size msg =
      match Msg.size msg with Ok s -> s | Error _ -> failwith "Invalid size"
    in
    let first_size = get_size first_msg in
    let rest_sizes = List.map get_size continuation_msgs in
    let total_size, first_fragment_size = 
      Size.compute_sizes_read ~first_size ~rest_sizes in
    
    let first_fragment = {
      id = Msg.id first_msg;
      offset = Msg.offset first_msg;
      size = first_fragment_size;
      gref = Msg.gref first_msg;
    } in
    
    let rest_fragments = List.map2 (fun msg size ->
      { id = Msg.id msg; offset = Msg.offset msg; size; gref = Msg.gref msg }
    ) continuation_msgs rest_sizes in
    
    { total_size; fragments = first_fragment :: rest_fragments }
  
  let read_packets ack_fn =
    let messages = collect_messages ack_fn in
    let packets = group_into_packets messages in
    Log.debug (fun f -> f "[%s.Reader] read_packets: %d messages -> %d packets" 
      Size.name (List.length messages) (List.length packets));
    packets
end

module Make_Writer(Msg : MESSAGE)(Size : SIZE_STRATEGY) = struct
  
  let write_packet ~get_slot ~packet =
    match packet.fragments with
    | [] -> failwith "Empty packet"
    | first_frag :: rest_frags ->
        Log.debug (fun f -> f "[%s.Writer] write_packet: total_size=%d, %d fragments" 
          Size.name packet.total_size (List.length packet.fragments));
        let rest_sizes = List.map (fun f -> f.size) rest_frags in
        let first_msg_size =
          if rest_frags = [] then first_frag.size
          else Size.compute_first_size_write ~total_size:packet.total_size ~rest_sizes
        in
        
        let first_flags =
          if rest_frags <> [] then Flags.more_data else Flags.empty
        in
        
        let first_slot = get_slot () in
        Msg.make ~id:first_frag.id ~offset:first_frag.offset 
                 ~flags:first_flags ~size:first_msg_size ~gref:first_frag.gref
        |> fun msg -> Msg.write msg first_slot;
        
        List.iteri (fun i frag ->
          let is_last = (i = List.length rest_frags - 1) in
          let flags = if is_last then Flags.empty else Flags.more_data in
          let slot = get_slot () in
          Msg.make ~id:frag.id ~offset:frag.offset ~flags ~size:frag.size ~gref:frag.gref
          |> fun msg -> Msg.write msg slot
        ) rest_frags
end

module RX_Reader = Make_Reader(RX_Message)(RX_Size_Strategy)
module RX_Writer = Make_Writer(RX_Message)(RX_Size_Strategy)
module TX_Reader = Make_Reader(TX_Message)(TX_Size_Strategy)
module TX_Writer = Make_Writer(TX_Message)(TX_Size_Strategy)

module type IO = sig
  val read_packets : ack_fn:((Cstruct.t -> unit) -> unit) -> packet list
  val write_packet : get_slot:(unit -> Cstruct.t) -> packet:packet -> unit
end

module RX_IO : IO = struct
  let read_packets ~ack_fn = RX_Reader.read_packets ack_fn
  let write_packet ~get_slot ~packet = RX_Writer.write_packet ~get_slot ~packet
end

module TX_IO : IO = struct
  let read_packets ~ack_fn = TX_Reader.read_packets ack_fn
  let write_packet ~get_slot ~packet = TX_Writer.write_packet ~get_slot ~packet
end
