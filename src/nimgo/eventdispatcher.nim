import ./coroutines {.all.}
import std/[os, selectors, nativesockets]
import std/[times, monotimes]
import sets

const NimGoNoThread {.booldefine.} = true
when NimGoNoThread:
    import ./private/fakeatomics
else:
    import ./private/atomics

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

#[ *** Event dispatcher/loop *** ]#

type
    AsyncData = object
        readList: AtomicSeq[CoroutineBase] # Also stores all other event kind
        writeList: AtomicSeq[CoroutineBase]
        unregisterWhenTriggered: bool

    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.

    EvDispatcher* = ref object
        # Following need the lock.
        # Atomic not used for simpler code on avoiding object copy (elements changed at same time)
        lock: Lock
        numOfCorosRegistered: int
        selector: Selector[AsyncData]
        # For the order of execution, see preamble
        onNextTickCoros: AtomicQueue[CoroutineBase]
        timers: AtomicHeapQueue[tuple[finishAt: MonoTime, coro: CoroutineBase]] # Thresold and not exact time
        pendingCoros: AtomicQueue[CoroutineBase]
        checkCoros: AtomicQueue[CoroutineBase]
        closeCoros: AtomicQueue[CoroutineBase]
        
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
        selector: newSelector[AsyncData]()
    )

proc hasImmediatePendingCoros(dispatcher: EvDispatcher): bool =
    not(dispatcher.onNextTickCoros.empty() and
        dispatcher.timers.empty() and
        dispatcher.pendingCoros.empty() and
        dispatcher.checkCoros.empty() and
        dispatcher.closeCoros.empty())

proc isEmpty*(dispatcher: EvDispatcher = MainEvDispatcher): bool =
    dispatcher.numOfCorosRegistered == 0 and
        dispatcher.onNextTickCoros.empty() and
        dispatcher.timers.empty() and
        dispatcher.pendingCoros.empty() and
        dispatcher.checkCoros.empty() and
        dispatcher.closeCoros.empty()

proc processNextTickCoros(dispatcher: var EvDispatcher, timeout: TimeOutWatcher) {.inline.} =
    while not (dispatcher.onNextTickCoros.empty() or timeout.expired):
        dispatcher.onNextTickCoros.popFirst().resume()

proc processTimers(dispatcher: var EvDispatcher, coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or dispatcher.numOfCorosRegistered == 0:
        if timeout.expired():
            break
        if dispatcher.timers.empty():
            break
        if getMonotime() < dispatcher.timers.peek().finishAt:
            break
        dispatcher.timers.pop().coro.resume()
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
        if dispatcher.pendingCoros.empty() or timeout.expired:
            break
        dispatcher.pendingCoros.popFirst().resume()
        processNextTickCoros(dispatcher, timeout)
    # Phase 1 again
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if not dispatcher.timers.empty():
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(dispatcher.timers.peek().finishAt - getMonoTime()),
                EvDispatcherTimeoutMs)        
        else:

            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(dispatcher.timers.peek().finishAt - getMonoTime()),
                timeout.getRemainingMs()
            ), EvDispatcherTimeoutMs)
    elif timeout.hasNoDeadline():
        pollTimeoutMs = clampTimeout(timeout.getRemainingMs(), EvDispatcherTimeoutMs)
    else:
        pollTimeoutMs = EvDispatcherTimeoutMs
    # Phase 3: poll for I/O
    while dispatcher.numOfCorosRegistered != 0:
        # The event loop could return with no work if an event is triggered with no coroutine
        # If so, we will sleep and loop again
        var readyKeyList = dispatcher.selector.select(pollTimeoutMs)
        var hasResumedCoro: bool
        if readyKeyList.len() == 0:
            break # timeout expired
        for readyKey in readyKeyList:
            dispatcher.lock.acquire()
            var asyncData = getData(dispatcher.selector, readyKey.fd)
            var writeList: seq[CoroutineBase]
            var readList: seq[CoroutineBase]
            if Event.Write in readyKey.events:
                writeList = asyncData.writeList.getMove()
            if readyKey.events.card() > 0 and {Event.Write} != readyKey.events:
                readList = asyncData.readList.getMove()
            dispatcher.numOfCorosRegistered -= writeList.len() + readList.len()
            dispatcher.lock.release()
            if writeList.len() > 0 or readList.len() > 0:
                hasResumedCoro = true
            for coro in writeList:
                coro.resume()
                processNextTickCoros(dispatcher, timeout)
            for coro in readList:
                coro.resume()
                processNextTickCoros(dispatcher, timeout)
            if asyncData.unregisterWhenTriggered:
                dispatcher.lock.acquire()
                dispatcher.selector.unregister(readyKey.fd)
                dispatcher.lock.release()
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.checkCoros.empty() or timeout.expired:
            break
        dispatcher.checkCoros.popFirst().resume()
        processNextTickCoros(dispatcher, timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.closeCoros.empty():
            break
        dispatcher.closeCoros.popFirst().resume()
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
    dispatcher = MainEvDispatcher
) =
    dispatcher.lock.acquire()
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    dispatcher.selector.registerEvent(ev, AsyncData(readList: newAtomicSeq(coros)))
    dispatcher.lock.release()

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
    dispatcher = MainEvDispatcher,
): PollFd =
    result = PollFd(fd)
    dispatcher.lock.acquire()
    dispatcher.selector.registerHandle(fd, events, AsyncData())
    dispatcher.lock.release()

