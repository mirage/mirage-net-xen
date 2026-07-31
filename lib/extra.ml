(* Descriptor types, from io/netif.h. Naming them matters more than it looks:
   the values are adjacent and a wrong one is silent, since the peer simply
   reads the descriptor it has been told it is holding. *)
let type_none = 0
let type_gso = 1
let type_mcast_add = 2
let type_mcast_del = 3
let type_hash = 4

type t = {
  typ : int;       (* uint8 *)
  flags : int;     (* uint8 *)
  gso_size : int;  (* uint16 *)
  gso_type : int;  (* uint8 *)
  gso_pad : int;   (* uint8 *)
}

let get_extra_type c = Cstruct.get_uint8 c 0
let get_extra_flags c = Cstruct.get_uint8 c 1
let get_extra_gso_size c = Cstruct.LE.get_uint16 c 2
let get_extra_gso_type c = Cstruct.get_uint8 c 4
let get_extra_gso_pad c = Cstruct.get_uint8 c 5

let set_extra_type c typ = Cstruct.set_uint8 c 0 typ
let set_extra_flags c flags = Cstruct.set_uint8 c 1 flags
let set_extra_gso_size c size = Cstruct.LE.set_uint16 c 2 size
let set_extra_gso_type c typ = Cstruct.set_uint8 c 4 typ
let set_extra_gso_pad c pad = Cstruct.set_uint8 c 5 pad

let read slot =
  let typ = get_extra_type slot in
  let flags = get_extra_flags slot in
  if typ = type_gso then (
    let gso_size = get_extra_gso_size slot in
    let gso_type = get_extra_gso_type slot in (* GSO type = 1 for TCPv4 *)
    let gso_pad = get_extra_gso_pad slot in
    Ok { typ; flags; gso_size; gso_type; gso_pad }
  ) else (
    Ok { typ; flags; gso_size=0; gso_type=0; gso_pad=0 }
  )

let write t slot =
  set_extra_type slot t.typ;
  set_extra_flags slot t.flags;
  if t.typ = type_gso then (
    set_extra_gso_size slot t.gso_size;
    set_extra_gso_type slot t.gso_type;
    set_extra_gso_pad slot t.gso_pad
  )
