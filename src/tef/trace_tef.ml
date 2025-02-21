open Trace_core
module A = Trace_core.Internal_.Atomic_

module Mock_ = struct
  let enabled = ref false
  let now = ref 0

  let[@inline never] now_us () : float =
    let x = !now in
    incr now;
    float_of_int x
end

let counter = Mtime_clock.counter ()

(** Now, in microseconds *)
let now_us () : float =
  if !Mock_.enabled then
    Mock_.now_us ()
  else (
    let t = Mtime_clock.count counter in
    Mtime.Span.to_float_ns t /. 1e3
  )

let protect ~finally f =
  try
    let x = f () in
    finally ();
    x
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    finally ();
    Printexc.raise_with_backtrace exn bt

type event =
  | E_tick
  | E_message of {
      tid: int;
      msg: string;
      time_us: float;
      data: (string * user_data) list;
    }
  | E_define_span of {
      tid: int;
      name: string;
      time_us: float;
      id: span;
      fun_name: string option;
      data: (string * user_data) list;
    }
  | E_exit_span of {
      id: span;
      time_us: float;
    }
  | E_enter_manual_span of {
      tid: int;
      name: string;
      time_us: float;
      id: int;
      flavor: [ `Sync | `Async ] option;
      fun_name: string option;
      data: (string * user_data) list;
    }
  | E_exit_manual_span of {
      tid: int;
      name: string;
      time_us: float;
      flavor: [ `Sync | `Async ] option;
      id: int;
    }
  | E_counter of {
      name: string;
      tid: int;
      time_us: float;
      n: float;
    }
  | E_name_process of { name: string }
  | E_name_thread of {
      tid: int;
      name: string;
    }

module Span_tbl = Hashtbl.Make (struct
  include Int64

  let hash : t -> int = Hashtbl.hash
end)

type span_info = {
  tid: int;
  name: string;
  start_us: float;
  data: (string * user_data) list;
}

(** key used to carry a unique "id" for all spans in an async context *)
let key_async_id : int Meta_map.Key.t = Meta_map.Key.create ()

let key_async_data : (string * [ `Sync | `Async ] option) Meta_map.Key.t =
  Meta_map.Key.create ()

module Writer = struct
  type t = {
    oc: out_channel;
    mutable first: bool;  (** first event? *)
    must_close: bool;
    pid: int;
  }

  let create ~out () : t =
    let oc, must_close =
      match out with
      | `Stdout -> stdout, false
      | `Stderr -> stderr, false
      | `File path -> open_out path, true
    in
    let pid =
      if !Mock_.enabled then
        2
      else
        Unix.getpid ()
    in
    output_char oc '[';
    { oc; first = true; pid; must_close }

  let close (self : t) : unit =
    output_char self.oc ']';
    flush self.oc;
    if self.must_close then close_out self.oc

  let[@inline] flush (self : t) : unit = flush self.oc

  let emit_sep_ (self : t) =
    if self.first then
      self.first <- false
    else
      output_string self.oc ",\n"

  let char = output_char
  let raw_string = output_string

  let str_val oc (s : string) =
    char oc '"';
    let encode_char c =
      match c with
      | '"' -> raw_string oc {|\"|}
      | '\\' -> raw_string oc {|\\|}
      | '\n' -> raw_string oc {|\n|}
      | '\b' -> raw_string oc {|\b|}
      | '\r' -> raw_string oc {|\r|}
      | '\t' -> raw_string oc {|\t|}
      | _ when Char.code c <= 0x1f ->
        raw_string oc {|\u00|};
        Printf.fprintf oc "%02x" (Char.code c)
      | c -> char oc c
    in
    String.iter encode_char s;
    char oc '"'

  let pp_user_data_ out : [< user_data | `Float of float ] -> unit = function
    | `None -> Printf.fprintf out "null"
    | `Int i -> Printf.fprintf out "%d" i
    | `Bool b -> Printf.fprintf out "%b" b
    | `String s -> str_val out s
    | `Float f -> Printf.fprintf out "%g" f

  (* emit args, if not empty. [ppv] is used to print values. *)
  let emit_args_o_ ppv oc args : unit =
    if args <> [] then (
      Printf.fprintf oc {json|,"args": {|json};
      List.iteri
        (fun i (n, value) ->
          if i > 0 then Printf.fprintf oc ",";
          Printf.fprintf oc {json|"%s":%a|json} n ppv value)
        args;
      char oc '}'
    )

  let emit_duration_event ~tid ~name ~start ~end_ ~args (self : t) : unit =
    let dur = end_ -. start in
    let ts = start in
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"cat":"","tid": %d,"dur": %.2f,"ts": %.2f,"name":%a,"ph":"X"%a}|json}
      self.pid tid dur ts str_val name
      (emit_args_o_ pp_user_data_)
      args;
    ()

  let emit_manual_begin ~tid ~name ~id ~ts ~args ~flavor (self : t) : unit =
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"cat":"trace","id":%d,"tid": %d,"ts": %.2f,"name":%a,"ph":"%c"%a}|json}
      self.pid id tid ts str_val name
      (match flavor with
      | None | Some `Async -> 'b'
      | Some `Sync -> 'B')
      (emit_args_o_ pp_user_data_)
      args;
    ()

  let emit_manual_end ~tid ~name ~id ~ts ~flavor (self : t) : unit =
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"cat":"trace","id":%d,"tid": %d,"ts": %.2f,"name":%a,"ph":"%c"}|json}
      self.pid id tid ts str_val name
      (match flavor with
      | None | Some `Async -> 'e'
      | Some `Sync -> 'E');

    ()

  let emit_instant_event ~tid ~name ~ts ~args (self : t) : unit =
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"cat":"","tid": %d,"ts": %.2f,"name":%a,"ph":"I"%a}|json}
      self.pid tid ts str_val name
      (emit_args_o_ pp_user_data_)
      args;
    ()

  let emit_name_thread ~tid ~name (self : t) : unit =
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"tid": %d,"name":"thread_name","ph":"M"%a}|json} self.pid
      tid
      (emit_args_o_ pp_user_data_)
      [ "name", `String name ];
    ()

  let emit_name_process ~name (self : t) : unit =
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"name":"process_name","ph":"M"%a}|json} self.pid
      (emit_args_o_ pp_user_data_)
      [ "name", `String name ];
    ()

  let emit_counter ~name ~tid ~ts (self : t) f : unit =
    emit_sep_ self;
    Printf.fprintf self.oc
      {json|{"pid":%d,"tid":%d,"ts":%.2f,"name":"c","ph":"C"%a}|json} self.pid
      tid ts
      (emit_args_o_ pp_user_data_)
      [ name, `Float f ];
    ()
