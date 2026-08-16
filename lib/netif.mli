module Make (C : S.CONFIGURATION) : sig
  include Mirage_net.S

  (* For Frontend *)
  val connect : string -> t Lwt.t

  (* For Backend *)
  val make_backend : domid:int -> device_id:int -> t Lwt.t
  val frontend_mac : t -> Macaddr.t
end
