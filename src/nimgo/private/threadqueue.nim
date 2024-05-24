import std/[options]
import ./[smartptrs, threadprimitives]

export options

## Lock free (thread safe) queue implementation using linked list
## Constant complexity with minimal overhead even if push/pop are not balanced

type
    GcRefContainer[T] = ref object
        val: T

    Node[T] = object
        when T is seq or T is string:
            # Simplest and safest
            val: GcRefContainer[T]
            next: Atomic[ptr Node[T]]
        else:
            val: T
            next: Atomic[ptr Node[T]]

    ThreadQueueObj[T] = object
        head: Atomic[ptr Node[T]]
        tail: Atomic[ptr Node[T]]

    ThreadQueue*[T] = SharedPtr[ThreadQueueObj[T]]

proc newThreadQueue*[T](): ThreadQueue[T] =
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
        when T is ref or T is string or T is seq:
            # when T is string or T is seq, we dealloc GcRefContainer[T]
            if currentNode[].val != nil:
                dealloc(cast[pointer](currentNode[].val))
        dealloc(currentNode)
        currentNode = nextNode

proc addLast*[T](q: ThreadQueue[T], val: sink T) =
    #when defined(gcOrc):
    #    GC_runOrc()
    when T is ref:
        Gc_ref(val)
    when T is string or T is seq:
        let val = GcRefContainer[T](val: val)
        Gc_ref(val)
    let newNode = allocSharedAndSet(Node[T](
        val: val,
        next: newAtomic[ptr Node[T]](nil)
    ))
    let prevTail = q[].tail.exchange(newNode)
    prevTail[].next.store(newNode)

proc popFirst*[T](q: ThreadQueue[T]): Option[T] =
    var oldHead = q[].head.load(moAcquire)
    let newHead = oldHead[].next.load(moAcquire)
    if newHead == nil:
        return none(T)
    if q[].head.compareExchange(oldHead, newHead):
        when T is string or T is seq:
            var val = newHead[].val.val
            Gc_unref(newHead[].val)
        else:
            var val = newHead[].val
            when T is ref:
                Gc_unref(val)
        result = some(move(val))
        
        dealloc(oldHead)
        return

proc empty*[T](q: ThreadQueue[T]): bool =
    ## The atomicity cannot be guaranted
    return q[].head.load(moAcquire) == q[].tail.load(moAcquire)