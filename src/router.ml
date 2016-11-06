open Core.Std
open Lwt

module Logger = Log.Make (struct let path = Log.outlog let section = "Router" end)

type t = {
  table: Channel.t String.Table.t String.Table.t; (* Channels (accessed by name) by listener.id *)
} [@@deriving sexp]

let create () =
  let table = String.Table.create () in
  (* Register the catch-all private listener *)
  let data = String.Table.create () in
  String.Table.add_exn table ~key:Listener.(private_listener.id) ~data;
  {table}

let register_listeners router listeners =
  let open Listener in
  List.filter_map listeners ~f:(fun listen ->
    let entry = String.Table.create () in
    match String.Table.add router.table ~key:listen.id ~data:entry with
    | `Ok -> None
    | `Duplicate -> Some (Printf.sprintf "Cannot register listener %s because it already exists" listen.id)
  )
  |> fun ll -> if List.length ll = 0 then Ok () else Error ll

(* Important: At this time, listeners must exist prior to adding channels *)
let register_channels router channels =
  let open Channel in
  List.concat_map channels ~f:(fun chan ->
    (* Every channel also registers with the private listener *)
    let chan_endpoints = Listener.(private_listener.id) :: chan.endpoint_names in
    List.filter_map chan_endpoints ~f:(fun listen_name ->
      match String.Table.find router.table listen_name with
      | Some chan_table ->
        begin match String.Table.add chan_table ~key:chan.name ~data:chan with
          | `Ok -> None
          | `Duplicate -> Some (
              Printf.sprintf
                "Registered channel %s with listener %s but another channel with the same name already existed"
                chan.name listen_name
            )
        end
      | None -> Some (Printf.sprintf "Cannot add channel %s to %s. Does that listener exist?" chan.name listen_name)
    ))
  |> function
  | [] -> Ok ()
  | errors -> Error errors

let find_chan router ~listen_name ~chan_name =
  match String.Table.find router.table listen_name with
  | None -> Error [Printf.sprintf "Unknown listener \'%s\'" listen_name]
  | Some chan_table ->
    begin match String.Table.find chan_table chan_name with
      | None -> Error [Printf.sprintf "No channel \'%s\' associated with listener \'%s\'" chan_name listen_name]
      | Some chan -> Ok chan
    end

let write router ~listen_name ~chan_name ~id_header ~mode stream =
  match find_chan router ~listen_name ~chan_name with
  | (Error _) as err -> return err
  | Ok chan ->
    let open Channel in
    begin match chan.write with
      | None -> return (Error [Printf.sprintf "Channel %s doesn't support Writing to it." chan_name])
      | Some write ->
        let open Write_settings in

        (* For JSON: Read the whole body, then generate IDs if needed *)
        (* For Plaintext: Use the stream parser *)
        let%lwt parsed = begin match write.format with
          | Io_format.Json ->
            let%lwt str = Util.stream_to_string ~buffer_size:chan.buffer_size stream in
            let open Config_j in
            begin match Util.parse_json input_message_of_string str with
              | (Error _) as err -> return ([| |], err)
              | Ok { atomic; messages; ids } ->
                let msgs = Message.of_string_array ~atomic messages in
                let mode = if Bool.(=) atomic true then `Atomic else `Multiple in
                begin match ids with
                  | Some ids -> return (msgs, Ok (Array.map ~f:Id.of_string ids))
                  | None -> return (msgs, (Id.array_of_string_opt ~mode ~msgs None))
                end
            end
          | Io_format.Plaintext ->
            let%lwt msgs = Message.of_stream ~format:write.format ~mode ~sep:chan.separator ~buffer_size:chan.buffer_size stream in
            let ids = Id.array_of_string_opt ~mode ~msgs id_header in
            return (msgs, ids)
        end in
        begin match parsed with
          | (msgs, Error str) -> return (Error [str])
          | (msgs, Ok ids) ->
            begin match ((Array.length msgs), (Array.length ids)) with
              | (msgs_l, ids_l) when Int.(<>) msgs_l ids_l -> return (Error [Printf.sprintf "Length mismatch between messages (%d) and IDs (%d)" msgs_l ids_l])
              | _ ->
                (* Now write to the channel *)
                let save_t =
                  let%lwt count = Channel.push chan msgs ids in
                  ignore_result (Logger.debug_lazy (lazy (
                      Printf.sprintf "Wrote: %s (length: %d) %s from %s" (Mode.Write.to_string mode) count chan_name listen_name
                    )));
                  (* Copy to other channels if needed. *)
                  let%lwt () = Lwt_list.iter_p (fun copy_chan_name ->
                      begin match find_chan router ~listen_name:Listener.(private_listener.id) ~chan_name:copy_chan_name with
                        | Error _ -> Logger.warning_lazy (lazy (Printf.sprintf "Cannot copy from %s to %s because %s doesn't exist." chan_name copy_chan_name copy_chan_name))
                        | Ok copy_chan ->
                          let%lwt copy_count = Channel.push copy_chan msgs ids in
                          if copy_count <> count then async (fun () ->
                              Logger.warning_lazy (lazy (Printf.sprintf "Mismatch while copying from %s (wrote %d) to %s (wrote %d). Possible ID collision(s)." chan_name count copy_chan_name copy_count)
                              ));
                          return_unit
                      end
                    ) write.copy_to in
                  return (Ok (Some count))
                in
                begin match write.ack with
                  | Saved -> save_t
                  | Instant -> return (Ok None)
                end
            end
        end
    end

let read_slice router ~listen_name ~chan_name ~id_header ~mode =
  match find_chan router ~listen_name ~chan_name with
  | (Error _) as err -> return err
  | Ok chan ->
    begin match chan.Channel.read with
      | None -> return (Error [Printf.sprintf "Channel %s doesn't support Reading from it." chan_name])
      | Some read ->
        let%lwt slice = Channel.pull_slice chan ~mode ~only_once:read.Read_settings.only_once in
        ignore_result (Logger.debug_lazy (lazy (
            Printf.sprintf "Read: %s (size: %d) from %s" chan_name (Array.length slice.Persistence.payloads) listen_name
          )));
        return (Ok (slice, chan))
    end

let read_stream router ~listen_name ~chan_name ~id_header ~mode =
  match find_chan router ~listen_name ~chan_name with
  | (Error _) as err -> return err
  | Ok chan ->
    begin match chan.Channel.read with
      | None -> return (Error [Printf.sprintf "Channel %s doesn't support Reading from it." chan_name])
      | Some read ->
        let%lwt stream = Channel.pull_stream chan ~mode ~only_once:read.Read_settings.only_once in
        ignore_result (Logger.debug_lazy (lazy (
            Printf.sprintf "Reading: %s (stream) from %s" chan_name listen_name
          )));
        return (Ok (stream, chan))
    end

let count router ~listen_name ~chan_name ~(mode: Mode.Count.t) =
  match find_chan router ~listen_name ~chan_name with
  | (Error _) as err -> return err
  | Ok chan ->
    begin match chan.Channel.read with
      | None -> return (Error [Printf.sprintf "Channel %s doesn't support Reading from it." chan_name])
      | Some read ->
        let%lwt count = Channel.size chan () in
        ignore_result (Logger.debug_lazy (lazy (
            Printf.sprintf "Counted: %s (size: %Ld) from %s" chan_name count listen_name
          )));
        return (Ok count)
    end