proc registerProcess*(
    pid: int,
    coros: seq[CoroutineBase] = @[],
    unregisterWhenTriggered = true,
    dispatcher = MainEvDispatcher
): PollFd =
    dispatcher.lock.acquire()
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    result = PollFd(dispatcher.selector.registerProcess(pid, AsyncData(
            readList: newAtomicSeq(coros),
            unregisterWhenTriggered: unregisterWhenTriggered
        )))
    dispatcher.lock.release()

proc registerSignal*(
    signal: int,
    coros: seq[CoroutineBase] = @[],
    unregisterWhenTriggered = true,
    dispatcher = MainEvDispatcher
): PollFd =
    dispatcher.lock.acquire()
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    result = PollFd(dispatcher.selector.registerSignal(signal, AsyncData(
        readList: newAtomicSeq(coros),
        unregisterWhenTriggered: unregisterWhenTriggered
    )))
    dispatcher.lock.release()

proc registerTimer*(
    timeout: int,
    oneshot: bool = true,
    coros: seq[CoroutineBase] = @[],
    dispatcher = MainEvDispatcher,
): PollFd =
    ## Timer is registered inside the poll, not inside the event loop
    ## Use another function to sleep inside the event loop (more reactive, less overhead)
    dispatcher.lock.acquire()
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    result = PollFd(dispatcher.selector.registerTimer(timeout, oneshot, AsyncData(
        readList: newAtomicSeq(coros),
        unregisterWhenTriggered: oneshot
    )))
    dispatcher.lock.release()

proc unregister*(fd: PollFd, dispatcher = MainEvDispatcher) =
    var asyncData = dispatcher.selector.getData(fd.int)
    let readList = asyncData.readList.getMove()
    let writeList = asyncData.writeList.getMove()
    dispatcher.lock.acquire()
    dispatcher.numOfCorosRegistered -= readList.len() + writeList.len()
    dispatcher.selector.unregister(fd.int)
    dispatcher.lock.release()
    for coro in readList:
        coro.destroy()
    for coro in writeList:
        coro.destroy()

proc addToPoll*(coro: CoroutineBase, fd: PollFd, event: Event, dispatcher = MainEvDispatcher) =
    ## Will not update the type event listening
    dispatcher.lock.acquire()
    dispatcher.numOfCorosRegistered += 1
    dispatcher.lock.release()
    if event == Event.Write:
        dispatcher.selector.getData(fd.int).writeList.add(coro)
    else:
        dispatcher.selector.getData(fd.int).readList.add(coro)

proc updateEvents*(fd: PollFd, events: set[Event], dispatcher = MainEvDispatcher) =
    dispatcher.selector.updateHandle(fd.int, events)

proc suspendUntilRead*(fd: PollFd, dispatcher = MainEvDispatcher) =
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    addToPoll(coro, fd, Event.Read, dispatcher)
    suspend()

proc suspendUntilWrite*(fd: PollFd, dispatcher = MainEvDispatcher) =
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    addToPoll(coro, fd, Event.Write, dispatcher)
    suspend()

MainEvDispatcher = newDispatcher()