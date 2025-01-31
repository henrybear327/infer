(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(*
 * Utilities to log in "infer_events" key-value scuba table.
 *)
open! IStd

let hostname = Unix.gethostname ()

let maybe_add_normal ~name ~value sample =
  match value with None -> sample | Some value -> Scuba.add_normal ~name ~value sample


let set_command_line_normales sample =
  let add_normal ~key ~data = Scuba.add_normal ~name:key ~value:data in
  Map.fold Config.scuba_normals ~init:sample ~f:add_normal


let set_command_line_tagsets sample =
  let add_tagset ~key ~data = Scuba.add_tagset ~name:key ~value:data in
  Map.fold Config.scuba_tags ~init:sample ~f:add_tagset


let set_common_fields sample =
  let open Scuba in
  sample
  |> add_int ~name:"pid" ~value:(ProcessPoolState.get_pid () |> Pid.to_int)
  |> add_int ~name:"is_main_process" ~value:(Bool.to_int Config.is_originator)
  |> add_normal ~name:"hostname" ~value:hostname
  |> maybe_add_normal ~name:"job_id" ~value:Config.job_id
  |> add_normal ~name:"command" ~value:(InferCommand.to_string Config.command)
  |> add_normal ~name:"infer_commit" ~value:Version.commit
  |> maybe_add_normal ~name:"execution_id"
       ~value:(Option.map ~f:Int64.to_string Config.scuba_execution_id)


let sample_from_event ~loc ({label; created_at_ts; data} : LogEntry.t) =
  let create_sample_with_label label =
    Scuba.new_sample ~time:(Some created_at_ts)
    |> set_common_fields |> set_command_line_normales |> set_command_line_tagsets
    |> Scuba.add_normal ~name:"event" ~value:label
    |> maybe_add_normal ~name:"location" ~value:loc
  in
  match data with
  | Count {value} ->
      create_sample_with_label (Printf.sprintf "count.%s" label)
      |> Scuba.add_int ~name:"value" ~value
  | Time {duration_us} ->
      create_sample_with_label (Printf.sprintf "time.%s" label)
      |> Scuba.add_int ~name:"value" ~value:duration_us
  | String {message} ->
      create_sample_with_label (Printf.sprintf "msg.%s" label)
      |> Scuba.add_normal ~name:"message" ~value:message


(** Consider buffering or batching if proves to be a problem *)
let log_many ~loc entries =
  let samples = List.map entries ~f:(sample_from_event ~loc) in
  Scuba.log Scuba.InferEvents samples


(** If scuba logging is disabled, we would not log anyway, but let's not even try to create samples
    to save perf *)
let log_many ~loc = if Config.scuba_logging then log_many ~loc else fun _ -> ()

let log_one ~loc entry = log_many ~loc [entry]

let log_message ~label ~loc ~message = log_one ~loc (LogEntry.mk_string ~label ~message)

let pulse_log_message ~label ~loc ~message =
  if Config.pulse_scuba_logging then log_message ~label ~loc:(Some loc) ~message


let log_many = log_many ~loc:None

let log_one = log_one ~loc:None

let log_message = log_message ~loc:None

let log_count ~label ~value = log_one (LogEntry.mk_count ~label ~value)

let log_duration ~label ~duration_us = log_one (LogEntry.mk_time ~label ~duration_us)

let cost_log_message ~label ~message = if Config.cost_scuba_logging then log_message ~label ~message

let execute_with_time_logging label f =
  let ret_val, duration = Utils.timeit ~f in
  let duration_us = IMtime.span_to_us_int duration in
  let entry = LogEntry.mk_time ~label ~duration_us in
  log_one entry ;
  ret_val


let flush_log_events () =
  log_many (LogEntry.global_log_get ()) ;
  LogEntry.global_log_erase ()


let register_global_log_flushing_at_exit () =
  Epilogues.register ~f:flush_log_events ~description:"Flushing global log entries to Scuba"
