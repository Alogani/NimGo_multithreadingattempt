import ../private/[timeoutwatcher, threadprimitives, threadqueue, smartptrs]
import ../[coroutines, eventdispatcher]
import std/os

type
    GoSemaphoreObj = object
        ## An implementation of a semaphore that can either suspend the coroutine or wait the thread depending on context
        ## It is thread safe but rely on coroutine's dispatcher, because coroutine cannot be resumed in another thread
        ## It uses a combination of Lock and Atomic for efficiency
        counter: Atomic[int]
        waitersQueue: ThreadQueue[tuple[coroShared: SharedResource[Coroutine], dispatcher: EvDispatcher]] # nil if thread waiting
        lock: Lock
        cond: Cond

    GoSemaphore* = SharedPtr[GoSemaphoreObj]

const BusyWaitSleepMs* = 10

proc `=destroy`*(sem: GoSemaphoreObj) =
    let semAddr = addr(sem)
    deinitLock(semAddr[].lock)
    deinitCond(semAddr[].cond)

proc newGoSemaphore*(initialValue = 0): GoSemaphore =
    var lock = Lock()
    lock.initLock()
    var cond = Cond()
    cond.initCond()
    return newSharedPtr(GoSemaphoreObj(
        counter: newAtomic(initialValue),
        waitersQueue: newThreadQueue[tuple[coroShared: SharedCoroutine, dispatcher: EvDispatcher]](),
        lock: lock,
        cond: cond,
    ))

proc signal*(self: GoSemaphore) =
    if fetchAdd(self[].counter, 1) >= 0:
        return
    var currentWaiterOpt = self[].waitersQueue.popFirst()
    while currentWaiterOpt.isNone():
        currentWaiterOpt = self[].waitersQueue.popFirst()
    let currentWaiter = currentWaiterOpt.unsafeGet()
    if currentWaiter.dispatcher.isNil():
        signal(self[].cond)
        return
    let coroOpt = currentWaiter.coroShared.use()
    if coroOpt.isNone():
        return # Doesn't need fetchAdd, because wait will call signal if timeout.expired()
    let coro = coroOpt.unsafeGet()
    if currentWaiter.dispatcher.runningInAnotherThread():
        currentWaiter.dispatcher.registerExternCoro coro
    else:
        registerCoro coro

proc signalUpTo*(self: GoSemaphore, count = 0) =
    while self[].counter.load() < count:
        self.signal()

proc wait*(self: GoSemaphore) =
    if fetchSub(self[].counter, 1) > 0:
        return
    if runningInsideDispatcher():
        let currentCoro = getCurrentCoroutine()
        self[].waitersQueue.addLast (newSharedResource(currentCoro), getCurrentThreadDispatcher())
        suspend(currentCoro)
    else:
        self[].lock.acquire()
        self[].waitersQueue.addLast (SharedCoroutine(), EvDispatcher())
        wait(self[].cond, self[].lock)
        self[].lock.release()

proc tryAcquire*(self: GoSemaphore): bool =
    ## Won't be put to sleep. return true is semaphore have been acquired, else false
    var actualCount = self[].counter.load()
    while true:
        if actualCount < 0:
            return false
        if self[].counter.compareExchange(actualCount, actualCount - 1):
            return true

proc waitWithTimeout*(self: GoSemaphore, timeoutMs: int): bool =
    ## Return true if semaphore has been acquired else false
    ## If waiter is a thread, we have no choice than to busywait
    let timeout = TimeOutWatcher.init(timeoutMs)
    if runningInsideDispatcher():
        if fetchSub(self[].counter, 1) > 0:
            return true
        let currentCoro = getCurrentCoroutine()
        let currentSharedCoro = newSharedResource(currentCoro)
        self[].waitersQueue.addLast (currentSharedCoro, getCurrentThreadDispatcher())
        registerOnSchedule(currentSharedCoro, timeoutMs)
        suspend(currentCoro)
        if timeout.expired():
            self.signal()
            return false
        else:
            return true
    else:
        if fetchSub(self[].counter, 1) > 0:
            return
        self[].waitersQueue.addLast (SharedCoroutine(), EvDispatcher())
        while not timeout.expired:
            if self.tryAcquire():
                return true
            sleep(clampTimeout(timeout.getRemainingMs(), BusyWaitSleepMs))
        return false
    