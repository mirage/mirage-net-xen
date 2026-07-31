(** Descriptor types, from io/netif.h. *)

val type_none : int
val type_gso : int
val type_mcast_add : int
val type_mcast_del : int
val type_hash : int

type t = {
  typ : int;       (* uint8 *)
  flags : int;     (* uint8 *)
  gso_size : int;  (* uint16 *)
  gso_type : int;  (* uint8 *)
  gso_pad : int;   (* uint8 *)
}

val read: Cstruct.t -> (t, string) result
val write: t -> Cstruct.t -> unit
