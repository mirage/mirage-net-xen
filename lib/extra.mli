type t = {
  typ : int;       (* uint8 *)
  flags : int;     (* uint8 *)
  gso_size : int;  (* uint16 *)
  gso_type : int;  (* uint8 *)
  gso_pad : int;   (* uint8 *)
}

val read: Cstruct.t -> (t, string) result
val write: t -> Cstruct.t -> unit
