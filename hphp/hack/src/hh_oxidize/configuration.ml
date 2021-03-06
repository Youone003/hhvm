(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel
open Reordered_argument_collections

type t = {
  by_ref: bool;
  extern_types: string SMap.t;
}

let default = { extern_types = SMap.empty; by_ref = false }

let config : t option ref = ref None

let set t =
  if Option.is_some !config then failwith "Config already set";
  config := Some t

let by_ref () = (Option.value_exn !config).by_ref

let extern_type type_name =
  "" :: State.curr_module_name () :: Output.glob_uses ()
  |> List.find_map ~f:(fun mod_name ->
         let maybe_qualified_type =
           if mod_name = "" then
             type_name
           else
             mod_name ^ "::" ^ type_name
         in
         SMap.find_opt
           (Option.value_exn !config).extern_types
           maybe_qualified_type)
