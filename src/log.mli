open Core.Std

val outlog : string
val errlog : string

val int_of_level : Lwt_log.level -> int
val lazy_level : int ref

val stdout : ?section:Lwt_log.section -> Lwt_log.level -> string -> unit Lwt.t
val stderr : ?section:Lwt_log.section -> Lwt_log.level -> string -> unit Lwt.t

module type S =
sig
  val debug : string -> unit Lwt.t
  val info : string -> unit Lwt.t
  val notice : string -> unit Lwt.t
  val warning : string -> unit Lwt.t
  val error : string -> unit Lwt.t
  val fatal : string -> unit Lwt.t

  val debug_lazy : string Lazy.t -> unit Lwt.t
  val info_lazy : string Lazy.t -> unit Lwt.t
  val notice_lazy : string Lazy.t -> unit Lwt.t
  val warning_lazy : string Lazy.t -> unit Lwt.t
  val error_lazy : string Lazy.t -> unit Lwt.t
  val fatal_lazy : string Lazy.t -> unit Lwt.t
end

module type Argument =
sig
  val path : string
  val section : string
end

module Make : functor (Argument : Argument) -> S
