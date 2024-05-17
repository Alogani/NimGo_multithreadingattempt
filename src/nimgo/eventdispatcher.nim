import ./coroutines {.all.}
import std/[os, selectors, nativesockets]
import std/[sets, heapqueue, times, monotimes]

#[
    Event loop implementation close to how the nodejs/libuv one's works (for more details: https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick).
    With the main difference of resuming coroutines instead of running callbacks (I'll use "worker" term to design the code answering an event)
    As so, it shares the main advantages and drawbacks. Mainly :
        - If multiple workers listen to the same event, they will be both runned, even if the event is consumed (could result in a blocking operation)
        - Worker execution pauses the event loop, and will delay the execution of the event loop, and by extension other workers
          This could have a negative impact on the overall performance and responsivness
    But here are principal differences with the nodejs implementation:
        - The poll phase will not wait indefinitly for I/O events if no timers are registers (unless NimGoNoThread is set)
          It will instead wait for a maximum of time defined by `EvDispatcherTimeOut` constant (can be tweaked with `-d:EvDispatcherTimeOut:Number`)
          This will allow the loop to be rerun to take into account workers and new events.
        - If the event loop and poll queue is empty, runOnce will immediatly return
    If you notice other differences with libuv, please let me now (I will either document it or implement it)
]#

## Following to resolve:
## - having multiple possible coro listening to same fd can lead to data race
## - suspendUntilTime not finished implemented


#[ *** Timeout utility *** ]#

type
    TimeOutWatcher* = object
        beginTime: Time
        timeoutMs: int

proc init*(T: type TimeOutWatcher, timeoutMs: int): T =
    TimeOutWatcher(
        beginTime: if timeoutMs != -1: getTime() else: Time(),
        timeoutMs: timeoutMs
    )

proc hasNoDeadline*(self: TimeOutWatcher): bool =
    return self.timeoutMs == -1

proc expired*(self: TimeOutWatcher): bool =
    if self.timeoutMs == -1:
        return false
    if self.timeoutMs < (getTime() - self.beginTime).inMilliseconds():
        return true
    return false

proc getRemainingMs*(self: TimeOutWatcher): int =
    if self.timeoutMs == -1:
        return -1
    let remaining = self.timeoutMs - (getTime() - self.beginTime).inMilliseconds()
    if remaining < 0:
        return 0
    else:
        return remaining

proc clampTimeout(x, b: int): int =
    ## if b == -1, consider it infinity
    ## Minimum timeout is always 0
    if x < 0: return 0
    if b != -1 and x > b: return b
    return x

#[ *** Thread safe API *** ]#
const NimGoNoThread {.booldefine.} = true

when NimGoNoThread:
    import deques

    type Queue[T] = distinct Deque[T]
    template push[T](q: Queue[T], data: T) = Deque[T](q).pushLast(data)
    template pop[T](q: Queue[T]): T = Deque[T](q).popFirst()
    template isEmpty[T](q: Queue[T]): bool = Deque[T](q).len() == 0

    type Lock = object ## Do nothing, but has the same API as the lock
    template acquire(lock: var Lock) = discard
    template release(lock: var Lock) = discard
else:
    import std/[locks, channels]

    type Queue[T] = distinct Channel[T]
    template push[T](q: Queue[T], data: T) = discard Channel[T](q).trySend(data)
    template pop[T](q: Queue[T]): T = Channel[T](q).recv()
    template isEmpty[T](q: Queue[T]): bool = not Channel[T](q).ready()

type Atomic[T] = object
    lock: Lock
    data: T
proc initAtomic[T](data: T): Atomic[T] =
    Atomic[T](data: data)
template getNoLock[T](self: Atomic[T]): T = self.data
template withLock[T](self: Atomic[T], body: untyped) =
    self.lock.acquire()
    body
    self.lock.release()
template set[T](self: Atomic[T], data: T) =
    self.lock.acquire()
    self.data = data
    self.lock.release()
template getAndClear[T](self: Atomic[T]): T =
    self.lock.acquire()
    var data = move(self.data)
    self.lock.release()
    data
template atomicInc[T: SomeInteger](self: Atomic[T], val: T = 1) =
    self.lock.acquire()
    self.data += val
    self.lock.release()
template atomicDec[T: SomeInteger](self: Atomic[T], val: T = 1) =
    self.lock.acquire()
    self.data -= val
    self.lock.release()


#[ *** Event dispatcher/loop *** ]#

type
    AsyncData = object
        readList: Atomic[seq[CoroutineBase]] # Also stores all other event kind
        writeList: Atomic[seq[CoroutineBase]]
        unregisterWhenTriggered: bool

    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.

    EvDispatcher* = object
        handles: Atomic[HashSet[PollFd]]
        numOfCorosRegistered: Atomic[int] # Inside the selector only
        onNextTickCoros: Queue[CoroutineBase]
        # In the same order as the runOnce execution:
        timers: Atomic[HeapQueue[tuple[finishAt: MonoTime, coro: CoroutineBase]]] # Thresold and not exact time
        pendingCoros: Queue[CoroutineBase]
        selector: Atomic[Selector[AsyncData]]
        checkCoros: Queue[CoroutineBase] # Executed after the poll phase
        closeCoros: Queue[CoroutineBase]
        
