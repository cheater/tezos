(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(*
 * Copyright (c) 2013-2015 Thomas Gazagnaire <thomas@gazagnaire.org>
 * Copyright (c) 2016 Grégoire Henry <gregoire.henry@ocamlpro.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

(* Import Ir_hum.S *)
module type Hum = sig
  include Tc.S0
  val to_hum: t -> string
  val of_hum: string -> t
end


(***** views *)

module type NODE = sig
  type t
  type node
  type contents
  module Contents: Tc.S0 with type t = contents
  module Path : sig
    (* Import Ir_S.PATH *)
    include Hum
    type step
    val empty: t
    val create: step list -> t
    val is_empty: t -> bool
    val cons: step -> t -> t
    val rcons: t -> step -> t
    val decons: t -> (step * t) option
    val rdecons: t -> (t * step) option
    val map: t -> (step -> 'a) -> 'a list
    module Step: Hum with type t = step
  end

  val empty: unit -> t
  val is_empty: t -> bool Lwt.t

  val read: t -> node option Lwt.t

  val read_contents: t -> Path.step -> contents option Lwt.t

  val with_contents: t -> Path.step -> contents option -> t option Lwt.t
  (* Return [true] iff the contents has actually changed. Used for
     invalidating the view cache if needed. *)

  val read_succ: node -> Path.step -> t option

  val with_succ: t -> Path.step -> t option -> t option Lwt.t
  (* Return [true] iff the successors has actually changes. Used for
     invalidating the view cache if needed. *)

  val steps: t -> Path.step list Lwt.t
end

module Ir_misc = struct
  module Set (K: Tc.S0) = struct

    include Set.Make(K)

    let of_list l =
      List.fold_left (fun set elt -> add elt set) empty l

    let to_list = elements

    include Tc.As_L0(struct
        type u = t
        type t = u
        module K = K
        let to_list = to_list
        let of_list = of_list
      end)
  end
  (* assume l1 and l2 are key-sorted *)
  let alist_iter2 compare_k f l1 l2 =
    let rec aux l1 l2 = match l1, l2 with
      | [], t -> List.iter (fun (key, v) -> f key (`Right v)) t
      | t, [] -> List.iter (fun (key, v) -> f key (`Left v)) t
      | (k1,v1)::t1, (k2,v2)::t2 ->
          match compare_k k1 k2 with
          | 0 ->
              f k1 (`Both (v1, v2));
              aux t1 t2
          | x -> if x < 0 then (
              f k1 (`Left v1);
              aux t1 l2
            ) else (
                f k2 (`Right v2);
                aux l1 t2
              )
    in
    aux l1 l2
  module Map_ext (M: Map.S) (K: Tc.S0 with type t = M.key) = struct

    include M

    let keys m =
      List.map fst (bindings m)

    let of_alist l =
      List.fold_left (fun map (k, v)  -> add k v map) empty l

    let to_alist = bindings

    let add_multi key data t =
      try
        let l = find key t in
        add key (data :: l) t
      with Not_found ->
        add key [data] t

    let iter2 f t1 t2 =
      alist_iter2 K.compare f (bindings t1) (bindings t2)

    module Lwt = struct
      open Lwt

      let iter2 f m1 m2 =
        let m3 = ref [] in
        iter2 (fun key data ->
            m3 := f key data :: !m3
          ) m1 m2;
        Lwt_list.iter_p
          (fun b -> b >>= fun () -> return_unit) (List.rev !m3)

      let merge f m1 m2 =
        let l3 = ref [] in
        let f key data =
          f key data >>= function
          | None   -> return_unit
          | Some v -> l3 := (key, v) :: !l3; return_unit
        in
        iter2 f m1 m2 >>= fun () ->
        let m3 = of_alist !l3 in
        return m3

    end

    include Tc.As_AL1(struct
        type 'a r = 'a t
        type 'a t = 'a r
        module K = K
        let of_alist = of_alist
        let to_alist = to_alist
      end)
  end
  module Map (S: Tc.S0) = Map_ext (Map.Make(S))(S)

end

module Make (S: Irmin.S) = struct

  module P = S.Private
  module Path = S.Key
  module PathSet = Ir_misc.Set(Path)

  module Step = Path.Step
  module StepMap = Ir_misc.Map(Path.Step)
  module StepSet = Ir_misc.Set(Path.Step)

  module Contents = struct

    type key = S.Repo.t * S.Private.Contents.key

    type contents_or_key =
      | Key of key
      | Contents of S.value
      | Both of key * S.value

    type t = contents_or_key ref
    (* Same as [Contents.t] but can either be a raw contents or a key
       that will be fetched lazily. *)

    let create c =
      ref (Contents c)

    let export c =
      match !c with
      | Both ((_, k), _)
      | Key (_, k) -> k
      | Contents _ -> Pervasives.failwith "Contents.export"

    let key db k =
      ref (Key (db, k))

    let read t =
      match !t with
      | Both (_, c)
      | Contents c -> Lwt.return (Some c)
      | Key (db, k as key) ->
        P.Contents.read (P.Repo.contents_t db) k >>= function
        | None   -> Lwt.return_none
        | Some c ->
          t := Both (key, c);
          Lwt.return (Some c)

    let equal (x:t) (y:t) =
      x == y
      ||
      match !x, !y with
      | (Key (_,x) | Both ((_,x),_)), (Key (_,y) | Both ((_,y),_)) ->
        P.Contents.Key.equal x y
      | (Contents x | Both (_, x)), (Contents y | Both (_, y)) ->
        P.Contents.Val.equal x y
      | _ -> false

  end

  module Node = struct

    type contents = S.value
    type key = S.Repo.t * P.Node.key

    type node = {
      contents: Contents.t StepMap.t;
      succ    : t StepMap.t;
      alist   : (Path.step * [`Contents of Contents.t | `Node of t ]) list Lazy.t;
    }

    and t = {
      mutable node: node option ;
      mutable key: key option ;
    }

    let rec equal (x:t) (y:t) =
      match x, y with
      | { key = Some (_,x) ; _ }, { key = Some (_,y) ; _ } ->
        P.Node.Key.equal x y
      | { node = Some x ; _ }, { node = Some y ; _ } ->
        List.length (Lazy.force x.alist) = List.length (Lazy.force y.alist)
        && List.for_all2 (fun (s1, n1) (s2, n2) ->
            Step.equal s1 s2
            && match n1, n2 with
            | `Contents n1, `Contents n2 -> Contents.equal n1 n2
            | `Node n1, `Node n2 -> equal n1 n2
            | _ -> false) (Lazy.force x.alist) (Lazy.force y.alist)
      | _ -> false

    let mk_alist contents succ =
      lazy (
        StepMap.fold
          (fun step c acc -> (step, `Contents c) :: acc)
          contents @@
        StepMap.fold
          (fun step c acc -> (step, `Node c) :: acc)
          succ
          [])
    let mk_index alist =
      List.fold_left (fun (contents, succ) (l, x) ->
          match x with
          | `Contents c -> StepMap.add l c contents, succ
          | `Node n     -> contents, StepMap.add l n succ
        ) (StepMap.empty, StepMap.empty) alist

    let create_node contents succ =
      let alist = mk_alist contents succ in
      { contents; succ; alist }

    let create contents succ =
      { key = None ; node = Some (create_node contents succ) }

    let key db k =
      { key = Some (db, k) ; node = None }

    let both db k v =
      { key = Some (db, k) ; node = Some v }

    let empty () = create StepMap.empty StepMap.empty

    let import t n =
      let alist = P.Node.Val.alist n in
      let alist = List.map (fun (l, x) ->
          match x with
          | `Contents (c, _meta) -> (l, `Contents (Contents.key t c))
          | `Node n     -> (l, `Node (key t n))
        ) alist in
      let contents, succ = mk_index alist in
      create_node contents succ

    let export n =
      match n.key with
      | Some (_, k) -> k
      | None -> Pervasives.failwith "Node.export"

    let export_node n =
      let alist = List.map (fun (l, x) ->
          match x with
          | `Contents c -> (l, `Contents (Contents.export c,
                                          P.Node.Val.Metadata.default))
          | `Node n     -> (l, `Node (export n))
        ) (Lazy.force n.alist)
      in
      P.Node.Val.create alist

    let read t =
      match t with
      | { key = None ; node = None } -> assert false
      | { node = Some n ; _ } -> Lwt.return (Some n)
      | { key = Some (db, k) ; _ } ->
        P.Node.read (P.Repo.node_t db) k >>= function
        | None   -> Lwt.return_none
        | Some n ->
          let n = import db n in
          t.node <- Some n;
          Lwt.return (Some n)

    let is_empty t =
      read t >>= function
      | None   -> Lwt.return false
      | Some n -> Lwt.return (Lazy.force n.alist = [])

    let steps t =
      read t >>= function
      | None    -> Lwt.return_nil
      | Some  n ->
        let steps = ref StepSet.empty in
        List.iter
          (fun (l, _) -> steps := StepSet.add l !steps)
          (Lazy.force n.alist);
        Lwt.return (StepSet.to_list !steps)

    let read_contents t step =
      read t >>= function
      | None   -> Lwt.return_none
      | Some t ->
        try
          StepMap.find step t.contents
          |> Contents.read
        with Not_found ->
          Lwt.return_none

    let read_succ t step =
      try Some (StepMap.find step t.succ)
      with Not_found -> None

    let with_contents t step contents =
      read t >>= function
      | None -> begin
          match contents with
          | None   -> Lwt.return_none
          | Some c ->
              let contents = StepMap.singleton step (Contents.create c) in
              Lwt.return (Some (create contents StepMap.empty))
        end
      | Some n -> begin
          match contents with
          | None ->
              if StepMap.mem step n.contents then
                let contents = StepMap.remove step n.contents in
                Lwt.return (Some (create contents n.succ))
              else
                Lwt.return_none
          | Some c ->
              try
                let previous = StepMap.find step n.contents in
                if not (Contents.equal (Contents.create c) previous) then
                  raise Not_found;
                Lwt.return_none
              with Not_found ->
                let contents =
                  StepMap.add step (Contents.create c) n.contents in
                Lwt.return (Some (create contents n.succ))
        end

    let with_succ t step succ =
      read t >>= function
      | None -> begin
          match succ with
          | None   -> Lwt.return_none
          | Some c ->
              let succ = StepMap.singleton step c in
              Lwt.return (Some (create StepMap.empty succ))
        end
      | Some n -> begin
          match succ with
          | None ->
              if StepMap.mem step n.succ then
                let succ = StepMap.remove step n.succ in
                Lwt.return (Some (create n.contents succ))
              else
                Lwt.return_none
          | Some c ->
              try
                let previous = StepMap.find step n.succ in
                if c != previous then raise Not_found;
                Lwt.return_none
              with Not_found ->
                let succ = StepMap.add step c n.succ in
                Lwt.return (Some (create n.contents succ))
        end

  end

  type key = Path.t
  type value = Node.contents

  type t = [`Empty | `Node of Node.t | `Contents of Node.contents]

  module CO = Tc.Option(P.Contents.Val)
  module PL = Tc.List(Path)

  let empty = `Empty

  let sub t path =
    let rec aux node path =
      match Path.decons path with
      | None        -> Lwt.return (Some node)
      | Some (h, p) ->
        Node.read node >>= function
        | None -> Lwt.return_none
        | Some t ->
          match Node.read_succ t h with
          | None   -> Lwt.return_none
          | Some v -> aux v p
    in
    match t with
    | `Empty      -> Lwt.return_none
    | `Node n     -> aux n path
    | `Contents _ -> Lwt.return_none

  let read_contents t path =
    match t, Path.rdecons path with
    | `Contents c, None -> Lwt.return (Some c)
    | _          , None -> Lwt.return_none
    | _          , Some (path, file) ->
      sub t path >>= function
      | None   -> Lwt.return_none
      | Some n -> Node.read_contents n file

  let read t k = read_contents t k

  let err_not_found n k =
    Printf.ksprintf
      invalid_arg "Irmin.View.%s: %s not found" n (Path.to_hum k)

  let read_exn t k =
    read t k >>= function
    | None   -> err_not_found "read" k
    | Some v -> Lwt.return v

  let mem t k =
    read t k >>= function
    | None  -> Lwt.return false
    | _     -> Lwt.return true

  let dir_mem t k =
    sub t k >>= function
    | Some _ -> Lwt.return true
    | None -> Lwt.return false

  let list_aux t path =
    sub t path >>= function
    | None   -> Lwt.return []
    | Some n ->
      Node.steps n >>= fun steps ->
      let paths =
        List.fold_left (fun set p ->
            PathSet.add (Path.rcons path p) set
          ) PathSet.empty steps
      in
      Lwt.return (PathSet.to_list paths)

  let list t path =
    list_aux t path

  let iter t fn =
    let rec aux = function
      | []       -> Lwt.return_unit
      | path::tl ->
        list t path >>= fun childs ->
        let todo = childs @ tl in
        mem t path >>= fun exists ->
        begin
          if not exists then Lwt.return_unit
          else fn path (fun () -> read_exn t path)
        end >>= fun () ->
        aux todo
    in
    list t Path.empty >>= aux

  let update_contents_aux t k v =
    match Path.rdecons k with
    | None -> begin
        match t, v with
        | `Empty, None -> Lwt.return t
        | `Contents c, Some v when P.Contents.Val.equal c v -> Lwt.return t
        | _, None -> Lwt.return `Empty
        | _, Some c -> Lwt.return (`Contents c)
      end
    | Some (path, file) ->
      let rec aux view path =
        match Path.decons path with
        | None        -> Node.with_contents view file v
        | Some (h, p) ->
          Node.read view >>= function
          | None ->
            if v = None then Lwt.return_none
            else err_not_found "update_contents" k (* XXX ?*)
          | Some n ->
            match Node.read_succ n h with
            | Some child -> begin
              aux child p >>= function
              | None -> Lwt.return_none
              | Some child -> begin
                  if v = None then
                    (* remove empty dirs *)
                    Node.is_empty child >>= function
                    | true  -> Lwt.return_none
                    | false -> Lwt.return (Some child)
                  else
                    Lwt.return (Some child)
                end >>= fun child ->
                Node.with_succ view h child
              end
            | None ->
              if v = None then
                Lwt.return_none
              else
                aux (Node.empty ()) p >>= function
                | None -> assert false
                | Some _ as child -> Node.with_succ view h child
      in
      let n = match t with `Node n -> n | _ -> Node.empty () in
      aux n path >>= function
      | None -> Lwt.return t
      | Some node ->
        Node.is_empty node >>= function
        | true  -> Lwt.return `Empty
        | false -> Lwt.return (`Node node)

  let update_contents t k v =
    update_contents_aux t k v

  let update t k v = update_contents t k (Some v)

  let remove t k = update_contents t k None

  let remove_rec t k =
    match Path.decons k with
    | None -> Lwt.return t
    | _    ->
      match t with
      | `Contents _ -> Lwt.return `Empty
      | `Empty -> Lwt.return t
      | `Node n ->
        let rec aux view path =
          match Path.decons path with
          | None       -> assert false
          | Some (h,p) ->
            if Path.is_empty p then
              Node.with_succ view h None
            else
              Node.read view >>= function
              | None   -> Lwt.return_none
              | Some n ->
                match Node.read_succ n h with
                | None       -> Lwt.return_none
                | Some child -> aux child p
        in
        aux n k >>= function
      | None -> Lwt.return t
      | Some node ->
        Node.is_empty node >>= function
        | true  -> Lwt.return `Empty
        | false -> Lwt.return (`Node node)

  type db = S.t

  let import db key =
    let repo = S.repo db in
    begin P.Node.read (P.Repo.node_t repo) key >|= function
    | None   -> `Empty
    | Some n -> `Node (Node.both repo key (Node.import repo n))
    end

  let export repo t =
    let node n = P.Node.add (P.Repo.node_t repo) (Node.export_node n) in
    let todo = Stack.create () in
    let rec add_to_todo n =
      match n with
      | { Node.key = Some _ ; _ } -> ()
      | { Node.key = None ; node = None } -> assert false
      | { Node.key = None ; node = Some x } ->
        (* 1. we push the current node job on the stack. *)
        Stack.push (fun () ->
            node x >>= fun k ->
            n.Node.key <- Some (repo, k);
            n.Node.node <- None; (* Clear cache ?? *)
            Lwt.return_unit
          ) todo;
        (* 2. we push the contents job on the stack. *)
        List.iter (fun (_, x) ->
            match x with
            | `Node _ -> ()
            | `Contents c ->
              match !c with
              | Contents.Both _
              | Contents.Key _       -> ()
              | Contents.Contents x  ->
                Stack.push (fun () ->
                    P.Contents.add (P.Repo.contents_t repo) x >>= fun k ->
                    c := Contents.Key (repo, k);
                    Lwt.return_unit
                  ) todo
          ) (Lazy.force x.Node.alist);
        (* 3. we push the children jobs on the stack. *)
        List.iter (fun (_, x) ->
            match x with
            | `Contents _ -> ()
            | `Node n ->
              Stack.push (fun () -> add_to_todo n; Lwt.return_unit) todo
          ) (Lazy.force x.Node.alist);
    in
    let rec loop () =
      let task =
        try Some (Stack.pop todo)
        with Stack.Empty -> None
      in
      match task with
      | None   -> Lwt.return_unit
      | Some t -> t () >>= loop
    in
    match t with
    | `Empty      -> Lwt.return `Empty
    | `Contents c -> Lwt.return (`Contents c)
    | `Node n ->
      add_to_todo n;
      loop () >|= fun () ->
      `Node (Node.export n)

  let of_path db path =
    P.read_node db path >>= function
    | None   -> Lwt.return `Empty
    | Some n -> import db n

  let update_path db path view =
    let repo = S.repo db in
    export repo view >>= function
    | `Empty      -> P.remove_node db path
    | `Contents c -> S.update db path c
    | `Node node  -> P.update_node db path node

end

module type S = sig
  include Irmin.RO
  val dir_mem: t -> key -> bool Lwt.t
  val update: t -> key -> value -> t Lwt.t
  val remove: t -> key -> t Lwt.t
  val list: t -> key -> key list Lwt.t
  val remove_rec: t -> key -> t Lwt.t
  val empty: t
  type db
  val of_path: db -> key -> t Lwt.t
  val update_path: db -> key -> t -> unit Lwt.t
end
