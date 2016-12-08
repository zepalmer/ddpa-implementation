open Batteries;;
open Jhupllib;;

open Core_ast;;
open Ddpa_abstract_ast;;
open Ddpa_context_stack;;
open Ddpa_graph;;
open Ddpa_utils;;
open Pds_reachability_types_stack;;

let logger = Logger_utils.make_logger "Ddpa_pds_edge_functions";;
let lazy_logger = Logger_utils.make_lazy_logger "Ddpa_pds_edge_functions";;

module Make
    (C : Context_stack)
    (S : (module type of Ddpa_pds_structure_types.Make(C)) with module C = C)
    (T : (module type of Ddpa_pds_dynamic_pop_types.Make(C)(S))
     with module C = C
      and module S = S)
    (B : Pds_reachability_basis.Basis)
    (R : Pds_reachability_analysis.Analysis
     with type State.t = S.Pds_state.t
      and type Targeted_dynamic_pop_action.t = T.pds_targeted_dynamic_pop_action)
=
struct
  open S;;
  open T;;

  (**
     Creates a PDS edge function for a particular DDPA graph edge.  The
     resulting function produces transitions for PDS states, essentially serving
     as the first step toward implementing each DDPA rule.  The remaining steps
     are addressed by the dynamic pop handler, which performs the closure of the
     dynamic pops generated by this function.
  *)
  let create_edge_function
      (eobm : End_of_block_map.t) (edge : ddpa_edge) (state : R.State.t) =
    (* Unpack the edge *)
    let Ddpa_edge(acl1, acl0) = edge in
    (* Generate PDS edge functions for this DDPA edge *)
    Logger_utils.lazy_bracket_log (lazy_logger `trace)
      (fun () -> Printf.sprintf "DDPA %s edge function at state %s"
          (show_ddpa_edge edge) (Pds_state.show state))
      (fun edges ->
         let string_of_output (actions,target) =
           String_utils.string_of_tuple
             (String_utils.string_of_list R.show_stack_action)
             Pds_state.show
             (actions,target)
         in
         Printf.sprintf "Generates edges: %s"
           (String_utils.string_of_list string_of_output @@
            List.of_enum @@ Enum.clone edges)) @@
    fun () ->
    let zero = Enum.empty in
    let%orzero Program_point_state(acl0',ctx) = state in
    (* TODO: There should be a way to associate each edge function with
             its corresponding acl0 rather than using this guard. *)
    [%guard (compare_annotated_clause acl0 acl0' == 0) ];
    let open Option.Monad in
    let zero () = None in
    (* TODO: It'd be nice if we had a terser way to represent stack
             processing operations (those that simply reorder the stack
             without transitioning to a different node). *)
    let targeted_dynamic_pops = Enum.filter_map identity @@ List.enum
        [
          (* 1b. Value drop *)
          begin
            return (Value_drop, Program_point_state(acl0,ctx))
          end
          ;
          (* 2a. Transitivity *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x, Abs_var_body x'))) = acl1
            in
            (* x = x' *)
            return (Variable_aliasing(x,x'),Program_point_state(acl1,ctx))
          end
          ;
          (* 2b. Stateless non-matching clause skip *)
          begin
            let%orzero (Unannotated_clause(Abs_clause(x,_))) = acl1 in
            (* x' = b *)
            return ( Stateless_nonmatching_clause_skip_1_of_2 x
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 2c. Skip block start and end: this is handled below as a
                 special case because it does not involve a pop. *)
          (* 3b. Value capture *)
          begin
            return ( Value_capture_1_of_3
                   , Program_point_state(acl0, ctx)
                   )
          end
          ;
          (* 3c. Rewind *)
          begin
            (*
              To rewind, we need to know the "end-of-block" for the node we are
              considering.  We have a dictionary mapping all of the *abstract*
              clauses in the program to their end-of-block clauses, but we don't
              have such mappings for e.g. wiring nodes or block start/end nodes.
              This code runs for *every* edge, so we need to skip those cases
              for which our mappings don't exist.  It's safe to skip all
              non-abstract-clause nodes, since we only rewind after looking up
              a function to access its closure and the only nodes that can
              complete a lookup are abstract clause nodes.
            *)
            match acl0 with
            | Unannotated_clause cl0 ->
              begin
                match Annotated_clause_map.Exceptionless.find acl0 eobm with
                | Some end_of_block ->
                  return ( Rewind_step(end_of_block, ctx)
                         , Program_point_state(acl0, ctx)
                         )
                | None ->
                  raise @@ Utils.Invariant_failure(
                    Printf.sprintf
                      "Abstract clause lacks end-of-block mapping: %s"
                      (show_abstract_clause cl0))
              end
            | Start_clause _ | End_clause _ | Enter_clause _ | Exit_clause _ ->
              (*
                These clauses can be safely ignored because they never complete
                a lookup and so won't ever be the subject of a rewind.
              *)
              zero ()
          end
          ;
          (* 4a. Function parameter wiring *)
          begin
            let%orzero (Enter_clause(x,x',c)) = acl1 in
            let%orzero (Abs_clause(_,Abs_appl_body (_,x3''))) = c in
            begin
              if not (equal_var x' x3'') then
                raise @@ Utils.Invariant_failure "Ill-formed wiring node."
              else
                ()
            end;
            (* x =(down)c x' *)
            [%guard C.is_top c ctx];
            let ctx' = C.pop ctx in
            return (Variable_aliasing(x,x'),Program_point_state(acl1,ctx'))
          end
          ;
          (* 4b. Function return wiring start *)
          begin
            let%orzero (Exit_clause(x,_,c)) = acl1 in
            let%orzero (Abs_clause(x1'',Abs_appl_body(x2'',x3''))) = c in
            begin
              if not (equal_var x x1'') then
                raise @@ Utils.Invariant_failure "Ill-formed wiring node."
              else
                ()
            end;
            (* x =(up)c _ (for functions) *)
            return ( Function_call_flow_validation(x2'',x3'',acl0,ctx,Unannotated_clause(c),ctx,x)
                   , Program_point_state(Unannotated_clause(c),ctx)
                   )
          end
          ;
          (* 4c. Function return wiring finish *)
          begin
            let%orzero (Exit_clause(x,x',c)) = acl1 in
            let%orzero (Abs_clause(x1'',Abs_appl_body _)) = c in
            begin
              if not (equal_var x x1'') then
                raise @@ Utils.Invariant_failure "Ill-formed wiring node."
              else
                ()
            end;
            (* x =(up)c x' *)
            let ctx' = C.push c ctx in
            return ( Function_call_flow_validation_resolution_1_of_2(x,x')
                   , Program_point_state(acl1,ctx')
                   )
          end
          ;
          (* 4d. Function non-local wiring *)
          begin
            let%orzero (Enter_clause(x'',x',c)) = acl1 in
            let%orzero (Abs_clause(_,Abs_appl_body(x2'',x3''))) = c in
            begin
              if not (equal_var x' x3'') then
                raise @@ Utils.Invariant_failure "Ill-formed wiring node."
              else
                ()
            end;
            (* x'' =(down)c x' *)
            [%guard C.is_top c ctx];
            let ctx' = C.pop ctx in
            return ( Function_closure_lookup(x'',x2'')
                   , Program_point_state(acl1,ctx')
                   )
          end
          ;
          (* 5a, 5b, and 5e. Conditional entrance wiring *)
          begin
            (* This block represents *all* conditional closure handling on
               the entering side. *)
            let%orzero (Enter_clause(x',x1,c)) = acl1 in
            let%orzero
              (Abs_clause(_,Abs_conditional_body(x1',p,f1,_))) = c
            in
            begin
              if not (equal_var x1 x1') then
                raise @@ Utils.Invariant_failure "Ill-formed wiring node."
              else
                ()
            end;
            let Abs_function_value(f1x,_) = f1 in
            (* x'' =(down)c x' for conditionals *)
            let closure_for_positive_path = equal_var f1x x' in
            return ( Conditional_closure_lookup
                       (x',x1,p,closure_for_positive_path)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 5c, 5d. Conditional return wiring *)
          begin
            let%orzero (Exit_clause(x,x',c)) = acl1 in
            let%orzero
              (Abs_clause(x2,Abs_conditional_body(x1,pat,f1,_))) = c
            in
            begin
              if not (equal_var x x2) then
                raise @@ Utils.Invariant_failure "Ill-formed wiring node."
              else
                ()
            end;
            (* x =(up) x' for conditionals *)
            let Abs_function_value(_,Abs_expr(cls)) = f1 in
            let f1ret = rv cls in
            let then_branch = equal_var f1ret x' in
            return ( Conditional_subject_validation(
                x,x',x1,pat,then_branch,acl1,ctx)
                   , Program_point_state(Unannotated_clause(c),ctx)
              )
          end
          ;
          (* 6a. Record destruction *)
          begin
            let%orzero
              (Unannotated_clause(
                  Abs_clause(x,Abs_projection_body(x',l)))) = acl1
            in
            (* x = x'.l *)
            return ( Record_projection_lookup(x,x',l)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 6b. Record projection *)
          begin
            return ( Record_projection_1_of_2
                   , Program_point_state(acl0,ctx)
                   )
          end
          ;
          (* 7a. Function filter validation *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   x,Abs_value_body(Abs_value_function(v))))) = acl1
            in
            (* x = f *)
            return ( Function_filter_validation(x,v)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 7b. Record validation *)
          begin
            let%orzero
              (Unannotated_clause(
                  Abs_clause(x,Abs_value_body(Abs_value_record(r))))) = acl1
            in
            (* x = r *)
            let target_state = Program_point_state(acl1,ctx) in
            return ( Record_filter_validation(
                x,r,acl1,ctx)
                   , target_state
              )
          end
          ;
          (* 7c. Integer filter validation *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   x,Abs_value_body(Abs_value_int)))) = acl1
            in
            (* x = int *)
            return ( Int_filter_validation(x)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 7d, 7e. Boolean filter validation *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   x,Abs_value_body(Abs_value_bool(b))))) = acl1
            in
            (* x = true OR x = false *)
            return ( Bool_filter_validation(x,b)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 7f. String filter validation *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   x,Abs_value_body(Abs_value_string)))) = acl1
            in
            (* x = <string> *)
            return ( String_filter_validation(x)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 8a. Assignment result *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x, Abs_update_body _))) = acl1
            in
            (* x = x' <- x'' -- produce {} for x *)
            return ( Empty_record_value_discovery x
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 8b. Dereference lookup *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x, Abs_deref_body(x')))) = acl1
            in
            (* x = !x' *)
            return ( Dereference_lookup(x,x')
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 8c. Cell validation *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   x,Abs_value_body(Abs_value_ref(cell))))) = acl1
            in
            (* x = ref x' *)
            return ( Cell_filter_validation(x,cell)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ;
          (* 8d. Cell dereference *)
          begin
            return ( Cell_dereference_1_of_2
                   , Program_point_state(acl0, ctx) )
          end
          ;
          (* 9a. Cell update alias analysis initialization *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   _, Abs_update_body(x',_)))) = acl1
            in
            (* x''' = x' <- x'' *)
            let source_state = Program_point_state(acl1,ctx) in
            let target_state = Program_point_state(acl0,ctx) in
            return ( Cell_update_alias_analysis_init_1_of_2(
                x',source_state,target_state)
                   , Program_point_state(acl0, ctx) )
          end
          ; (* 9b,9c. Alias resolution *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(
                   _, Abs_update_body(_,x'')))) = acl1
            in
            (* x''' = x' <- x'' *)
            return ( Alias_analysis_resolution_1_of_5(x'')
                   , Program_point_state(acl1, ctx) )
          end
          ; (* 10a. Stateful non-side-effecting clause skip *)
          begin
            let%orzero (Unannotated_clause(Abs_clause(x,b))) = acl1 in
            [% guard (is_immediate acl1) ];
            [% guard (b |>
                      (function
                        | Abs_update_body _ -> false
                        | _ -> true)) ];
            (* x' = b *)
            return ( Nonsideeffecting_nonmatching_clause_skip x
                   , Program_point_state(acl1,ctx)
                   )
          end
          ; (* 10b. Side-effect search initialization *)
          begin
            let%orzero (Exit_clause(x'',_,c)) = acl1 in
            (* x'' =(up)c x' *)
            let%bind ctx' =
              match c with
              | Abs_clause(_,Abs_appl_body _) -> return @@ C.push c ctx
              | Abs_clause(_,Abs_conditional_body _) -> return ctx
              | _ -> zero ()
            in
            return ( Side_effect_search_init_1_of_2(x'',acl0,ctx)
                   , Program_point_state(acl1,ctx') )
          end
          ; (* 10c. Side-effect search non-matching clause skip *)
          begin
            let%orzero (Unannotated_clause(Abs_clause(_,b))) = acl1 in
            [% guard (is_immediate acl1) ];
            [% guard (b |>
                      (function
                        | Abs_update_body _ -> false
                        | _ -> true)) ];
            (* x' = b *)
            return ( Side_effect_search_nonmatching_clause_skip
                   , Program_point_state(acl1,ctx) )
          end
          ; (* 10d. Side-effect search exit wiring node *)
          begin
            let%orzero (Exit_clause(_,_,c)) = acl1 in
            (* x'' =(up)c x' *)
            let%bind ctx' =
              match c with
              | Abs_clause(_,Abs_appl_body _) -> return @@ C.push c ctx
              | Abs_clause(_,Abs_conditional_body _) -> return ctx
              | _ -> zero ()
            in
            return ( Side_effect_search_exit_wiring
                   , Program_point_state(acl1,ctx') )
          end
          ; (* 10e. Side-effect search enter wiring node *)
          begin
            let%orzero (Enter_clause(_,_,c)) = acl1 in
            (* x'' =(down)c x' *)
            let%bind ctx' =
              match c with
              | Abs_clause(_,Abs_appl_body _) -> return @@ C.pop ctx
              | Abs_clause(_,Abs_conditional_body _) -> return ctx
              | _ -> zero ()
            in
            return ( Side_effect_search_enter_wiring
                   , Program_point_state(acl1,ctx') )
          end
          (* FIXME: why does this clause kill performance? *)
          ; (* 10f. Side-effect search without discovery *)
          begin
            return ( Side_effect_search_without_discovery
                   , Program_point_state(acl0,ctx) )
          end
          ; (* 10g. Side-effect search alias analysis initialization *)
          begin
            let%orzero (Unannotated_clause(
                Abs_clause(_,Abs_update_body(x',_)))) = acl1
            in
            return ( Side_effect_search_alias_analysis_init(x',acl0,ctx)
                   , Program_point_state(acl1,ctx) )
          end
          ; (* 10h,10i. Side-effect search alias analysis resolution *)
          begin
            let%orzero (Unannotated_clause(
                Abs_clause(_,Abs_update_body(_,x'')))) = acl1
            in
            return ( Side_effect_search_alias_analysis_resolution_1_of_4(
                x'')
                   , Program_point_state(acl1,ctx) )
          end
          ; (* 10j. Side-effect search escape *)
          begin
            return ( Side_effect_search_escape_1_of_2
                   , Program_point_state(acl0,ctx) )
          end
          ; (* 10k. Side-effect search escape completion *)
          begin
            return ( Side_effect_search_escape_completion_1_of_4
                   , Program_point_state(acl0,ctx) )
          end
          ; (* 11a. Binary operation operand lookup *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x1,
                                             Abs_binary_operation_body(x2,_,x3)))) = acl1
            in
            (* x1 = x2 op x3 *)
            return ( Binary_operator_lookup_init(
                x1,x2,x3,acl1,ctx,acl0,ctx)
                   , Program_point_state(acl1,ctx)
              )
          end
          ; (* 11b. Unary operation operand lookup *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x1,
                                             Abs_unary_operation_body(_,x2)))) = acl1
            in
            (* x1 = op x2 *)
            return ( Unary_operator_lookup_init(
                x1,x2,acl0,ctx)
                   , Program_point_state(acl1,ctx)
              )
          end
          ; (* 11c. Indexing lookup *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x1,
                                             Abs_indexing_body(x2,x3)))) = acl1
            in
            (* x1 = x2[x3] *)
            return ( Indexing_lookup_init(
                x1,x2,x3,acl1,ctx,acl0,ctx)
                   , Program_point_state(acl1,ctx)
              )
          end
          ; (* 12a,12b,12c,13a,13b,13c,13d,13e,13f,13g,13h,13i,13j,13k,13l,14a,14b,14c. Binary operator resolution *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x1,
                                             Abs_binary_operation_body(_,op,_)))) = acl1
            in
            (* x1 = x2 op x3 *)
            return ( Binary_operator_resolution_1_of_4(x1,op)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ; (* 13m,13n. Unary operator resolution *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x1,
                                             Abs_unary_operation_body(op,_)))) = acl1
            in
            (* x1 = op x2 *)
            return ( Unary_operator_resolution_1_of_3(x1,op)
                   , Program_point_state(acl1,ctx)
                   )
          end
          ; (* 14d. Indexing resolution *)
          begin
            let%orzero
              (Unannotated_clause(Abs_clause(x1,
                                             Abs_indexing_body(_,_)))) = acl1
            in
            (* x1 = x2[x3] *)
            return ( Indexing_resolution_1_of_4(x1)
                   , Program_point_state(acl1,ctx)
                   )
          end
        ]
    in
    let nop_states =
      match acl1 with
      | Start_clause _ | End_clause _ ->
        Enum.singleton @@ Program_point_state(acl1,ctx)
      | _ -> Enum.empty ()
    in
    Enum.append
      (targeted_dynamic_pops
       |> Enum.map
         (fun (action,state) -> ([Pop_dynamic_targeted(action)], state)))
      (nop_states
       |> Enum.map
         (fun state -> ([], state)))
  ;;

  let create_untargeted_dynamic_pop_action_function
      (edge : ddpa_edge) (state : R.State.t) =
    let Ddpa_edge(_, acl0) = edge in
    let zero = Enum.empty in
    let%orzero Program_point_state(acl0',_) = state in
    (* TODO: There should be a way to associate each action function with
             its corresponding acl0 rather than using this guard. *)
    [%guard (compare_annotated_clause acl0 acl0' == 0)];
    let open Option.Monad in
    let untargeted_dynamic_pops = Enum.filter_map identity @@ List.enum
        [
          (* 1a. Value discovery. *)
          begin
            return @@ Value_discovery_1_of_2
          end
          ;
          (* 3a. Jump. *)
          begin
            return @@ Do_jump
          end
        ]
    in
    untargeted_dynamic_pops
  ;;

end;;