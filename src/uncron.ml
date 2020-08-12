(** A non-time based job queue service

    Build with: ocamlfind ocamlopt -package lwt,lwt.unix,lwt_ppx,logs,logs.lwt -linkpkg -o uncron ./uncron.ml
 *)

open Lwt

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
    Logs_lwt.info (fun m -> m "Job \"%s\" was added to the queue" msg);
    queue := jobs; Printf.sprintf "Job \"%s\" accepted" msg

let rec handle_connection ic oc () =
    Lwt_io.read_line_opt ic >>=
    (fun msg ->
        match msg with
        | Some msg -> 
            let reply = handle_message msg in
            Lwt_io.write_line oc reply >>= handle_connection ic oc
        | None -> Logs_lwt.info (fun m -> m "Connection closed") >>= return)

let accept_connection conn =
    let fd, _ = conn in
    let ic = Lwt_io.of_fd Lwt_io.Input fd in
    let oc = Lwt_io.of_fd Lwt_io.Output fd in
    Lwt.on_failure (handle_connection ic oc ()) (fun e -> Logs.err (fun m -> m "%s" (Printexc.to_string e) ));
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
    let%lwt sock = socket PF_UNIX SOCK_STREAM 0 |> Lwt.return in
    let%lwt () = Lwt_unix.bind sock @@ ADDR_UNIX(sockfile) in
    listen sock backlog;
    Lwt.return sock

(* Job handling functions *)
let log_result res =
    let msg =
        (match res with
        | Lwt_unix.WEXITED n -> Printf.sprintf "Job exited with code %d" n
        | Lwt_unix.WSIGNALED n -> Printf.sprintf "Job was killed by signal %d" n
        | Lwt_unix.WSTOPPED _ -> "Job stopped")
    in Logs_lwt.info (fun m -> m "%s" msg)

let run_job job =
    match job with
    | Some j ->
        let%lwt _ = Logs_lwt.info (fun m -> m "Running job \"%s\"" j) in
        let%lwt res = Lwt_unix.system j in
        let%lwt () = log_result res in
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
    let%lwt sock = create_socket sock_path in
    let%lwt () = start_runner () in
    let serve = create_server sock in
    serve ()

let () =
    let () = print_endline "Starting uncron" in
    let () = Logs.set_reporter (Logs.format_reporter ()) in
    let () = Logs.set_level (Some Logs.Info) in
    Lwt_main.run @@ main_loop ()
