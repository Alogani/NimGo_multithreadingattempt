import ./coroutines {.all.}
import std/[os, selectors, nativesockets]
import std/[deques, sets, heapqueue, times, monotimes]

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

const NimGoNoThread {.booldefine.} = true

type
    AsyncData = object
        readList: seq[CoroutineBase] # Also stores all other event kind
        writeList: seq[CoroutineBase]
        unregisterWhenTriggered: bool

    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.

    EvDispatcher* = object
        handles: HashSet[PollFd]
        numOfCorosRegistered: int # Inside the selector only
        onNextTickCoros: Deque[CoroutineBase]
        # In the same order as the runOnce execution:
        timers: HeapQueue[tuple[finishAt: MonoTime, coro: CoroutineBase]] # Thresold and not exact time
        pendingCoros: Deque[CoroutineBase]
        selector: Selector[AsyncData]
        checkCoros: Deque[CoroutineBase] # Executed after the poll phase
        closeCoros: Deque[CoroutineBase]
        
const EvDispatcherTimeoutMs {.intdefine.} = 100
const SleepMsIfInactive = 30 # to avoid busy waiting. When selector is not empty, but events triggered with no associated coroutines
const SleepMsIfEmpty = 50 # to avoid busy waiting. When the event loop is empty
const CoroLimitByPhase = 30 # To avoid starving the coros inside the poll
when NimGoNoThread:
    var MainEvDispatcher {.threadvar.}: EvDispatcher # Automatically set on import
else:
    var MainEvDispatcher: EvDispatcher # Automatically set on import

proc getGlobalDispatcher*(): var EvDispatcher =
    return MainEvDispatcher

proc setGlobalDispatcher*(dispatcher: EvDispatcher) =
    ## A default globbal dispatcher is already set
    MainEvDispatcher = dispatcher

proc newDispatcher*(): EvDispatcher =
    EvDispatcher(
        selector: newSelector[AsyncData]()
    )

proc hasImmediatePendingCoros(dispatcher: EvDispatcher): bool =
    dispatcher.onNextTickCoros.len() != 0 or
        dispatcher.pendingCoros.len() != 0 or
        dispatcher.checkCoros.len() != 0 or
        dispatcher.closeCoros.len() != 0

proc isEmpty*(dispatcher: EvDispatcher = MainEvDispatcher): bool =
    dispatcher.numOfCorosRegistered == 0 and
        dispatcher.onNextTickCoros.len() == 0 and
        dispatcher.timers.len() == 0 and
        dispatcher.pendingCoros.len() == 0 and
        dispatcher.checkCoros.len() == 0 and
        dispatcher.closeCoros.len() == 0

proc processNextTickCoros(dispatcher: var EvDispatcher, timeout: TimeOutWatcher) {.inline.} =
    while dispatcher.onNextTickCoros.len() > 0 and not timeout.expired:
        dispatcher.onNextTickCoros.popFirst().resume()

