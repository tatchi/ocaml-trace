type 'a t = {
  mutex: Mutex.t;
  cond: Condition.t;
  q: 'a Queue.t;
  mutable closed: bool;
}

exception Closed

let create () : _ t =
  {
    mutex = Mutex.create ();
    cond = Condition.create ();
    q = Queue.create ();
    closed = false;
  }

let close (self : _ t) =
  Mutex.lock self.mutex;
  if not self.closed then (
    self.closed <- true;
    Condition.broadcast self.cond (* awake waiters so they fail  *)
  );
  Mutex.unlock self.mutex

let push (self : _ t) x : unit =
  Mutex.lock self.mutex;
  if self.closed then (
    Mutex.unlock self.mutex;
    raise Closed
  ) else (
    let was_empty = Queue.is_empty self.q in
    Queue.push x self.q;
    if was_empty then Condition.signal self.cond;
    Mutex.unlock self.mutex
  )

let pop (self : 'a t) : 'a =
  Mutex.lock self.mutex;
  let rec loop () =
    if Queue.is_empty self.q then (
      if self.closed then (
        Mutex.unlock self.mutex;
        raise Closed
      );
      Condition.wait self.cond self.mutex;
      (loop [@tailcall]) ()
    ) else (
      let x = Queue.pop self.q in
      Mutex.unlock self.mutex;
      x
    )
  in
  loop ()

let transfer (self : 'a t) q2 : unit =
  Mutex.lock self.mutex;
  while
    if Queue.is_empty self.q then (
      if self.closed then (
        Mutex.unlock self.mutex;
        raise Closed
      );
      Condition.wait self.cond self.mutex;
      true
    ) else (
      Queue.transfer self.q q2;
      Mutex.unlock self.mutex;
      false
    )
  do
    ()
  done
