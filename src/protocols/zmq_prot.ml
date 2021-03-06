open Core.Std
open Lwt

module Logger = Log.Make (struct let path = Log.outlog let section = "Zmq" end)

type worker = {
  accept: unit Lwt.t;
  socket: [`Dealer] Lwt_zmq.Socket.t;
}

type t = {
  generic : Config_t.config_listener;
  specific : Config_t.config_zmq_settings;
  inproc: string;
  inbound: string;
  frontend: [`Router] ZMQ.Socket.t;
  backend: [`Dealer] ZMQ.Socket.t;
  workers: worker array;
  proxy: unit Lwt.t;
  stop_w: unit Lwt.u;
  ctx: ZMQ.Context.t;
}
let sexp_of_t zmq =
  let open Config_t in
  Sexp.List [
    Sexp.List [
      Sexp.Atom zmq.generic.name;
      Sexp.Atom zmq.generic.host;
      Sexp.Atom (Int.to_string zmq.generic.port);
    ];
    Sexp.List [
      Sexp.Atom (Int.to_string zmq.specific.concurrency);
    ];
  ]

let ctx = ZMQ.Context.create ()
let () = ZMQ.Context.set_io_threads ctx 1

let invalid_read_output = Zmq_obj_pb.({ length = 0; last_id = None; last_timens = None })

let handler zmq routing socket frames =
  let open Routing in
  let%lwt zmq = zmq in
  match frames with
  | header::id::meta::msgs ->
    let open Zmq_obj_pb in

    let%lwt (output, messages) = begin try%lwt
        let input = decode_input (Pbrt.Decoder.of_bytes meta) in
        let chan_name = input.channel in
        begin match input.action with

          | Write_input write ->
            let ids = Array.of_list write.ids in
            let msgs = Array.of_list msgs in
            let%lwt (errors, saved) =
              begin match%lwt routing.write_zmq ~chan_name ~ids ~msgs ~atomic:write.atomic with
                | Ok ((Some _) as count) -> return ([], count)
                | Ok None -> return ([], None)
                | Error errors -> return (errors, (Some 0))
              end
            in
            return ({ errors; action = Write_output { saved } }, [||])

          | Read_input read ->
            let%lwt (errors, read_output, messages) = begin match Mode.of_string read.mode with
              | Error str -> return ([str], invalid_read_output, [||])
              | Ok parsed_mode ->
                begin match Mode.wrap (parsed_mode :> Mode.Any.t) with
                  | `Read mode ->
                    begin match%lwt routing.read_slice ~chan_name ~mode ~limit:read.limit with
                      | Error errors -> return (errors, invalid_read_output, [||])
                      | Ok (slice, _) ->
                        let open Persistence in
                        let read_output = {
                          length = Array.length slice.payloads;
                          last_id = Option.map slice.metadata ~f:(fun m -> m.last_id);
                          last_timens = Option.map slice.metadata ~f:(fun m -> m.last_timens);
                        }
                        in
                        return ([], read_output, slice.payloads)
                    end
                  | _ ->
                    return (
                      [sprintf "[%s] is not a valid Reading mode" (Mode.to_string (parsed_mode :> Mode.Any.t))],
                      invalid_read_output,
                      [||]
                    )
                end
            end
            in
            return ({ errors; action = Read_output read_output }, messages)

          | Count_input ->
            let%lwt (errors, count) =
              begin match%lwt routing.count ~chan_name ~mode:`Count with
                | Ok count -> return ([], Some count)
                | Error errors -> return (errors, None)
              end
            in
            return ({ errors; action = Count_output { count } }, [||])

          | Delete_input ->
            let%lwt errors =
              begin match%lwt routing.delete ~chan_name ~mode:`Delete with
                | Ok () -> return []
                | Error errors -> return errors
              end
            in
            return ({ errors; action = Delete_output }, [||])

          | Health_input health ->
            let chan_name = if health.global then None else Some chan_name in
            let%lwt errors = routing.health ~chan_name ~mode:`Health in
            return ({ errors; action = Health_output }, [||])

        end
      with
      | ex ->
        let error = begin match ex with
          | Protobuf.Decoder.Failure err -> sprintf "Protobuf Decoder Error: %s" (Protobuf.Decoder.error_to_string err)
          | Failure str -> str
          | ex -> Exn.to_string ex
        end
        in
        return ({ errors = [error]; action = Error_output }, [||])
    end
    in
    let encoder = Pbrt.Encoder.create () in
    encode_output output encoder;
    let reply = Pbrt.Encoder.to_bytes encoder in
    begin match messages with
      | [||] -> Lwt_zmq.Socket.send_all socket [header; id; reply]
      | msgs ->
        (* TODO: Benchmark this *)
        Lwt_zmq.Socket.send_all socket ([header; id; reply] @ (Array.to_list messages))
    end

  | strs ->
    let printable = Yojson.Basic.to_string (`List (List.map ~f:(fun s -> `String s) strs)) in
    let%lwt () = Logger.warning (sprintf "Received invalid msg parts on %s: %s" zmq.inbound printable) in
    let error = sprintf "Received invalid msg parts on %s. Expected [id], [meta], [msgs...]." zmq.inbound in
    Lwt_zmq.Socket.send_all socket (strs @ [error])

let set_hwm sock receive send =
  ZMQ.Socket.set_receive_high_water_mark sock receive;
  ZMQ.Socket.set_send_high_water_mark sock send

let start generic specific routing =
  let open Config_t in
  let open Routing in
  let inproc = sprintf "inproc://%s" generic.name in
  let inbound = sprintf "tcp://%s:%d" generic.host generic.port in
  let (instance_t, instance_w) = wait () in
  let (stop_t, stop_w) = wait () in

  let frontend = ZMQ.Socket.create ctx ZMQ.Socket.router in
  ZMQ.Socket.bind frontend inbound;
  set_hwm frontend specific.receive_hwm specific.send_hwm;
  let backend = ZMQ.Socket.create ctx ZMQ.Socket.dealer in
  ZMQ.Socket.bind backend inproc;

  let proxy = Lwt_preemptive.detach (fun () ->
      ZMQ.Proxy.create frontend backend;
    ) ()
  in
  async (fun () -> pick [stop_t; proxy]);

  (* TODO: Configurable timeout for disconnected clients *)
  (* print_endline (sprintf "send timeout %d" (ZMQ.Socket.get_send_timeout frontend)); *)
  (* print_endline (sprintf "receive timeout %d" (ZMQ.Socket.get_receive_timeout frontend)); *)

  let%lwt callback = match routing with
    | Admin _ -> fail_with "ZMQ listeners don't support Admin routing"
    | Standard standard_routing -> return (handler instance_t standard_routing)
  in

  let workers = Array.init specific.concurrency (fun _ ->
      let sock = ZMQ.Socket.create ctx ZMQ.Socket.dealer in
      ZMQ.Socket.connect sock inproc;
      let socket = Lwt_zmq.Socket.of_socket sock in
      let rec loop socket =
        let%lwt () = try%lwt
            let%lwt frames = Lwt_zmq.Socket.recv_all socket in
            callback socket frames
          with
          | ex -> Logger.error (Exn.to_string ex)
        in
        loop socket
      in
      let accept = loop socket in
      async (fun () -> accept);
      { socket; accept; }
    )
  in
  let instance = {
    generic;
    specific;
    inproc;
    inbound;
    frontend;
    backend;
    workers;
    proxy;
    stop_w;
    ctx;
  }
  in
  wakeup instance_w instance;
  return instance

let stop zmq =
  Array.iter zmq.workers ~f:(fun worker ->
    cancel worker.accept
  );
  return_unit

let close zmq =
  let%lwt () = stop zmq in
  if is_sleeping (waiter_of_wakener zmq.stop_w) then wakeup zmq.stop_w ();
  ZMQ.Socket.unbind zmq.frontend zmq.inbound;
  ZMQ.Socket.unbind zmq.backend zmq.inproc;
  ZMQ.Socket.close zmq.frontend;
  ZMQ.Socket.close zmq.backend;
  Array.iter zmq.workers ~f:(fun worker ->
    let sock = Lwt_zmq.Socket.to_socket worker.socket in
    ZMQ.Socket.disconnect sock zmq.inproc;
    ZMQ.Socket.close sock
  );
  return_unit
