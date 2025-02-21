(** A global collector.

    The collector, if present, is responsible for collecting messages
    and spans, and storing them, recording them, forward them, or
    offering them to other services and processes.
*)

open Types

let dummy_span : span = Int64.min_int

let dummy_explicit_span : explicit_span =
  { span = dummy_span; meta = Meta_map.empty }

(** Signature for a collector.

    This is only relevant to implementors of tracing backends; to instrument
    your code you only need to look at the {!Trace} module. *)
module type S = sig
  val with_span :
    __FUNCTION__:string option ->
    __FILE__:string ->
    __LINE__:int ->
    data:(string * user_data) list ->
    string ->
    (span -> 'a) ->
    'a
  (** Run the function in a new span.

      This replaces the previous [enter_span] and [exit_span] which were too flexible
      to be efficient to implement in async contexts.
     @since 0.3 *)

  val enter_manual_span :
    parent:explicit_span option ->
    flavor:[ `Sync | `Async ] option ->
    __FUNCTION__:string option ->
    __FILE__:string ->
    __LINE__:int ->
    data:(string * user_data) list ->
    string ->
    explicit_span
  (** Enter an explicit span. Surrounding scope, if any, is provided by [parent],
      and this function can store as much metadata as it wants in the hmap
      in the {!explicit_span}'s [meta] field.

      This means that the collector doesn't need to implement contextual
      storage mapping {!span} to scopes, metadata, etc. on its side;
      everything can be transmitted in the {!explicit_span}.
      @since 0.3 *)

  val exit_manual_span : explicit_span -> unit
  (** Exit an explicit span.
      @since 0.3 *)

  val message : ?span:span -> data:(string * user_data) list -> string -> unit
  (** Emit a message with associated metadata. *)

  val name_thread : string -> unit
  (** Give a name to the current thread. *)

  val name_process : string -> unit
  (** Give a name to the current process. *)

  val counter_int : string -> int -> unit
  (** Integer counter. *)

  val counter_float : string -> float -> unit
  (** Float counter. *)

  val shutdown : unit -> unit
  (** Shutdown collector, possibly waiting for it to finish sending data. *)
end
