(*
 * Copyright (c) 2015 Thomas Leonard
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

let return = Lwt.return

type block = Gnt.gntref * Cstruct.t
type t = {
  grant : Gnt.gntref -> Io_page.t -> unit;
  mutable blocks : block list;
  mutable in_use : int;
  mutable shutdown : bool;
}

let page_size = Io_page.round_to_page_size 1
let block_size = page_size / 2

let make grant = { grant; blocks = []; shutdown = false; in_use = 0 }

let shutdown t =
  t.shutdown <- true;
  if t.in_use = 0 then (
    t.blocks |> List.iter (fun (gref, block) ->
      if block.Cstruct.off = 0 then (
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
  Gnt.Gntshr.get () >>= fun gnt ->
  t.grant gnt page;
  return (gnt, Io_page.to_cstruct page)

let put t block =
  t.blocks <- block :: t.blocks;
  t.in_use <- t.in_use - 1;
  if t.in_use = 0 && t.shutdown then shutdown t

let use t fn =
  if t.shutdown then
    failwith "Shared_page_pool.use after shutdown";
  begin match t.blocks with
  | [] ->
      (* Frames normally fit within 2048 bytes, so we split each page in half. *)
      alloc t >>= fun (gntref, page) ->
      let b1 = Cstruct.sub page 0 block_size in
      let b2 = Cstruct.shift page block_size in
      t.blocks <- (gntref, b2) :: t.blocks;
      return (gntref, b1)
  | hd :: tl ->
      t.blocks <- tl;
      return hd
  end >>= fun (gntref, block as grant) ->
  t.in_use <- t.in_use + 1;
  Lwt.try_bind
    (fun () -> fn gntref block)
    (fun (_, release as result) ->
      Lwt.on_termination release (fun () -> put t grant);
      return result
    )
    (fun ex -> put t grant; Lwt.fail ex)

let blocks_needed bytes =
  (bytes + block_size - 1) / block_size