end

let bg_thread ~out (events : event B_queue.t) : unit =
  let writer = Writer.create ~out () in
  protect ~finally:(fun () -> Writer.close writer) @@ fun () ->
  let spans : span_info Span_tbl.t = Span_tbl.create 32 in
  let local_q = Queue.create () in

  (* add function name, if provided, to the metadata *)
  let add_fun_name_ fun_name data : _ list =
    match fun_name with
    | None -> data
    | Some f -> ("function", `String f) :: data
  in

  (* how to deal with an event *)
  let handle_ev (ev : event) : unit =
    match ev with
    | E_tick -> Writer.flush writer
    | E_message { tid; msg; time_us; data } ->
      Writer.emit_instant_event ~tid ~name:msg ~ts:time_us ~args:data writer
    | E_define_span { tid; name; id; time_us; fun_name; data } ->
      (* save the span so we find it at exit *)
      let data = add_fun_name_ fun_name data in
      Span_tbl.add spans id { tid; name; start_us = time_us; data }
    | E_exit_span { id; time_us = stop_us } ->
      (match Span_tbl.find_opt spans id with
      | None -> (* bug! TODO: emit warning *) ()
      | Some { tid; name; start_us; data } ->
        Span_tbl.remove spans id;
        Writer.emit_duration_event ~tid ~name ~start:start_us ~end_:stop_us
          ~args:data writer)
    | E_enter_manual_span { tid; time_us; name; id; data; fun_name; flavor } ->
      let data = add_fun_name_ fun_name data in
      Writer.emit_manual_begin ~tid ~name ~id ~ts:time_us ~args:data ~flavor
        writer
    | E_exit_manual_span { tid; time_us; name; id; flavor } ->
      Writer.emit_manual_end ~tid ~name ~id ~ts:time_us ~flavor writer
    | E_counter { tid; name; time_us; n } ->
      Writer.emit_counter ~name ~tid ~ts:time_us writer n
    | E_name_process { name } -> Writer.emit_name_process ~name writer
    | E_name_thread { tid; name } -> Writer.emit_name_thread ~tid ~name writer
  in

  try
    while true do
      (* work on local events, already on this thread *)
      while not (Queue.is_empty local_q) do
        let ev = Queue.pop local_q in
        handle_ev ev
      done;

      (* get all the events in the incoming blocking queue, in
         one single critical section. *)
      B_queue.transfer events local_q
    done
  with B_queue.Closed ->
    (* warn if app didn't close all spans *)
    if Span_tbl.length spans > 0 then
      Printf.eprintf "trace-tef: warning: %d spans were not closed\n%!"
        (Span_tbl.length spans);
    ()

let tick_thread events : unit =
  try
    while true do
      Thread.delay 0.5;
      B_queue.push events E_tick
    done
  with B_queue.Closed -> ()

type output =
  [ `Stdout
  | `Stderr
  | `File of string
  ]

