import std/[options]
import ./[smartptrs, threadprimitives]

export options

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
    {.warning: "TODO: is this first alloc necessary ?".}
    let node = allocSharedAndSet(Node[T]())
    let atomicNode = newAtomic(node)
    return newSharedPtr(ThreadQueueObj[T](
        head: atomicNode,
        tail: atomicNode
    ))

proc `=destroy`*[T](q: ThreadQueueObj[T]) {.nodestroy.} =
    var q = q # Needs a var
    var currentNode = q.head.load(moRelaxed)
    while currentNode != nil:
        let nextNode = currentNode.next.load(moRelaxed)
        dealloc(currentNode)
        currentNode = nextNode

proc addLast*[T](q: ThreadQueue[T], val: sink T) =
    when defined(gcOrc):
        GC_runOrc()
    {.warning: "TODO: Put string inside a ref object for safety".}
    when T is ref:
        Gc_ref(val)
    when T is string: # does that do something ?
        discard
    let newNode = allocSharedAndSet(Node[T](
        val: val,
        next: newAtomic[ptr Node[T]](nil)
    ))
    newNode[] = Node[T](val: val)
    let prevTail = q[].tail.exchange(newNode, moAcquireRelease)
    prevTail[].next.store(newNode, moRelease)

proc popFirst*[T](q: ThreadQueue[T]): Option[T] =
    var oldHead = q[].head.load(moAcquire)
    let newHead = oldHead[].next.load(moAcquire)
    if newHead == nil:
        return none(T)
    if q[].head.compareExchange(oldHead, newHead, moAcquireRelease):
        result = some(move(newHead[].val))
        when T is ref:
            Gc_unref(val)
        dealloc(oldHead)
        return

proc empty*[T](q: ThreadQueue[T]): bool =
    ## The atomicity cannot be guaranted
    return q[].head.load(moAcquire) == q[].tail.load(moAcquire)