const EvDispatcherTimeoutMs {.intdefine.} = 100
const SleepMsIfInactive = 30 # to avoid busy waiting. When selector is not empty, but events triggered with no associated coroutines
const SleepMsIfEmpty = 50 # to avoid busy waiting. When the event loop is empty
const CoroLimitByPhase = 30 # To avoid starving the coros inside the poll
when NimGoNoThread:
    var MainEvDispatcher {.threadvar.}: EvDispatcher # Automatically set on import
else:
    var MainEvDispatcher: EvDispatcher # Automatically set on import

proc getGlobalDispatcher*(): EvDispatcher =
    return MainEvDispatcher

proc setGlobalDispatcher*(dispatcher: EvDispatcher) =
    ## A default globbal dispatcher is already set
    MainEvDispatcher = dispatcher

proc newDispatcher*(): EvDispatcher =
    EvDispatcher(
        selector: initAtomic(newSelector[AsyncData]())
    )

proc hasImmediatePendingCoros(dispatcher: EvDispatcher): bool =
    not(dispatcher.onNextTickCoros.isEmpty() and
        dispatcher.timers.getNoLock().len() == 0 and
        dispatcher.pendingCoros.isEmpty() and
        dispatcher.checkCoros.isEmpty() and
        dispatcher.closeCoros.isEmpty())

proc isEmpty*(dispatcher: EvDispatcher = MainEvDispatcher): bool =
    dispatcher.numOfCorosRegistered.getNoLock() == 0 and
        dispatcher.onNextTickCoros.isEmpty() and
        dispatcher.timers.getNoLock().len() == 0 and
        dispatcher.pendingCoros.isEmpty() and
        dispatcher.checkCoros.isEmpty() and
        dispatcher.closeCoros.isEmpty()

proc processNextTickCoros(dispatcher: var EvDispatcher, timeout: TimeOutWatcher) {.inline.} =
    while not (dispatcher.onNextTickCoros.isEmpty or timeout.expired):
        dispatcher.onNextTickCoros.pop().resume()

proc processTimers(dispatcher: var EvDispatcher, coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or dispatcher.numOfCorosRegistered.getNoLock() == 0:
        if timeout.expired():
            break
        if dispatcher.timers.getNoLock().len() == 0:
            break
        if getMonotime() < dispatcher.timers.getNoLock()[0].finishAt:
            break
        withLock(dispatcher.timers):
            dispatcher.timers.data.pop().coro.resume()
        processNextTickCoros(dispatcher, timeout)
        coroLimitForTimer += 1

proc runOnce(dispatcher: var EvDispatcher, timeoutMs: int) =
    ## Run the event loop. The poll phase is done only once
    ## Timeout is a thresold and be taken in account lately
    let timeout = TimeOutWatcher.init(timeoutMs)
    processNextTickCoros(dispatcher, timeout)
    # Phase 1: process timers
    var coroLimitForTimer = 0
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # Phase 2: process pending
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.pendingCoros.isEmpty() or timeout.expired:
            break
        dispatcher.pendingCoros.pop().resume()
        processNextTickCoros(dispatcher, timeout)
    # Phase 1 again
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if dispatcher.timers.getNoLock().len() > 0:
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(dispatcher.timers.getNoLock()[0].finishAt - getMonoTime()),
                EvDispatcherTimeoutMs)        
        else:

            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(dispatcher.timers.getNoLock()[0].finishAt - getMonoTime()),
                timeout.getRemainingMs()
            ), EvDispatcherTimeoutMs)
    elif timeout.hasNoDeadline():
        pollTimeoutMs = clampTimeout(timeout.getRemainingMs(), EvDispatcherTimeoutMs)
    else:
        pollTimeoutMs = EvDispatcherTimeoutMs
    # Phase 3: poll for I/O
    while dispatcher.numOfCorosRegistered.getNoLock() != 0:
        # The event loop could return with no work if an event is triggered with no coroutine
        # If so, we will sleep and loop again
        var readyKeyList = dispatcher.selector.getNoLock().select(pollTimeoutMs)
        var hasResumedCoro: bool
        if readyKeyList.len() == 0:
            break # timeout expired
        for readyKey in readyKeyList:
            var asyncData = getData(dispatcher.selector.getNoLock(), readyKey.fd)
            if Event.Write in readyKey.events:
                let writeList = asyncData.writeList.getAndClear()
                dispatcher.numOfCorosRegistered.atomicDec(writeList.len)
                if writeList.len > 0: hasResumedCoro = true
                for coro in writeList: # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros(dispatcher, timeout)
            if {Event.Write} != readyKey.events:
                let readList = asyncData.readList.getAndClear()
                dispatcher.numOfCorosRegistered.atomicDec(readList.len)
                if readList.len > 0: hasResumedCoro = true
                for coro in readList: # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros(dispatcher, timeout)
            if asyncData.unregisterWhenTriggered:
                withLock(dispatcher.selector):
                    dispatcher.selector.data.unregister(readyKey.fd)
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.checkCoros.isEmpty() or timeout.expired:
            break
        dispatcher.checkCoros.pop().resume()
        processNextTickCoros(dispatcher, timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.closeCoros.isEmpty():
            break
        dispatcher.closeCoros.pop().resume()
        processNextTickCoros(dispatcher, timeout)

proc runEventLoop*(dispatcher: var EvDispatcher, timeoutMs = -1) =
    ## Run the event loop until it is empty
    ## Only two kinds of deadlocks can happen:
    ## - if at least one coroutine waits for an event that never happens
    ## - if a coroutine never stops, or recursivly add coroutines
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not dispatcher.isEmpty() and not timeout.expired:
        runOnce(dispatcher, timeout.getRemainingMs())

proc runEventLoop*(timeoutMs = -1) =
    runEventLoop(MainEvDispatcher, timeoutMs)

proc runEventLoopForever*(dispatcher: var EvDispatcher, timeoutMs = -1, stopFlag: var bool = false) =
    ## Run the event loop even if empty (causing a deadlock on main thread)
    ## To use inside a dedicated thread or with a timeout
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not (stopFlag or timeout.expired):
        while dispatcher.isEmpty() and not timeout.expired:
            sleep(SleepMsIfEmpty)
        runOnce(dispatcher, timeout.getRemainingMs())

proc runEventLoopForever*(timeoutMs = -1, stopFlag: var bool = false) =
    runEventLoopForever(MainEvDispatcher, timeoutMs, stopFlag)

#[ *** Poll fd API *** ]#

proc registerEvent*(
    ev: SelectEvent,
    coros: seq[CoroutineBase] = @[],
    dispatcher: var EvDispatcher = MainEvDispatcher
) =
    if coros.len() > 0: dispatcher.numOfCorosRegistered.atomicInc(coros.len())
    withLock(dispatcher.selector):
        dispatcher.selector.data.registerEvent(ev, AsyncData(readList: initAtomic(coros)))

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
    dispatcher: var EvDispatcher = MainEvDispatcher,
): PollFd =
    withLock(dispatcher.selector):
        dispatcher.selector.data.registerHandle(fd, events, AsyncData())
    return PollFd(fd)