let collector ~out () : collector =
  let module M = struct
    let active = A.make true

    (** generator for span ids *)
    let span_id_gen_ = A.make 0

    (* queue of messages to write *)
    let events : event B_queue.t = B_queue.create ()

    (** writer thread. It receives events and writes them to [oc]. *)
    let t_write : Thread.t = Thread.create (fun () -> bg_thread ~out events) ()

    (** ticker thread, regularly sends a message to the writer thread.
         no need to join it. *)
    let _t_tick : Thread.t = Thread.create (fun () -> tick_thread events) ()

    let shutdown () =
      if A.exchange active false then (
        B_queue.close events;
        Thread.join t_write
      )

    let get_tid_ () : int =
      if !Mock_.enabled then
        3
      else
        Thread.id (Thread.self ())

    let with_span ~__FUNCTION__:fun_name ~__FILE__:_ ~__LINE__:_ ~data name f =
      let span = Int64.of_int (A.fetch_and_add span_id_gen_ 1) in
      let tid = get_tid_ () in
      let time_us = now_us () in
      B_queue.push events
        (E_define_span { tid; name; time_us; id = span; fun_name; data });

      let finally () =
        let time_us = now_us () in
        B_queue.push events (E_exit_span { id = span; time_us })
      in

      Fun.protect ~finally (fun () -> f span)

    let enter_manual_span ~(parent : explicit_span option) ~flavor
        ~__FUNCTION__:fun_name ~__FILE__:_ ~__LINE__:_ ~data name :
        explicit_span =
      (* get the id, or make a new one *)
      let id =
        match parent with
        | Some m -> Meta_map.find_exn key_async_id m.meta
        | None -> A.fetch_and_add span_id_gen_ 1
      in
      let time_us = now_us () in
      B_queue.push events
        (E_enter_manual_span
           { id; time_us; tid = get_tid_ (); data; name; fun_name; flavor });
      {
        span = 0L;
        meta =
          Meta_map.(
            empty |> add key_async_id id |> add key_async_data (name, flavor));
      }

    let exit_manual_span (es : explicit_span) : unit =
      let id = Meta_map.find_exn key_async_id es.meta in
      let name, flavor = Meta_map.find_exn key_async_data es.meta in
      let time_us = now_us () in
      let tid = get_tid_ () in
      B_queue.push events
        (E_exit_manual_span { tid; id; name; time_us; flavor })

    let message ?span:_ ~data msg : unit =
      let time_us = now_us () in
      let tid = get_tid_ () in
      B_queue.push events (E_message { tid; time_us; msg; data })

    let counter_float name f =
      let time_us = now_us () in
      let tid = get_tid_ () in
      B_queue.push events (E_counter { name; n = f; time_us; tid })

    let counter_int name i = counter_float name (float_of_int i)
    let name_process name : unit = B_queue.push events (E_name_process { name })

    let name_thread name : unit =
      let tid = get_tid_ () in
      B_queue.push events (E_name_thread { tid; name })
  end in
  (module M)

let setup ?(out = `Env) () =
  match out with
  | `Stderr -> Trace_core.setup_collector @@ collector ~out:`Stderr ()
  | `Stdout -> Trace_core.setup_collector @@ collector ~out:`Stdout ()
  | `File path -> Trace_core.setup_collector @@ collector ~out:(`File path) ()
  | `Env ->
    (match Sys.getenv_opt "TRACE" with
    | Some "1" ->
      let path = "trace.json" in
      let c = collector ~out:(`File path) () in
      Trace_core.setup_collector c
    | Some "stdout" -> Trace_core.setup_collector @@ collector ~out:`Stdout ()
    | Some "stderr" -> Trace_core.setup_collector @@ collector ~out:`Stderr ()
    | Some path ->
      let c = collector ~out:(`File path) () in
      Trace_core.setup_collector c
    | None -> ())

let with_setup ?out () f =
  setup ?out ();
  protect ~finally:Trace_core.shutdown f

module Internal_ = struct
  let mock_all_ () = Mock_.enabled := true
end
