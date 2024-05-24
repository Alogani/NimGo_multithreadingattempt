import ./private/threadprimitives


type
    BinaryGoSemaphore* = object
        ## An implementation of a semaphore that can either suspend the coroutine or wait the thread depending on context
        ## It uses a combination of Lock and Atomic for efficiency
        available: Atomic[bool]
        lock: Lock
        cond: Cond

proc wait*(s: var BinaryGoSemaphore) =
    discard

proc signal*(s: var BinaryGoSemaphore) =
    discard






#[
    Cases:
    waiter is a coro with no dispatcher: signal
    waiter is a thread: signal
    waiter is a coro with a dispatcher:
        - suspend 
        for sender:
            if signal has same dispatcher:
                - resume directly
            else:
                - add it inside the dispatcher (but should not be waken too early!!!)

]#