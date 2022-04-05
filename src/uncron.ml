(** A non-time based job queue service

    Build with: ocamlfind ocamlopt -package lwt,lwt.unix,lwt_ppx,logs,logs.lwt -linkpkg -o uncron ./uncron.ml
 *)

let () = Printexc.record_backtrace true

open Lwt

let (let*) = Lwt.bind

(* Queue *)
module Queue = struct
    type 'a queue = Queue of 'a list * 'a list

    let empty = Queue ([], [])

    let add q item =
        match q with
        | Queue (front, back) -> Queue (item :: front, back)

    let take q =
        match q with
        | Queue ([], []) -> None, empty
        | Queue (front, b :: bs) -> Some b, (Queue (front, bs))
        | Queue (front, []) ->
            let back = List.rev front
            in (Some (List.hd back), Queue ([], List.tl back))
end

(* Shared job queue *)
let queue = ref Queue.empty

let sock_path = "/tmp/uncron.sock"
let backlog = 100

(* Communication functions *)
let handle_message msg =
    let jobs = !queue in
    let jobs = Queue.add jobs msg in
    let () = ignore @@ Logs_lwt.info (fun m -> m "Job \"%s\" was added to the queue" msg) in
    queue := jobs; Printf.sprintf "Job \"%s\" accepted" msg

let handle_connection ic oc () =
    Lwt_io.read_line_opt ic >>=
    (fun msg ->
        match msg with
        | Some msg -> 
            let reply = handle_message msg in
            let* () = Lwt_io.write_line oc reply in
            let* () = Lwt_io.flush oc in
            Lwt_io.close oc
        | None -> Logs_lwt.info (fun m -> m "Connection closed") >>= return)

let accept_connection conn =
    let fd, _ = conn in
    let ic = Lwt_io.of_fd ~mode:Lwt_io.Input fd in
    let oc = Lwt_io.of_fd ~mode:Lwt_io.Output fd in
    Lwt.on_failure (handle_connection ic oc ()) (fun e -> Logs.err (fun m -> m "%s" (Printexc.to_string e)));
    Logs_lwt.info (fun m -> m "New connection") >>= return
 
let delete_socket_if_exists sockfile =
    try
        let _ = Unix.stat sockfile in
        Unix.unlink sockfile
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    | _ -> failwith "Could not delete old socket file, exiting"

(** Bind to a UNIX socket *)
let create_socket sockfile =
    let open Lwt_unix in
    let () = delete_socket_if_exists sockfile in
    let backlog = 100 in
    let* sock = socket PF_UNIX SOCK_STREAM 0 |> Lwt.return in
    let* () = Lwt_unix.bind sock @@ ADDR_UNIX(sockfile) in
    listen sock backlog;
    Lwt.return sock

(* Job handling functions *)
let log_result (res, out, err) =
    let msg =
        (match res with
        | Ok (Unix.WEXITED n) -> Printf.sprintf "Job exited with code %d" n
        | Ok (Unix.WSIGNALED n) -> Printf.sprintf "Job was killed by signal %d" n
        | Ok (Unix.WSTOPPED _) -> "Job stopped"
        | Error msg -> Printf.sprintf "Job execution caused an exception: %s" msg)
    in Logs_lwt.info (fun m -> m "%s\nStdout: %s\nStderr: %s\n" msg out err)

let get_program_output ?(input=None) command env_array =
    (* open_process_full does not automatically pass the existing environment
       to the child process, so we need to add it to our custom environment. *)
    let env_array = Array.append (Unix.environment ()) env_array in
    try
        let std_out, std_in, std_err = Unix.open_process_full command env_array in
        let () =
            begin match input with
            | None -> ()
            | Some i ->
              let () = Printf.fprintf std_in i; flush std_in in
              (* close stdin to signal the end of input *)
              close_out std_in
            end
        in
        let output = CCIO.read_all std_out in
        let err = CCIO.read_all std_err in
        let res = Unix.close_process_full (std_out, std_in, std_err) in
        (Ok res, output, err)
    with
    | Sys_error msg -> (Error (Printf.sprintf "System error: %s" msg), "", "")
    | _ ->
      let msg = Printexc.get_backtrace () in
      (Error msg, "", "")

let run_job job =
    match job with
    | Some j ->
        let* _ = Logs_lwt.info (fun m -> m "Running job \"%s\"" j) in
        let* (res, out, err) = get_program_output j [||] |> Lwt.return in
        let* () = log_result (res, out, err) in
        return ()
    | None -> return_unit

let fetch_job () =
    let jobs = !queue in
    let item, rest = Queue.take jobs in
    match item with
    | None -> return None
    | Some i -> queue := rest; return @@ Some i

let rec run_jobs () =
    fetch_job () >>= run_job >>= (fun () -> Lwt_unix.sleep 1.) >>= run_jobs

let start_runner () =
    Lwt.on_failure (run_jobs ()) (fun e -> Logs.err (fun m -> m "%s" (Printexc.to_string e) ));
    return_unit

let create_server sock =
    let rec serve () =
        Lwt_unix.accept sock >>= accept_connection >>= serve
    in serve

let main_loop () =
    let* sock = create_socket sock_path in
    let* () = start_runner () in
    let serve = create_server sock in
    serve ()

let () =
    let () = print_endline "Starting uncron" in
    let () = Logs.set_reporter (Logs.format_reporter ()) in
    let () = Logs.set_level (Some Logs.Info) in
    Lwt_main.run @@ main_loop ()
