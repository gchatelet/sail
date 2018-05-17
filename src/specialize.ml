(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Ast_util
open Rewriter

let is_typ_ord_uvar = function
  | Type_check.U_typ _ -> true
  | Type_check.U_order _ -> true
  | _ -> false

let rec nexp_simp_typ (Typ_aux (typ_aux, l)) =
  let typ_aux = match typ_aux with
    | Typ_id v -> Typ_id v
    | Typ_var kid -> Typ_var kid
    | Typ_tup typs -> Typ_tup (List.map nexp_simp_typ typs)
    | Typ_app (f, args) -> Typ_app (f, List.map nexp_simp_typ_arg args)
    | Typ_exist (kids, nc, typ) -> Typ_exist (kids, nc, nexp_simp_typ typ)
    | Typ_fn (typ1, typ2, effect) -> Typ_fn (nexp_simp_typ typ1, nexp_simp_typ typ2, effect)
  in
  Typ_aux (typ_aux, l)
and nexp_simp_typ_arg (Typ_arg_aux (typ_arg_aux, l)) =
  let typ_arg_aux = match typ_arg_aux with
    | Typ_arg_nexp n -> Typ_arg_nexp (nexp_simp n)
    | Typ_arg_typ typ -> Typ_arg_typ (nexp_simp_typ typ)
    | Typ_arg_order ord -> Typ_arg_order ord
  in
  Typ_arg_aux (typ_arg_aux, l)

let nexp_simp_uvar = function
  | Type_check.U_nexp nexp -> (prerr_endline ("Simp nexp " ^ string_of_nexp nexp); Type_check.U_nexp (nexp_simp nexp))
  | Type_check.U_typ typ -> Type_check.U_typ (nexp_simp_typ typ)
  | uvar -> uvar

(* We have to be careful about whether the typechecker has renamed anything returned by instantiation_of.
   This part of the typechecker API is a bit ugly. *)
let fix_instantiation instantiation =
  let instantiation = KBindings.bindings (KBindings.filter (fun _ uvar -> is_typ_ord_uvar uvar) instantiation) in
  let instantiation = List.map (fun (kid, uvar) -> Type_check.orig_kid kid, nexp_simp_uvar uvar) instantiation in
  List.fold_left (fun m (k, v) -> KBindings.add k v m) KBindings.empty instantiation

let rec polymorphic_functions is_kopt (Defs defs) =
  match defs with
  | DEF_spec (VS_aux (VS_val_spec (TypSchm_aux (TypSchm_ts (typq, typ) , _), id, _, externs), _)) :: defs ->
     let is_type_polymorphic = List.exists is_kopt (quant_kopts typq) in
     if is_type_polymorphic then
       IdSet.add id (polymorphic_functions is_kopt (Defs defs))
     else
       polymorphic_functions is_kopt (Defs defs)
  | _ :: defs -> polymorphic_functions is_kopt (Defs defs)
  | [] -> IdSet.empty

let string_of_instantiation instantiation =
  let open Type_check in
  let kid_names = ref KBindings.empty in
  let kid_counter = ref 0 in
  let kid_name kid =
    try KBindings.find kid !kid_names with
    | Not_found -> begin
        let n = string_of_int !kid_counter in
        kid_names := KBindings.add kid n !kid_names;
        incr kid_counter;
        n
      end
  in

  (* We need custom string_of functions to ensure that alpha-equivalent definitions get the same name *)
  let rec string_of_nexp = function
    | Nexp_aux (nexp, _) -> string_of_nexp_aux nexp
  and string_of_nexp_aux = function
    | Nexp_id id -> string_of_id id
    | Nexp_var kid -> kid_name kid
    | Nexp_constant c -> Big_int.to_string c
    | Nexp_times (n1, n2) -> "(" ^ string_of_nexp n1 ^ " * " ^ string_of_nexp n2 ^ ")"
    | Nexp_sum (n1, n2) -> "(" ^ string_of_nexp n1 ^ " + " ^ string_of_nexp n2 ^ ")"
    | Nexp_minus (n1, n2) -> "(" ^ string_of_nexp n1 ^ " - " ^ string_of_nexp n2 ^ ")"
    | Nexp_app (id, nexps) -> string_of_id id ^ "(" ^ Util.string_of_list ", " string_of_nexp nexps ^ ")"
    | Nexp_exp n -> "2 ^ " ^ string_of_nexp n
    | Nexp_neg n -> "- " ^ string_of_nexp n
  in

  let rec string_of_typ = function
    | Typ_aux (typ, l) -> string_of_typ_aux typ
  and string_of_typ_aux = function
    | Typ_id id -> string_of_id id
    | Typ_var kid -> kid_name kid
    | Typ_tup typs -> "(" ^ Util.string_of_list ", " string_of_typ typs ^ ")"
    | Typ_app (id, args) -> string_of_id id ^ "(" ^ Util.string_of_list ", " string_of_typ_arg args ^ ")"
    | Typ_fn (typ_arg, typ_ret, eff) ->
       string_of_typ typ_arg ^ " -> " ^ string_of_typ typ_ret ^ " effect " ^ string_of_effect eff
    | Typ_exist (kids, nc, typ) ->
       "exist " ^ Util.string_of_list " " kid_name kids ^ ", " ^ string_of_n_constraint nc ^ ". " ^ string_of_typ typ
  and string_of_typ_arg = function
    | Typ_arg_aux (typ_arg, l) -> string_of_typ_arg_aux typ_arg
  and string_of_typ_arg_aux = function
    | Typ_arg_nexp n -> string_of_nexp n
    | Typ_arg_typ typ -> string_of_typ typ
    | Typ_arg_order o -> string_of_order o
  and string_of_n_constraint = function
    | NC_aux (NC_equal (n1, n2), _) -> string_of_nexp n1 ^ " = " ^ string_of_nexp n2
    | NC_aux (NC_not_equal (n1, n2), _) -> string_of_nexp n1 ^ " != " ^ string_of_nexp n2
    | NC_aux (NC_bounded_ge (n1, n2), _) -> string_of_nexp n1 ^ " >= " ^ string_of_nexp n2
    | NC_aux (NC_bounded_le (n1, n2), _) -> string_of_nexp n1 ^ " <= " ^ string_of_nexp n2
    | NC_aux (NC_or (nc1, nc2), _) ->
       "(" ^ string_of_n_constraint nc1 ^ " | " ^ string_of_n_constraint nc2 ^ ")"
    | NC_aux (NC_and (nc1, nc2), _) ->
       "(" ^ string_of_n_constraint nc1 ^ " & " ^ string_of_n_constraint nc2 ^ ")"
    | NC_aux (NC_set (kid, ns), _) ->
       kid_name kid ^ " in {" ^ Util.string_of_list ", " Big_int.to_string ns ^ "}"
    | NC_aux (NC_true, _) -> "true"
    | NC_aux (NC_false, _) -> "false"
  in

  let string_of_uvar = function
    | U_nexp n -> string_of_nexp n
    | U_order o -> string_of_order o
    | U_effect eff -> string_of_effect eff
    | U_typ typ -> string_of_typ typ
  in

  let string_of_binding (kid, uvar) = string_of_kid kid ^ " => " ^ string_of_uvar uvar in
  Util.zencode_string (Util.string_of_list ", " string_of_binding (KBindings.bindings instantiation))

let id_of_instantiation id instantiation =
  let str = string_of_instantiation instantiation in
  prepend_id (str ^ "#") id

let rec variant_generic_typ id (Defs defs) =
  match defs with
  | DEF_type (TD_aux (TD_variant (id', _, typq, _, _), _)) :: _ when Id.compare id id' = 0 ->
     mk_typ (Typ_app (id', List.map (fun kopt -> mk_typ_arg (Typ_arg_typ (mk_typ (Typ_var (kopt_kid kopt))))) (quant_kopts typq)))
  | _ :: defs -> variant_generic_typ id (Defs defs)
  | [] -> failwith ("No variant with id " ^ string_of_id id)

(* Returns a list of all the instantiations of a function id in an
   ast. Also works with union constructors, and searches for them in
   patterns. *)
let rec instantiations_of id ast =
  let instantiations = ref [] in

  let inspect_exp = function
    | E_aux (E_app (id', _), _) as exp when Id.compare id id' = 0 ->
       let instantiation = fix_instantiation (Type_check.instantiation_of exp) in
       instantiations := instantiation :: !instantiations;
       exp
    | exp -> exp
  in

  (* We need to to check patterns in case id is a union constructor
     that is never called like a function. *)
  let inspect_pat = function
    | P_aux (P_app (id', _), annot) as pat when Id.compare id id' = 0 ->
       begin match Type_check.typ_of_annot annot with
       | Typ_aux (Typ_app (variant_id, _), _) as typ ->
          let open Type_check in
          let instantiation, _, _ = unify (fst annot) (env_of_annot annot)
                                          (variant_generic_typ variant_id ast)
                                          typ
          in
          instantiations := fix_instantiation instantiation :: !instantiations;
          pat
       | Typ_aux (Typ_id variant_id, _) -> pat
       | _ -> failwith ("Union constructor " ^ string_of_pat pat ^ " has non-union type")
       end
    | pat -> pat
  in

  let rewrite_pat = { id_pat_alg with p_aux = (fun (pat, annot) -> inspect_pat (P_aux (pat, annot))) } in
  let rewrite_exp = { id_exp_alg with pat_alg = rewrite_pat;
                                      e_aux = (fun (exp, annot) -> inspect_exp (E_aux (exp, annot))) } in
  let _ = rewrite_defs_base { rewriters_base with rewrite_exp = (fun _ -> fold_exp rewrite_exp);
                                                  rewrite_pat = (fun _ -> fold_pat rewrite_pat)} ast in

  !instantiations

let rec rewrite_polymorphic_calls id ast =
  let vs_ids = Initial_check.val_spec_ids ast in

  let rewrite_e_aux = function
    | E_aux (E_app (id', args), annot) as exp when Id.compare id id' = 0 ->
       let instantiation = fix_instantiation (Type_check.instantiation_of exp) in
       let spec_id = id_of_instantiation id instantiation in
       (* Make sure we only generate specialized calls when we've
          specialized the valspec. The valspec may not be generated if
          a polymorphic function calls another polymorphic function.
          In this case a specialization of the first may require that
          the second needs to be specialized again, but this may not
          have happened yet. *)
       if IdSet.mem spec_id vs_ids then
         E_aux (E_app (spec_id, args), annot)
       else
         exp
    | exp -> exp
  in

  let rewrite_exp = { id_exp_alg with e_aux = (fun (exp, annot) -> rewrite_e_aux (E_aux (exp, annot))) } in
  rewrite_defs_base { rewriters_base with rewrite_exp = (fun _ -> fold_exp rewrite_exp) } ast

let rec typ_frees ?exs:(exs=KidSet.empty) (Typ_aux (typ_aux, l)) =
  match typ_aux with
  | Typ_id v -> KidSet.empty
  | Typ_var kid when KidSet.mem kid exs -> KidSet.empty
  | Typ_var kid -> KidSet.singleton kid
  | Typ_tup typs -> List.fold_left KidSet.union KidSet.empty (List.map (typ_frees ~exs:exs) typs)
  | Typ_app (f, args) -> List.fold_left KidSet.union KidSet.empty (List.map (typ_arg_frees ~exs:exs) args)
  | Typ_exist (kids, nc, typ) -> typ_frees ~exs:(KidSet.of_list kids) typ
  | Typ_fn (typ1, typ2, _) -> KidSet.union (typ_frees ~exs:exs typ1) (typ_frees ~exs:exs typ2)
and typ_arg_frees ?exs:(exs=KidSet.empty) (Typ_arg_aux (typ_arg_aux, l)) =
  match typ_arg_aux with
  | Typ_arg_nexp n -> KidSet.empty
  | Typ_arg_typ typ -> typ_frees ~exs:exs typ
  | Typ_arg_order ord -> KidSet.empty

let rec typ_int_frees ?exs:(exs=KidSet.empty) (Typ_aux (typ_aux, l)) =
  match typ_aux with
  | Typ_id v -> KidSet.empty
  | Typ_var kid -> KidSet.empty
  | Typ_tup typs -> List.fold_left KidSet.union KidSet.empty (List.map (typ_int_frees ~exs:exs) typs)
  | Typ_app (f, args) -> List.fold_left KidSet.union KidSet.empty (List.map (typ_arg_int_frees ~exs:exs) args)
  | Typ_exist (kids, nc, typ) -> typ_int_frees ~exs:(KidSet.of_list kids) typ
  | Typ_fn (typ1, typ2, _) -> KidSet.union (typ_int_frees ~exs:exs typ1) (typ_int_frees ~exs:exs typ2)
and typ_arg_int_frees ?exs:(exs=KidSet.empty) (Typ_arg_aux (typ_arg_aux, l)) =
  match typ_arg_aux with
  | Typ_arg_nexp n -> KidSet.diff (tyvars_of_nexp n) exs
  | Typ_arg_typ typ -> KidSet.empty
  | Typ_arg_order ord -> KidSet.empty

let uvar_int_frees = function
  | Type_check.U_nexp n -> tyvars_of_nexp n
  | Type_check.U_typ typ -> typ_int_frees typ
  | _ -> KidSet.empty

let uvar_typ_frees = function
  | Type_check.U_typ typ -> typ_frees typ
  | _ -> KidSet.empty

let specialize_id_valspec instantiations id ast =
  match split_defs (is_valspec id) ast with
  | None -> failwith ("Valspec " ^ string_of_id id ^ " does not exist!")
  | Some (pre_ast, vs, post_ast) ->
     let typschm, externs, is_cast, annot = match vs with
       | DEF_spec (VS_aux (VS_val_spec (typschm, _, externs, is_cast), annot)) -> typschm, externs, is_cast, annot
       | _ -> assert false (* unreachable *)
     in
     let TypSchm_aux (TypSchm_ts (typq, typ), _) = typschm in

     (* Keep track of the specialized ids to avoid generating things twice. *)
     let spec_ids = ref IdSet.empty in

     let specialize_instance instantiation =
       (* Replace the polymorphic type variables in the type with their concrete instantiation. *)
       let typ = Type_check.subst_unifiers instantiation typ in

       (* Collect any new type variables introduced by the instantiation *)
       let collect_kids kidsets = KidSet.elements (List.fold_left KidSet.union KidSet.empty kidsets) in
       let typ_frees = KBindings.bindings instantiation |> List.map snd |> List.map uvar_typ_frees |> collect_kids in
       let int_frees = KBindings.bindings instantiation |> List.map snd |> List.map uvar_int_frees |> collect_kids in

       (* Remove type variables from the type quantifier. *)
       let kopts, constraints = quant_split typq in
       let kopts = List.filter (fun kopt -> not (is_typ_kopt kopt || is_order_kopt kopt)) kopts in
       let typq = mk_typquant (List.map (mk_qi_id BK_type) typ_frees
                               @ List.map (mk_qi_id BK_int) int_frees
                               @ List.map mk_qi_kopt kopts
                               @ List.map mk_qi_nc constraints) in
       let typschm = mk_typschm typq typ in

       let spec_id = id_of_instantiation id instantiation in

       if IdSet.mem spec_id !spec_ids then [] else
         begin
           spec_ids := IdSet.add spec_id !spec_ids;
           [DEF_spec (VS_aux (VS_val_spec (typschm, spec_id, externs, is_cast), annot))]
         end
     in

     let specializations = List.map specialize_instance instantiations |> List.concat in

     append_ast pre_ast (append_ast (Defs (vs :: specializations)) post_ast)

let specialize_id_fundef instantiations id ast =
  match split_defs (is_fundef id) ast with
  | None -> ast
  | Some (pre_ast, DEF_fundef fundef, post_ast) ->
     let spec_ids = ref IdSet.empty in
     let specialize_fundef instantiation =
       let spec_id = id_of_instantiation id instantiation in
       if IdSet.mem spec_id !spec_ids then [] else
         begin
           prerr_endline ("specialised fundef " ^ string_of_id id ^ " to " ^ string_of_id spec_id);
           spec_ids := IdSet.add spec_id !spec_ids;
           [DEF_fundef (rename_fundef spec_id fundef)]
         end
     in
     let fundefs = List.map specialize_fundef instantiations |> List.concat in
     append_ast pre_ast (append_ast (Defs (DEF_fundef fundef :: fundefs)) post_ast)
  | Some _ -> assert false (* unreachable *)

let specialize_id_overloads instantiations id (Defs defs) =
  let ids = IdSet.of_list (List.map (id_of_instantiation id) instantiations) in

  let rec rewrite_overloads defs =
    match defs with
    | DEF_overload (overload_id, overloads) :: defs ->
       let overloads = List.concat (List.map (fun id' -> if Id.compare id' id = 0 then IdSet.elements ids else [id']) overloads) in
       DEF_overload (overload_id, overloads) :: rewrite_overloads defs
    | def :: defs -> def :: rewrite_overloads defs
    | [] -> []
  in

  Defs (rewrite_overloads defs)

(* Once we've specialized a definition, it's original valspec should
   be unused, unless another polymorphic function called it. We
   therefore remove all unused valspecs. Remaining polymorphic
   valspecs are then re-specialized. This process is iterated until
   the whole spec is specialized. *)
let remove_unused_valspecs env ast =
  let calls = ref (IdSet.of_list [mk_id "main"; mk_id "execute"; mk_id "decode"; mk_id "initialize_registers"; mk_id "append_64"]) in
  let vs_ids = Initial_check.val_spec_ids ast in

  let inspect_exp = function
    | E_aux (E_app (call, _), _) as exp ->
       calls := IdSet.add call !calls;
       exp
    | exp -> exp
  in

  let rewrite_exp = { id_exp_alg with e_aux = (fun (exp, annot) -> inspect_exp (E_aux (exp, annot))) } in
  let _ = rewrite_defs_base { rewriters_base with rewrite_exp = (fun _ -> fold_exp rewrite_exp) } ast in

  let unused = IdSet.filter (fun vs_id -> not (IdSet.mem vs_id !calls)) vs_ids in

  let rec remove_unused (Defs defs) id =
    match defs with
    | def :: defs when is_fundef id def ->
       prerr_endline ("Removing fundef: " ^ string_of_id id);
       remove_unused (Defs defs) id
    | def :: defs when is_valspec id def ->
       prerr_endline ("Removing valspec: " ^ string_of_id id);
       remove_unused (Defs defs) id
    | DEF_overload (overload_id, overloads) :: defs ->
       begin
         match List.filter (fun id' -> Id.compare id id' <> 0) overloads with
         | [] -> remove_unused (Defs defs) id
         | overloads -> DEF_overload (overload_id, overloads) :: remove_unused (Defs defs) id
       end
    | def :: defs -> def :: remove_unused (Defs defs) id
    | [] -> []
  in

  List.fold_left (fun ast id -> Defs (remove_unused ast id)) ast (IdSet.elements unused)

let specialize_id id ast =
  prerr_endline ("specialising: " ^ string_of_id id);
  let instantiations = instantiations_of id ast in
  List.iter (fun i -> prerr_endline (string_of_instantiation i)) instantiations;

  let ast = specialize_id_valspec instantiations id ast in
  let ast = specialize_id_fundef instantiations id ast in
  specialize_id_overloads instantiations id ast

(* When we generate specialized versions of functions, we need to
   ensure that the types they are specialized to appear before the
   function definitions in the AST. Therefore we pull all the type
   definitions (and default definitions) to the start of the AST. *)
let reorder_typedefs (Defs defs) =
  let tdefs = ref [] in

  let rec filter_typedefs = function
    | (DEF_default _ | DEF_type _) as tdef :: defs ->
       tdefs := tdef :: !tdefs;
       filter_typedefs defs
    | def :: defs -> def :: filter_typedefs defs
    | [] -> []
  in

  let others = filter_typedefs defs in
  Defs (List.rev !tdefs @ others)

let specialize_ids ids ast =
  let ast = List.fold_left (fun ast id -> specialize_id id ast) ast (IdSet.elements ids) in
  let ast = reorder_typedefs ast in
  let ast, _ = Type_check.check Type_check.initial_env ast in
  let ast =
    List.fold_left (fun ast id -> rewrite_polymorphic_calls id ast) ast (IdSet.elements ids)
  in
  let ast, env = Type_check.check Type_check.initial_env ast in
  let ast = remove_unused_valspecs env ast in
  ast, env

(***** Specialising polymorphic variant types, e.g. option *****)

let rewrite_polymorphic_constructors id ast =
  let rewrite_e_aux = function
    | E_aux (E_app (id', args), annot) as exp when Id.compare id id' = 0 ->
       let instantiation = fix_instantiation (Type_check.instantiation_of exp) in
       let spec_id = id_of_instantiation id instantiation in
       E_aux (E_app (spec_id, args), annot)
    | exp -> exp
  in
  let rewrite_p_aux = function
    | P_aux (P_app (id', args), annot) as pat when Id.compare id id' = 0 ->
       begin match Type_check.typ_of_annot annot with
       | Typ_aux (Typ_app (variant_id, _), _) as typ ->
          let open Type_check in
          let instantiation, _, _ = unify (fst annot) (env_of_annot annot)
                                          (variant_generic_typ variant_id ast)
                                          (typ_of_annot annot)
          in
          (* FIXME: What if instantiation only involves U_nexps? *)
          let instantiation = fix_instantiation instantiation in
          P_aux (P_app (id_of_instantiation id' instantiation, args), annot)
       | Typ_aux (Typ_id variant_id, _) -> pat
       | _ -> failwith ("Union constructor " ^ string_of_pat pat ^ " has non-union type")
       end
    | pat -> pat
  in

  let rewrite_pat = { id_pat_alg with p_aux = (fun (pat, annot) -> rewrite_p_aux (P_aux (pat, annot))) } in
  let rewrite_exp = { id_exp_alg with pat_alg = rewrite_pat;
                                      e_aux = (fun (exp, annot) -> rewrite_e_aux (E_aux (exp, annot))) } in
  rewrite_defs_base { rewriters_base with rewrite_exp = (fun _ -> fold_exp rewrite_exp);
                                          rewrite_pat = (fun _ -> fold_pat rewrite_pat)} ast

let kinded_id_arg kind_id =
  let typ_arg arg = Typ_arg_aux (arg, Parse_ast.Unknown) in
  match kind_id with
  | KOpt_aux (KOpt_none kid, _) -> typ_arg (Typ_arg_nexp (nvar kid))
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_int, _)], _), kid), _) -> typ_arg (Typ_arg_nexp (nvar kid))
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_order, _)], _), kid), _) ->
     typ_arg (Typ_arg_order (Ord_aux (Ord_var kid, Parse_ast.Unknown)))
  | KOpt_aux (KOpt_kind (K_aux (K_kind [BK_aux (BK_type, _)], _), kid), _) ->
     typ_arg (Typ_arg_typ (mk_typ (Typ_var kid)))
  | KOpt_aux (KOpt_kind (K_aux (K_kind kinds, _), kid), l) -> assert false

let fold_union_quant quants (QI_aux (qi, l)) =
  match qi with
  | QI_id kind_id -> quants @ [kinded_id_arg kind_id]
  | _ -> quants

let specialize_variants ((Defs defs) as ast) env =
  let ctors = ref [] in

  let specialize_variant (TD_aux (tdef_aux, annot)) ast env =
    match tdef_aux with
    | TD_variant (v_id, name_scheme, typq, tus, flag) as variant ->
       let kopts = List.filter (fun kopt -> is_typ_kopt kopt || is_order_kopt kopt) (quant_kopts typq) in
       if kopts = [] then
         (* If non-polymorphic, then do nothing. *)
         TD_aux (variant, annot)
       else
         let specialize_tu (Tu_aux (Tu_ty_id (typ, id), annot)) =
           ctors := id :: !ctors;
           let is = instantiations_of id ast in
           let is = List.sort_uniq (fun i1 i2 -> String.compare (string_of_instantiation i1) (string_of_instantiation i2)) is in
           List.map (fun i ->
               let i = fix_instantiation i in
               let ret_typ = app_typ v_id (List.fold_left fold_union_quant [] (quant_items typq)) in
               let ret_typ = Type_check.subst_unifiers i ret_typ in
               Tu_aux (Tu_ty_id (Type_check.subst_unifiers i (mk_typ (Typ_fn (typ, ret_typ, no_effect))), id_of_instantiation id i), annot)) is
         in
         (*
         let kopts, constraints = quant_split typq in
         let kopts = List.filter (fun kopt -> not (is_typ_kopt kopt || is_order_kopt kopt)) kopts in
         let typq = mk_typquant (List.map mk_qi_kopt kopts @ List.map mk_qi_nc constraints) in
          *)
         TD_aux (TD_variant (v_id, name_scheme, typq, List.concat (List.map specialize_tu tus), flag), annot)
    | _ -> assert false
  in

  let rec specialize_variants' = function
    | DEF_type (TD_aux (TD_variant _, _) as tdef) :: defs ->
       DEF_type (specialize_variant tdef ast env) :: specialize_variants' defs
    | def :: defs ->
       def :: specialize_variants' defs
    | [] -> []
  in

  let ast = Defs (specialize_variants' defs) in
  let ast = List.fold_left (fun ast id -> rewrite_polymorphic_constructors id ast) ast !ctors in
  Type_check.check Type_check.initial_env ast

let rec specialize ast env =
  prerr_endline "\n==================== SPECIALISATION PASS ====================";
  let ids = polymorphic_functions (fun kopt -> is_typ_kopt kopt || is_order_kopt kopt) ast in
  if IdSet.is_empty ids then
    specialize_variants ast env
  else
    let ast, env = specialize_ids ids ast in
    specialize ast env
