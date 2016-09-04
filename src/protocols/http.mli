open Core.Std
open Cohttp
open Cohttp_lwt_unix
open Sexplib.Conv

type t = {
  generic : Config_t.config_listener;
  specific : Config_t.config_http_settings;
  sock : Lwt_unix.file_descr;
  close : unit Lwt.u;
  ctx : Cohttp_lwt_unix_net.ctx;
  thread : unit Lwt.t;
} [@@deriving sexp_of]

type http_routing = [
  | `Admin
  | `Standard of (
      chan_name:string ->
      mode:Mode.Pub.t ->
      string Lwt_stream.t ->
      (int, int * string list) Result.t Lwt.t
    )
]

val start :
  Config_t.config_listener ->
  Config_t.config_http_settings ->
  http_routing ->
  t Lwt.t

val stop : t -> unit Lwt.t

val close : t -> unit Lwt.t