proc registerProcess*(
    pid: int,
    coros: seq[CoroutineBase] = @[],
    unregisterWhenTriggered = true,
    dispatcher: var EvDispatcher = MainEvDispatcher
): PollFd =
    if coros.len() > 0: dispatcher.numOfCorosRegistered.atomicInc(coros.len())
    withLock(dispatcher.selector):
        result = PollFd(dispatcher.selector.data.registerProcess(pid, AsyncData(
            readList: initAtomic(coros),
            unregisterWhenTriggered: unregisterWhenTriggered
        )))

proc registerSignal*(
    signal: int,
    coros: seq[CoroutineBase] = @[],
    unregisterWhenTriggered = true,
    dispatcher: var EvDispatcher = MainEvDispatcher
): PollFd =
    if coros.len() > 0: dispatcher.numOfCorosRegistered.atomicInc(coros.len())
    withLock(dispatcher.selector):
        result = PollFd(dispatcher.selector.data.registerSignal(signal, AsyncData(
            readList: initAtomic(coros),
            unregisterWhenTriggered: unregisterWhenTriggered
        )))

proc registerTimer*(
    timeout: int,
    oneshot: bool = true,
    coros: seq[CoroutineBase] = @[],
    dispatcher: var EvDispatcher = MainEvDispatcher,
): PollFd =
    ## Timer is registered inside the poll, not inside the event loop
    ## Use another function to sleep inside the event loop (more reactive, less overhead)
    if coros.len() > 0: dispatcher.numOfCorosRegistered.atomicInc(coros.len())
    withLock(dispatcher.selector):
        result = PollFd(dispatcher.selector.data.registerTimer(timeout, oneshot, AsyncData(
            readList: initAtomic(coros),
            unregisterWhenTriggered: oneshot
        )))

proc unregister*(fd: PollFd, dispatcher: var EvDispatcher = MainEvDispatcher) =
    withLock(dispatcher.selector):
        var asyncData = dispatcher.selector.data.getData(fd.int)
        let readList = asyncData.readList.getAndClear()
        dispatcher.numOfCorosRegistered.atomicDec(readList.len())
        for coro in readList:
            coro.destroy()
        let writeList = asyncData.writeList.getAndClear()
        dispatcher.numOfCorosRegistered.atomicDec(writeList.len())
        for coro in writeList:
            coro.destroy()
        dispatcher.selector.data.unregister(fd.int)

proc suspendUntilRead*(fd: PollFd) =
    ## Will not update kind of events listening, this should be given/updated at registration
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    withLock MainEvDispatcher.selector.getNoLock().getData(fd.int).readList:
        MainEvDispatcher.selector.getNoLock().getData(fd.int).readList.data.add(coro)
    MainEvDispatcher.numOfCorosRegistered.atomicInc()
    suspend()


MainEvDispatcher = newDispatcher()