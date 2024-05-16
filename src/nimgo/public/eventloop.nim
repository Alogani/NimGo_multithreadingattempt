import ../coroutines {.all.}
import std/[os, selectors, nativesockets]
import std/[deques, heapqueue, times, monotimes]

#[
    Event loop implementation close to how the nodejs/libuv one's works (for more details: https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick).
    With the main difference of resuming coroutines instead of running callbacks (I'll use "worker" term to design the code answering an event)
    As so, it shares the main advantages and drawbacks. Mainly :
        - If multiple workers listen to the same event, they will be both runned, even if the event is consumed (could result in a blocking operation)
        - Worker execution pauses the event loop, and will delay the execution of the event loop, and by extension other workers
          This could have a negative impact on the overall performance and responsivness
    But here are principal differences with the nodejs implementation:
        - The poll phase will not wait indefinitly for I/O events if no timers are registers (unless NimGoNoThread is set)
          It will instead wait for a maximum of time defined by `EventLoopTimeOut` constant (can be tweaked with `-d:EventLoopTimeOut:Number`)
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

#[ *** Event loop *** ]#

type
    AsyncData = object
        readList: seq[CoroutineBase] # Also stores all other event kind
        writeList: seq[CoroutineBase]

    EventLoop = object
        numOfCorosRegistered: int # Inside the selector only
        onNextTickCoros: Deque[CoroutineBase]
        # In the same order as the runOnce execution:
        timers: HeapQueue[tuple[finishAt: MonoTime, coro: CoroutineBase]] # Thresold and not exact time
        pendingCoros: Deque[CoroutineBase]
        selector: Selector[AsyncData]
        checkCoros: Deque[CoroutineBase] # Executed after the poll phase
        closeCoros: Deque[CoroutineBase]
        
    AsyncFd* = distinct int

const NimGoNoThread {.booldefine.} = true
const EventLoopTimeoutMs {.intdefine.} = 100
const SleepMsIfInactive = 30 # to avoid busy waiting. When selector is not empty, but events triggered with no associated coroutines
const SleepMsIfEmpty = 50 # to avoid busy waiting. When the event loop is empty
const CoroLimitByPhase = 30 # To avoid starving the coros inside the poll
var MainEvDispatcher: EventLoop # Automatically set on import

proc getGlobalDispatcher*(): var EventLoop =
    return MainEvDispatcher

proc setGlobalDispatcher*(dispatcher: EventLoop) =
    ## A default globbal dispatcher is already set
    MainEvDispatcher = dispatcher

proc newDispatcher*(): EventLoop =
    EventLoop(
        selector: newSelector[AsyncData]()
    )

proc hasImmediatePendingCoros(evLoop: EventLoop): bool =
    evLoop.onNextTickCoros.len() != 0 or
        evLoop.pendingCoros.len() != 0 or
        evLoop.checkCoros.len() != 0 or
        evLoop.closeCoros.len() != 0

proc isEmpty*(evLoop: EventLoop = MainEvDispatcher): bool =
    evLoop.numOfCorosRegistered == 0 and
        evLoop.onNextTickCoros.len() == 0 and
        evLoop.timers.len() == 0 and
        evLoop.pendingCoros.len() == 0 and
        evLoop.checkCoros.len() == 0 and
        evLoop.closeCoros.len() == 0

proc processNextTickCoros(evLoop: var EventLoop, timeout: TimeOutWatcher) {.inline.} =
    while evLoop.onNextTickCoros.len() > 0 and not timeout.expired:
        evLoop.onNextTickCoros.popFirst().resume()

proc processTimers(evLoop: var EventLoop, coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or evLoop.numOfCorosRegistered == 0:
        if timeout.expired():
            break
        if evLoop.timers.len() == 0:
            break
        if getMonotime() < evLoop.timers[0].finishAt:
            break
        evLoop.timers.pop().coro.resume()
        processNextTickCoros(evLoop, timeout)
        coroLimitForTimer += 1

proc runOnce(evLoop: var EventLoop, timeoutMs: int) =
    ## Run the event loop. The poll phase is done only once
    ## Timeout is a thresold and be taken in account lately
    let timeout = TimeOutWatcher.init(timeoutMs)
    processNextTickCoros(evLoop, timeout)
    # Phase 1: process timers
    var coroLimitForTimer = 0
    processTimers(evLoop, coroLimitForTimer, timeout)
    # Phase 2: process pending
    for i in 0 ..< CoroLimitByPhase:
        if evLoop.pendingCoros.len() == 0 or timeout.expired:
            break
        evLoop.pendingCoros.popFirst().resume()
        processNextTickCoros(evLoop, timeout)
    # Phase 1 again
    processTimers(evLoop, coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if evLoop.timers.len() > 0:
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(evLoop.timers[0].finishAt - getMonoTime()),
                EventLoopTimeoutMs)        
        else:

            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(evLoop.timers[0].finishAt - getMonoTime()),
                timeout.getRemainingMs()
            ), EventLoopTimeoutMs)
    elif timeout.hasNoDeadline():
        pollTimeoutMs = clampTimeout(timeout.getRemainingMs(), EventLoopTimeoutMs)
    else:
        pollTimeoutMs = EventLoopTimeoutMs
    # Phase 3: poll for I/O
    while evLoop.numOfCorosRegistered != 0:
        # The event loop could return with no work if an event is triggered with no coroutine
        # If so, we will sleep and loop again
        var readyKeyList = evLoop.selector.select(pollTimeoutMs)
        var hasResumedCoro: bool
        if readyKeyList.len() == 0:
            break # timeout expired
        for readyKey in readyKeyList:
            var asyncData = getData(evLoop.selector, readyKey.fd)
            if Event.Write in readyKey.events:
                let len = asyncData.writeList.len()
                evLoop.numOfCorosRegistered -= len
                if len > 0: hasResumedCoro = true
                for coro in move(asyncData.writeList): # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros(evLoop, timeout)
            if {Event.Write} != readyKey.events:
                let len = asyncData.readList.len()
                evLoop.numOfCorosRegistered -= len
                if len > 0: hasResumedCoro = true
                for coro in move(asyncdata.readList): # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros(evLoop, timeout)
                if Event.Write notin readyKey.events:
                    ## Concerns Timer, Signal And Process. Because they are oneshot, we will get rid of them
                    evLoop.selector.unregister(readyKey.fd)
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(evLoop, coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if evLoop.checkCoros.len() == 0 or timeout.expired:
            break
        evLoop.checkCoros.popFirst().resume()
        processNextTickCoros(evLoop, timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if evLoop.closeCoros.len() == 0:
            break
        evLoop.closeCoros.popFirst().resume()
        processNextTickCoros(evLoop, timeout)
    
proc runEventLoop*(evLoop: var EventLoop = MainEvDispatcher, timeoutMs = -1) =
    ## Run the event loop until it is empty
    ## Only two kinds of deadlocks can happen:
    ## - if at least one coroutine waits for an event that never happens
    ## - if a coroutine never stops, or recursivly add coroutines
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not evLoop.isEmpty() and not timeout.expired:
        runOnce(evLoop, timeout.getRemainingMs())

proc runEventLoopForever*(evLoop: var EventLoop = MainEvDispatcher, stopFlag: var bool, timeoutMs = -1) =
    ## Run the event loop even if empty (causing a deadlock on main thread)
    ## To use inside a dedicated thread or with a timeout
    let timeout = TimeOutWatcher.init(timeoutMs)
    while not (stopFlag or timeout.expired):
        while evLoop.isEmpty() and not timeout.expired:
            sleep(SleepMsIfEmpty)
        runOnce(evLoop, timeout.getRemainingMs())

proc registerEvent(evLoop: var EventLoop = MainEvDispatcher, ev: SelectEvent) =
    evLoop.selector.registerEvent(ev, AsyncData())

proc registerHandle(evLoop: var EventLoop = MainEvDispatcher, fd: int | SocketHandle;
                       events: set[Event]) =
    evLoop.selector.registerHandle(fd, events, AsyncData())

proc registerProcess(evLoop: var EventLoop = MainEvDispatcher, pid: int) =
    evLoop.selector.registerProcess(pid, AsyncData())

proc registerSignal(evLoop: var EventLoop = MainEvDispatcher, signal: int) =
    evLoop.selector.registerSignal(signal, AsyncData())

proc registerTimer(evLoop: var EventLoop = MainEvDispatcher, timeout: int) =
    evLoop.selector.registerTimer(timeout, true, AsyncData())

proc suspendUntilRead*(fd: AsyncFd) =
    ## Will not update kind of events listening, this should be given/updated at registration
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    let dispatcher = getGlobalDispatcher()
    dispatcher.selector.getData(fd.int).readList.add(coro)
    suspend()


MainEvDispatcher = newDispatcher()