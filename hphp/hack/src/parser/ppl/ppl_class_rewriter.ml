(**
 * Copyright (c) 2018, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

(**
 * Hack PPL models are reliant on Hack coroutine functionality but it is not
 * necessary that developers who write Hack PPL models understand the
 * coroutine framework. It is only necessary for inference method authors
 * to understand how Hack PPL models interact with coroutines.
 *
 * In order to abstract away the coroutine framework from model writing,
 * we introduce the class attribute specification <<__PPL>> which will trigger
 * a rewriting step to reintroduce the coroutine syntax. This rewriting step
 * is meant as a temporary measure until longer term, deeper integration is
 * enabled for Hack PPL.
 *)

module Syntax = Full_fidelity_editable_positioned_syntax
module Rewriter = Full_fidelity_rewriter.WithSyntax(Syntax)
(* Includes helpful builders *)
module CoroutineSyntax = Coroutine_syntax
module PPLRewriterSyntax = Ppl_rewriter_syntax

open Syntax
open CoroutineSyntax
open PPLRewriterSyntax

(**
 * Adds the `coroutine` keyword to the beginning of the list of modifiers.
 * This intermediate stage is not syntactically correct and has to be rewritten
 * by the coroutine lowerer.
 *)
let add_coroutine_modifier_to_modifiers_list function_modifiers =
  let modifiers = syntax_node_to_list function_modifiers in
  if List.exists ~f:is_coroutine modifiers
  then failwith "Should not lower methods that are already coroutines"
  else
    let coroutine_token_syntax = make_token_syntax TokenKind.Coroutine in
    let syntax_list =
      coroutine_token_syntax :: syntax_node_to_list function_modifiers in
    make_list syntax_list

(* Adds \PPL\Inference\Infer as the first argument to function parameters *)
let add_infer_receiver_to_parameter_list parameters =
  let infer_type_parameter_syntax =
    make_simple_type_specifier ppl_infer_type_name_syntax in
  let infer_parameter_syntax =
    make_parameter_declaration_syntax
      infer_type_parameter_syntax
      receiver_string in
  prepend_to_comma_delimited_syntax_list
    infer_parameter_syntax
    parameters

(* Adds coroutine modifier and Infer parameter to PPL class methods *)
let rewrite_ppl_method_header method_header =
  match syntax method_header with
  | FunctionDeclarationHeader ({
      function_modifiers;
      function_parameter_list;
      _;
    } as declaration_header) ->
      let function_modifiers =
        add_coroutine_modifier_to_modifiers_list function_modifiers in
      let function_parameter_list =
        add_infer_receiver_to_parameter_list function_parameter_list in
      let new_method_header =
        FunctionDeclarationHeader
          { declaration_header with
            function_modifiers;
            function_parameter_list;
          } in
      Syntax.synthesize_from
        method_header
        new_method_header
  | _ -> failwith "Expected function declaration header"

(* Determines whether a function call receiver is $this or self *)
let is_this_or_self receiver =
  match syntax receiver with
  | MemberSelectionExpression {
      member_object = {
        syntax = VariableExpression {
          variable_expression = {
            syntax = Token token;
            _;
          };
          _;
        };
        _;
      };
      _;
    } when Token.text token = "$this" -> true
  | ScopeResolutionExpression {
      scope_resolution_qualifier = {
        syntax = Token token;
        _;
      };
      _;
    } when Token.text token = "self" -> true
  | _ -> false

(**
 * Rewrites all calls to methods in the class (identified by $this and self)
 * as well as calls to all methods on the \Infer class.
 *)
let rewrite_ppl_method_body method_body suspension_id =
  let rewrite node suspension_id =
    match syntax node with
    (* $this->method_call(...) or self::method_call(...) *)
    | FunctionCallExpression ({
        function_call_receiver;
        function_call_argument_list;
        _;
      } as function_call_expression)
      when is_this_or_self function_call_receiver ->
        let new_function_call_argument_list =
          function_call_argument_list
          |> prepend_to_comma_delimited_syntax_list receiver_variable_syntax in
        let new_function_expression =
          FunctionCallExpression {
            function_call_expression with
            function_call_argument_list = new_function_call_argument_list;
          } in
        let new_function_call_expression_syntax =
          Syntax.synthesize_from
            node
            new_function_expression in
        let new_syntax =
          make_syntax @@
          PrefixUnaryExpression {
            prefix_unary_operator = suspend_token_syntax;
            prefix_unary_operand = new_function_call_expression_syntax;
          } in
        suspension_id, Rewriter.Replace new_syntax
    (* sample(), factor(), observe(), condition() *)
    | FunctionCallExpression ({
        function_call_receiver = {
          syntax = Token token;
          _;
        };
        _;
      } as function_call_expression) when is_infer_method (Token.text token) ->
        let new_function_call_receiver =
          make_member_selection_expression_syntax
            receiver_variable_syntax
            (make_name_syntax (Token.text token)) in
        let new_function_expression =
          FunctionCallExpression {
            function_call_expression with
            function_call_receiver = new_function_call_receiver
          } in
        let new_node = Syntax.synthesize_from node new_function_expression in
        let new_syntax =
          make_syntax @@
          PrefixUnaryExpression {
            prefix_unary_operator = suspend_token_syntax;
            prefix_unary_operand = new_node;
          } in
        suspension_id + 1, Rewriter.Replace new_syntax
    | _ -> suspension_id, Rewriter.Keep
  in
  Rewriter.aggregating_rewrite_post rewrite method_body suspension_id

(* Matches the __PPL macro *)
let is_ppl_attribute attribute =
  match syntax attribute with
  | ListItem {
      list_item = {
        syntax = Attribute {
          attribute_name = {
            syntax = Token token;
            _;
          };
          _;
        };
        _;
      };
      _;
    } when Token.text token = ppl_macro_string -> true
  | _ -> false

(* Rewrites a class annotated with the __PPL macro *)
let rewrite_ppl_class_body classish_body =
  let rewrite_ppl_class_method class_method acc =
    match syntax class_method with
    | MethodishDeclaration ({
        methodish_function_decl_header = ({
          syntax = FunctionDeclarationHeader {
            function_modifiers = m;
            _;
          };
          _;
        } as methodish_function_decl_header);
        methodish_function_body;
        _;
      } as method_declaration) when not @@ has_coroutine_modifier m ->
        let new_method_header =
          rewrite_ppl_method_header methodish_function_decl_header in
        let acc, new_method_body =
          rewrite_ppl_method_body methodish_function_body acc in
        let new_class_method =
          MethodishDeclaration
            { method_declaration with
              methodish_function_decl_header = new_method_header;
              methodish_function_body = new_method_body;
            } in
        let new_node = Syntax.synthesize_from class_method new_class_method in
        acc, Rewriter.Replace new_node
    | _ -> acc, Rewriter.Keep
  in
  Rewriter.rewrite_pre_and_stop_with_acc
    rewrite_ppl_class_method
    classish_body
    0

(* Determines whether a list of attributes has the __PPL macro *)
let has_ppl_attribute attributes =
  match syntax attributes with
  | AttributeSpecification {
      attribute_specification_attributes;
      _;
    } ->
      let attribute_list =
        syntax_node_to_list attribute_specification_attributes in
      List.exists ~f:is_ppl_attribute attribute_list
  | _ -> false

(* Removes the macro when lowering the code to coroutines *)
let remove_ppl_attribute attributes =
  match syntax attributes with
  | AttributeSpecification ({
      attribute_specification_attributes;
      _;
    } as attribute_specification) ->
      let attribute_list =
        syntax_node_to_list attribute_specification_attributes in
      let new_attribute_list =
        List.filter ~f:(fun a -> not @@ is_ppl_attribute a) attribute_list in
      if List.length new_attribute_list = 0
      then make_missing ()
      else
        let new_syntax =
          AttributeSpecification {
            attribute_specification with
            attribute_specification_attributes = make_list new_attribute_list
          } in
        Syntax.synthesize_from
          attributes
          new_syntax
  | _ -> failwith "Expected Attribute Specification"

(* Rewrites all classes annotated with the __PPL macro in a list *)
let rewrite_all_declarations declaration_list =
  let rewrite_declaration declaration =
    match syntax declaration with
    | ClassishDeclaration ({
        classish_attribute;
        classish_body;
        _;
      } as class_declaration) when has_ppl_attribute classish_attribute ->
      let _, new_classish_body = rewrite_ppl_class_body classish_body in
      let new_attributes = remove_ppl_attribute classish_attribute in
      let new_class_declaration =
        ClassishDeclaration
          { class_declaration with classish_body = new_classish_body
          ; classish_attribute = new_attributes
          } in
      let new_node = Syntax.synthesize_from declaration new_class_declaration in
      Rewriter.Replace new_node
    | _ -> Rewriter.Keep
  in
  List.map
    ~f:(Rewriter.rewrite_pre_and_stop rewrite_declaration)
    declaration_list

(* Rewrites all classes with the __PPL macro in a file *)
let rewrite_ppl_classes root =
  match syntax root with
  | Script { script_declarations; } ->
    let declarations = syntax_node_to_list script_declarations in
    begin match declarations with
    | hh_decl :: declarations ->
      let rewritten_declarations = rewrite_all_declarations declarations in
      make_script (make_list (hh_decl :: rewritten_declarations))
    | _ -> failwith "How did we get a script with no header element?" end
  | _ -> failwith "How did we get a root that is not a script?"