proc processTimers(dispatcher: var EvDispatcher, coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or dispatcher.numOfCorosRegistered == 0:
        if timeout.expired():
            break
        if dispatcher.timers.len() == 0:
            break
        if getMonotime() < dispatcher.timers[0].finishAt:
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
        if dispatcher.pendingCoros.len() == 0 or timeout.expired:
            break
        dispatcher.pendingCoros.popFirst().resume()
        processNextTickCoros(dispatcher, timeout)
    # Phase 1 again
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if dispatcher.timers.len() > 0:
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(dispatcher.timers[0].finishAt - getMonoTime()),
                EvDispatcherTimeoutMs)        
        else:

            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(dispatcher.timers[0].finishAt - getMonoTime()),
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
            var asyncData = getData(dispatcher.selector, readyKey.fd)
            if Event.Write in readyKey.events:
                let len = asyncData.writeList.len()
                dispatcher.numOfCorosRegistered -= len
                if len > 0: hasResumedCoro = true
                for coro in move(asyncData.writeList): # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros(dispatcher, timeout)
            if {Event.Write} != readyKey.events:
                let len = asyncData.readList.len()
                dispatcher.numOfCorosRegistered -= len
                if len > 0: hasResumedCoro = true
                for coro in move(asyncdata.readList): # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros(dispatcher, timeout)
            if asyncData.unregisterWhenTriggered:
                dispatcher.selector.unregister(readyKey.fd)
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(dispatcher, coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.checkCoros.len() == 0 or timeout.expired:
            break
        dispatcher.checkCoros.popFirst().resume()
        processNextTickCoros(dispatcher, timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if dispatcher.closeCoros.len() == 0:
            break
        dispatcher.closeCoros.popFirst().resume()
        processNextTickCoros(dispatcher, timeout)

proc runEvDispatcher*(dispatcher: var EvDispatcher, timeoutMs = -1) =
    ## Run the event loop until it is empty
    ## Only two kinds of deadlocks can happen:
    ## - if at least one coroutine waits for an event that never happens
    ## - if a coroutine never stops, or recursivly add coroutines
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not dispatcher.isEmpty() and not timeout.expired:
        runOnce(dispatcher, timeout.getRemainingMs())

proc runEvDispatcher*(timeoutMs = -1) =
    runEvDispatcher(MainEvDispatcher, timeoutMs)

proc runEvDispatcherForever*(dispatcher: var EvDispatcher, timeoutMs = -1, stopFlag: var bool = false) =
    ## Run the event loop even if empty (causing a deadlock on main thread)
    ## To use inside a dedicated thread or with a timeout
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not (stopFlag or timeout.expired):
        while dispatcher.isEmpty() and not timeout.expired:
            sleep(SleepMsIfEmpty)
        runOnce(dispatcher, timeout.getRemainingMs())

proc runEvDispatcherForever*(timeoutMs = -1, stopFlag: var bool = false) =
    runEvDispatcherForever(MainEvDispatcher, timeoutMs, stopFlag)

#[ *** Poll fd API *** ]#

proc registerEvent*(
    ev: SelectEvent,
    coros: seq[CoroutineBase] = @[],
    dispatcher: var EvDispatcher = MainEvDispatcher
) =
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    dispatcher.selector.registerEvent(ev, AsyncData(readList: coros))

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
    dispatcher: var EvDispatcher = MainEvDispatcher,
): PollFd =
    dispatcher.selector.registerHandle(fd, events, AsyncData())
    return PollFd(fd)

proc registerProcess*(
    pid: int,
    coros: seq[CoroutineBase] = @[],
    unregisterWhenTriggered = true,
    dispatcher: var EvDispatcher = MainEvDispatcher
): PollFd =
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    PollFd(dispatcher.selector.registerProcess(pid,
        AsyncData(readList: coros, unregisterWhenTriggered: unregisterWhenTriggered))
    )

proc registerSignal*(
    signal: int,
    coros: seq[CoroutineBase] = @[],
    unregisterWhenTriggered = true,
    dispatcher: var EvDispatcher = MainEvDispatcher
): PollFd =
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    PollFd(dispatcher.selector.registerSignal(signal,
        AsyncData(readList: coros, unregisterWhenTriggered: unregisterWhenTriggered))
    )

proc registerTimer*(
    timeout: int,
    oneshot: bool = true,
    coros: seq[CoroutineBase] = @[],
    dispatcher: var EvDispatcher = MainEvDispatcher,
): PollFd =
    ## Timer is registered inside the poll, not inside the event loop
    ## Use another function to sleep inside the event loop (more reactive, less overhead)
    if coros.len() > 0: dispatcher.numOfCorosRegistered += coros.len()
    PollFd(dispatcher.selector.registerTimer(timeout, true,
        AsyncData(readList: coros, unregisterWhenTriggered: oneshot))
    )

proc unregister*(fd: PollFd, dispatcher: var EvDispatcher = MainEvDispatcher) =
    var asyncData = dispatcher.selector.getData(fd.int)
    dispatcher.numOfCorosRegistered -= asyncData.readList.len()
    dispatcher.numOfCorosRegistered -= asyncData.writeList.len()
    dispatcher.selector.unregister(fd.int)

proc suspendUntilRead*(fd: PollFd) =
    ## Will not update kind of events listening, this should be given/updated at registration
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    let dispatcher = getGlobalDispatcher()
    dispatcher.selector.getData(fd.int).readList.add(coro)
    suspend()


MainEvDispatcher = newDispatcher()