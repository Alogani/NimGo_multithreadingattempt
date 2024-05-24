import ./private/[threadprimitives, threadqueue, smartptrs]
import ./[coroutines, eventdispatcher]

type
    GoSemaphoreObj = object
        ## An implementation of a semaphore that can either suspend the coroutine or wait the thread depending on context
        ## It is thread safe but rely on coroutine's dispatcher, because coroutine cannot be resumed in another thread
        ## It uses a combination of Lock and Atomic for efficiency
        counter: Atomic[int]
        waitersQueue: ThreadQueue[tuple[coro: Coroutine, dispatcher: EvDispatcher]] # nil if thread waiting
        lock: Lock
        cond: Cond

    GoSemaphore* = SharedPtr[GoSemaphoreObj]

proc newGoSemaphore*(initialValue = 0): GoSemaphore =
    var lock = Lock()
    lock.initLock()
    var cond = Cond()
    cond.initCond()
    return newSharedPtr(GoSemaphoreObj(
        counter: newAtomic(initialValue),
        waitersQueue: newThreadQueue[tuple[coro: Coroutine, dispatcher: EvDispatcher]](),
        lock: lock,
        cond: cond,
    ))

proc wait*(self: GoSemaphore) =
    if fetchSub(self[].counter, 1) > 0:
        return
    if runningInsideDispatcher():
        let currentCoro = getCurrentCoroutine()
        self[].waitersQueue.addLast (currentCoro, getCurrentThreadDispatcher())
        suspend(currentCoro)
    else:
        self[].lock.acquire()
        self[].waitersQueue.addLast (Coroutine(), EvDispatcher())
        wait(self[].cond, self[].lock)
        self[].lock.release()

proc tryWait*(self: GoSemaphore): bool =
    ## Won't be put to sleep. return true is semaphore have been acquired, else false
    var actualCount = self[].counter.load()
    while true:
        if actualCount <= 0:
            return false
        if self[].counter.compareExchange(actualCount, actualCount - 1):
            return true

proc signal*(self: GoSemaphore) =
    if fetchAdd(self[].counter, 1) >= 0:
        return
    var currentWaiterOpt = self[].waitersQueue.popFirst()
    while currentWaiterOpt.isNone():
        currentWaiterOpt = self[].waitersQueue.popFirst()
    let currentWaiter = currentWaiterOpt.unsafeGet()
    if currentWaiter.dispatcher.isNil():
        signal(self[].cond)
    elif currentWaiter.dispatcher.runningInAnotherThread():
        currentWaiter.dispatcher.registerExternCoro currentWaiter.coro
    else:
        registerCoro currentWaiter.coro

proc signalUpTo*(self: GoSemaphore, count = 0) =
    while self[].counter.load() < count:
        self.signal()