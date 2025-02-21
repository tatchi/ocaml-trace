module type KEY_IMPL = sig
  type t

  exception Store of t

  val id : int
end

module Key = struct
  type 'a t = (module KEY_IMPL with type t = 'a)

  let _n = ref 0

  let create (type k) () =
    incr _n;
    let id = !_n in
    let module K = struct
      type t = k

      let id = id

      exception Store of k
    end in
    (module K : KEY_IMPL with type t = k)

  let id (type k) (module K : KEY_IMPL with type t = k) = K.id

  let equal : type a b. a t -> b t -> bool =
   fun (module K1) (module K2) -> K1.id = K2.id
end

type pair = Pair : 'a Key.t * 'a -> pair
type exn_pair = E_pair : 'a Key.t * exn -> exn_pair

let pair_of_e_pair (E_pair (k, e)) =
  let module K = (val k) in
  match e with
  | K.Store v -> Pair (k, v)
  | _ -> assert false

module M = Map.Make (struct
  type t = int

  let compare (i : int) j = Stdlib.compare i j
end)

type t = exn_pair M.t

let empty = M.empty
let mem k t = M.mem (Key.id k) t

let find_exn (type a) (k : a Key.t) t : a =
  let module K = (val k) in
  let (E_pair (_, e)) = M.find K.id t in
  match e with
  | K.Store v -> v
  | _ -> assert false

let find k t = try Some (find_exn k t) with Not_found -> None

let add_e_pair_ p t =
  let (E_pair ((module K), _)) = p in
  M.add K.id p t

let add_pair_ p t =
  let (Pair (((module K) as k), v)) = p in
  let p = E_pair (k, K.Store v) in
  M.add K.id p t

let add (type a) (k : a Key.t) v t =
  let module K = (val k) in
  add_e_pair_ (E_pair (k, K.Store v)) t

let remove (type a) (k : a Key.t) t =
  let module K = (val k) in
  M.remove K.id t

let cardinal t = M.cardinal t
let length = cardinal
let iter f t = M.iter (fun _ p -> f (pair_of_e_pair p)) t
let to_list t = M.fold (fun _ p l -> pair_of_e_pair p :: l) t []
let add_list t l = List.fold_right add_pair_ l t
let of_list l = add_list empty l
