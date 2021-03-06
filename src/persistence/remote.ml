open Core.Std
open Lwt
open Cohttp
open Cohttp_lwt_unix

type remote_t = {
  base_urls: Uri.t array;
  base_headers: Header.t;
  input_format: Http_format.t;
  output_format: Http_format.t;
  chan_separator: string;
} [@@deriving sexp]

let create base_urls base_headers ~input ~output ~chan_separator =
  let base_urls = Array.map ~f:Uri.of_string base_urls in
  let base_headers = Config_t.(
      Header.add_list
        (Header.init ())
        (List.map ~f:(fun pair -> (pair.key, pair.value)) base_headers)
    )
  in
  let input_format = Http_format.create input in
  let output_format = Http_format.create output in
  let instance = { base_urls; base_headers; input_format; output_format; chan_separator; } in
  return instance

let get_base instance =
  let arr = instance.base_urls in
  Array.get arr (Random.int (Array.length arr))

module M = struct

  type t = remote_t [@@deriving sexp]

  let close instance = return_unit

  let push instance ~msgs ~ids =
    let open Json_obj_j in
    (* Body *)
    let payload = match instance.input_format with
      | Http_format.Plaintext ->
        String.concat_array ~sep:instance.chan_separator (Array.map ~f:B64.encode msgs)
      | Http_format.Json ->
        string_of_input { atomic = false; messages = msgs; ids = Some ids; }
    in
    let body = Cohttp_lwt_body.of_string payload in

    (* Headers *)
    let headers = match instance.input_format with
      | Http_format.Plaintext ->
        let mode_string = if Int.(=) (Array.length ids) 1 then "single" else "multiple" in
        Header.add_list instance.base_headers [
          Header_names.mode, mode_string;
          Header_names.id, (String.concat_array ~sep:Id.default_separator ids);
        ]
      | Http_format.Json ->
        Header.add instance.base_headers Header_names.mode "multiple"
    in

    (* Call *)
    let uri = get_base instance in
    let%lwt (response, body) = Client.call ~headers ~body ~chunked:false `POST uri in
    let%lwt body_str = Cohttp_lwt_body.to_string body in
    let%lwt parsed = Util.parse_async write_of_string body_str in
    match parsed.errors with
    | [] -> return (Option.value ~default:0 parsed.saved)
    | errors -> fail_with (String.concat ~sep:", " errors)

  let pull instance ~search ~fetch_last =
    let open Json_obj_j in
    let open Persistence in
    let (mode, limit) = match search with
      | { filters = [| ((`After_id _) as mode) |]; limit; _ }
      | { filters = [| ((`After_ts _) as mode) |]; limit; _ } -> (mode, limit)
      | { limit; _ } -> ((`Many limit), limit)
    in
    let headers = Header.add_list instance.base_headers [
        Header_names.mode, (Mode.Read.to_string mode);
        Header_names.limit, (Int64.to_string limit);
      ] in

    (* Call *)
    let uri = get_base instance in
    let%lwt (response, body) = Client.call ~headers ~chunked:false `GET uri in
    let%lwt body_str = Cohttp_lwt_body.to_string body in
    let response_headers = Response.headers response in
    let%lwt (errors, messages) = match ((Response.status response), (instance.output_format)) with
      | `No_content, _ -> return ([], [| |])
      | _, Http_format.Plaintext ->
        begin match Header.get response_headers "content-type" with
          | Some "application/json" ->
            let%lwt parsed = Util.parse_async errors_of_string body_str in
            return (parsed.errors, [| |])
          | _ ->
            let msgs = Util.split ~sep:instance.chan_separator body_str in
            return ([], Array.of_list_map ~f:B64.decode msgs)
        end
      | _, Http_format.Json ->
        let%lwt parsed = Util.parse_async read_of_string body_str in
        return (parsed.errors, parsed.messages)
    in
    match errors with
    | [] ->
      let last_ts = Util.header_name_to_int64_opt response_headers Header_names.last_ts in
      let last_row_data = begin match ((Header.get response_headers Header_names.last_id), last_ts)
        with
        | (Some last_id), (Some last_timens) -> Some (last_id, last_timens)
        | _ -> None
      end
      in
      return (messages, None, last_row_data)
    | errors -> fail_with (String.concat ~sep:", " errors)

  let size instance =
    let open Json_obj_j in
    let headers = instance.base_headers in
    let uri = Util.append_to_path (get_base instance) "count" in
    let%lwt (response, body) = Client.call ~headers ~chunked:false `GET uri in
    let%lwt body_str = Cohttp_lwt_body.to_string body in
    let%lwt parsed = Util.parse_async count_of_string body_str in
    match parsed.errors with
    | [] -> return (Option.value ~default:Int64.zero parsed.count)
    | errors -> fail_with (String.concat ~sep:", " errors)

  let delete instance =
    let open Json_obj_j in
    let headers = instance.base_headers in
    let uri = Util.append_to_path (get_base instance) "delete" in
    let%lwt (response, body) = Client.call ~headers ~chunked:false `DELETE uri in
    let%lwt body_str = Cohttp_lwt_body.to_string body in
    let%lwt parsed = Util.parse_async errors_of_string body_str in
    match parsed.errors with
    | [] -> return_unit
    | errors -> fail_with (String.concat ~sep:", " errors)

  let health instance =
    let open Json_obj_j in
    let headers = instance.base_headers in
    let uri = Util.append_to_path (get_base instance) "health" in
    try%lwt
      let%lwt (response, body) = Client.call ~headers ~chunked:false `GET uri in
      let%lwt body_str = Cohttp_lwt_body.to_string body in
      let%lwt parsed = Util.parse_async errors_of_string body_str in
      begin match parsed.errors with
        | [] ->
          begin match parsed.code, parsed.errors with
            | (200, []) -> return []
            | (_, errors) -> return errors
          end
        | errors -> return errors
      end
    with
    | Unix.Unix_error (c, n, _) -> return [Fs.format_unix_exn c n (Uri.to_string uri)]
    | err -> return [Exn.to_string err]

end
