# True atomic module
# Easier for conditional import in parent module like that

when true:
    # std/locks is performant both in high and low contention
    import std/locks
    export locks
else:
    type Lock* = object
        ## Do nothing, but has the same API as the lock
    
    template acquire*(lock: var Lock) =
        discard
    template release*(lock: var Lock) =
        discard

# # Data exchange
# All the data exchange between threads can be collected by the GC if not carefully handled
# The following atomic structures should be stored inside a global variable for safety
# Channels are not used to avoid deep copy (less efficient when transfering lot of data)


import std/[heapqueue, deques]

type
    AtomicQueue*[T] = object
        queue: Deque[T]
        lock: Lock

proc addLast*[T](self: var AtomicQueue[T], data: T) {.inline.} =
    self.lock.acquire()
    self.queue.addLast(data)
    self.lock.release()

proc peekFirst*[T](self: AtomicQueue[T]): lent T {.inline.} =
    self.queue.peekFirst()

proc popFirst*[T](self: var AtomicQueue[T]): T {.inline.} =
    self.lock.acquire()
    result = self.queue.popFirst()
    self.lock.release()

proc empty*[T](self: AtomicQueue[T]): bool {.inline.} =
    self.queue.len() == 0


type
    AtomicHeapQueue*[T] = object
        queue: HeapQueue[T]
        lock: Lock

proc peek*[T](self: AtomicHeapQueue[T]): lent T {.inline.} =
    self.queue[0]

proc push*[T](self: var AtomicHeapQueue[T], data: T) {.inline.} =
    self.lock.acquire()
    self.queue.push(data)
    self.lock.release()

proc pop*[T](self: var AtomicHeapQueue[T]): T {.inline.} =
    self.lock.acquire()
    result = self.queue.pop()
    self.lock.release()

proc empty*[T](self: AtomicHeapQueue[T]): bool {.inline.} =
    self.queue.len() == 0


type
    AtomicSeq*[T] = object
        stack: seq[T]
        lock: Lock

proc newAtomicSeq*[T](data: sink seq[T]): AtomicSeq[T] =
    AtomicSeq[T](stack: data)

proc add*[T](self: var AtomicSeq[T], data: sink T) {.inline.} =
    self.lock.acquire()
    self.stack.add data
    self.lock.release()

proc getMove*[T](self: var AtomicSeq[T]): seq[T] {.inline.} =
    self.lock.acquire()
    result = move(self.stack)
    self.lock.release()