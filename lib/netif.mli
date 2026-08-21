module Make (C : S.CONFIGURATION) : sig
  include Mirage_net.S

  val max_frame_size : t -> int
  (** [max_frame_size t] is the largest [size] that {!write} will carry as a
      single frame. It counts the ethernet header, unlike {!mtu}, and is not
      part of [Mirage_net.S], so only a caller that knows this driver can use
      it. It exceeds the mtu only where the peer has agreed to segment for us.
      It says nothing about receiving. *)

  (* For Frontend *)
  val connect : string -> t Lwt.t

  (* For Backend *)
  (* Fires once the connection is over and torn down. The vif still exists, so the
     caller may connect again - that is how a guest that closes gets its network back. *)
  val make_backend :
    ?on_closed:(unit -> unit Lwt.t) -> domid:int -> device_id:int -> unit -> t Lwt.t
  val frontend_mac : t -> Macaddr.t
end
