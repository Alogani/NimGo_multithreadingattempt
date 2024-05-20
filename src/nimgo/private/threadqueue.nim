import std/[atomics, options]
import ./smartptrs

## Lock free (thread safe) queue implementation using linked list
## Constant complexity with minimal overhead even if push/pop are not balanced

type
    Node[T] = object
        val: T
        next: Atomic[ptr Node[T]]

    ThreadQueueObj[T] = object
        head: Atomic[ptr Node[T]]
        tail: Atomic[ptr Node[T]]

    ThreadQueue*[T] = SharedPtr[ThreadQueueObj[T]]


proc newThreadQueue*[T](): ThreadQueue[T] =
    result = newSharedPtr(ThreadQueueObj[T])
    let node = cast[ptr Node[T]](allocShared(sizeof Node[T]))
    result[].head = newAtomic(node)
    result[].tail = result[].head

proc `=destroy`*[T](q: ThreadQueueObj[T]) {.nodestroy.} =
    var q = q # Needs a var
    var currentNode = q.head.load(moRelaxed)
    while currentNode != nil:
        let nextNode = currentNode.next.load(moRelaxed)
        dealloc(currentNode)
        currentNode = nextNode

proc push*[T](q: ThreadQueue[T], val: sink T) =
    let newNode = cast[ptr Node[T]](allocShared(sizeof Node[T]))
    when T is ref:
        # Is it enough or shall it be converted to ptr ?
        Gc_ref(val)
    newNode[] = Node[T](val: val)
    let prevTail = q[].tail.exchange(newNode, moAcquireRelease)
    prevTail[].next.store(newNode, moRelease)

proc popImpl[T](q: ThreadQueue[T], isError: var bool): T =
    while true:
        var oldHead = q[].head.load(moAcquire)
        let newHead = oldHead[].next.load(moAcquire)
        if newHead == nil:
            isError = true
            return
        if q[].head.compareExchange(oldHead, newHead, moAcquireRelease):
            result = move(newHead[].val)
            when T is ref:
                Gc_unref(result)
            dealloc(oldHead)
            return

proc pop*[T](q: ThreadQueue[T]): T =
    ## Raise if empty
    var isError: bool
    result = q.popImpl(isError)
    if isError:
        raise newException(ValueError, "Trying to pop inside an empty queue")

proc popTry*[T](q: ThreadQueue[T]): Option[T] =
    var isError: bool
    let res = q.popImpl(isError)
    if isError:
        return none(T)
    else:
        return some(res)

proc empty*[T](q: ThreadQueue[T]): bool =
    ## The atomicity cannot be guaranted
    return q[].head.load(moAcquire) == q[].tail.load(moAcquire)
