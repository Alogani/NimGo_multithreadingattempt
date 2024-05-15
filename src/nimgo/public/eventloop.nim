import ../coroutines {.all.}
import std/[selectors, deques, heapqueue, times, monotimes]

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
    TimeOutWatcher = object
        beginTime: Time
        timeoutMs: int

proc init(T: type TimeOutWatcher, timeoutMs: int): T =
    TimeOutWatcher(
        beginTime: if timeoutMs != -1: getTime() else: Time(),
        timeoutMs: timeoutMs
    )

proc expired(self: TimeOutWatcher): bool =
    if self.timeoutMs == -1:
        return false
    if self.timeoutMs < (getTime() - self.beginTime).inMilliseconds():
        return true
    return false

proc getRemainingMs(self: TimeOutWatcher): int =
    if self.timeoutMs == -1:
        return -1
    let remaining = self.timeoutMs - (getTime() - self.beginTime).inMilliseconds()
    if remaining < 0:
        return 0
    else:
        return remaining


#[ *** Event loop *** ]#

type
    AsyncData = object
        readList: seq[CoroutineBase] # Also stores all other event kind
        writeList: seq[CoroutineBase]

    EventLoop = object
        onNextTickCoros: Deque[CoroutineBase]
        # In the same order as the runOnce execution:
        timers: HeapQueue[tuple[finishAt: MonoTime, coro: CoroutineBase]] # Thresold and not exact time
        pendingCoros: Deque[CoroutineBase]
        selector: Selector[AsyncData]
        checkCoros: Deque[CoroutineBase] # Executed after the poll phase
        closeCoros: Deque[CoroutineBase]
        
    AsyncFd* = distinct int

const SleepMsIfInactive = 50 # to avoid busy waiting
const CoroLimitByPhase = 20 # To avoid exhaustion
const NimGoNoThread {.booldefine.} = true
when NimGoNoThread:
    const EventLoopTimeoutMs = -1
else:
    const EventLoopTimeoutMs {.intdefine.} = 100

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

proc processNextTickCoros() {.inline.} =
    while MainEvDispatcher.onNextTickCoros.len() > 0:
        MainEvDispatcher.onNextTickCoros.popFirst().resume()

proc processTimers(coroLimitForTimer: var int) =
    while coroLimitForTimer < CoroLimitByPhase:
        if MainEvDispatcher.timers.len() == 0:
            break
        if getMonotime() < MainEvDispatcher.timers[0].finishAt:
            break
        MainEvDispatcher.timers.pop().coro.resume()
        processNextTickCoros()
        coroLimitForTimer += 1

proc runOnce(evLoop: var EventLoop = MainEvDispatcher): bool =
    ## Run the event loop
    ## Return false if no coroutine were executed
    let hasImmediatePendingCoro = (
        evLoop.onNextTickCoros.len() != 0 or
        evLoop.pendingCoros.len() != 0 or
        evLoop.checkCoros.len() != 0 or
        evLoop.closeCoros.len() != 0
        )
    processNextTickCoros()
    # Phase 1: process timers
    var coroLimitForTimer = 0
    processTimers(coroLimitForTimer)
    # Phase 2: process pending
    for i in 0 ..< CoroLimitByPhase:
        if evLoop.pendingCoros.len() == 0:
            break
        evLoop.pendingCoros.popFirst().resume()
        processNextTickCoros()
    # Phase 1 again
    processTimers(coroLimitForTimer)
    # PrePhase 3: calculate the poll timeout
    var pollTimeoutMs: int
    if evLoop.timers.len() > 0:
        let remaining = inMilliseconds(evLoop.timers[0].finishAt - getMonoTime())
        if remaining < 0:
            pollTimeoutMs = 0
        elif EventLoopTimeoutMs == -1:
            pollTimeoutMs = remaining
        else:
            pollTimeoutMs = min(EventLoopTimeoutMs, remaining)
    else:
        pollTimeoutMs = EventLoopTimeoutMs
    # Phase 3: poll for I/O
    var pollCoroWasTriggered = false
    if not evLoop.selector.isEmpty():
        var readyKeyList = evLoop.selector.select(pollTimeoutMs)
        for readyKey in readyKeyList:
            var asyncData = getData(evLoop.selector, readyKey.fd)
            if Event.Write in readyKey.events:
                pollCoroWasTriggered = pollCoroWasTriggered or asyncData.writeList.len() > 0
                for coro in move(asyncData.writeList): # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros()
            if {Event.Write} != readyKey.events:
                pollCoroWasTriggered = pollCoroWasTriggered or asyncData.readList.len() > 0
                for coro in move(asyncdata.readList): # We use move here to empty the queue
                    coro.resume()
                    processNextTickCoros()
    # Phase 1 again
    processTimers(coroLimitForTimer)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if evLoop.checkCoros.len() == 0:
            break
        evLoop.checkCoros.popFirst().resume()
        processNextTickCoros()
    # Phase 5: process "close" coros
    for i in 0 ..< CoroLimitByPhase:
        if evLoop.closeCoros.len() == 0:
            break
        evLoop.closeCoros.popFirst().resume()
        processNextTickCoros()
    # Let us know if some coro were executed
    return hasImmediatePendingCoro or pollCoroWasTriggered
    
proc runEventLoop*(evLoop: var EventLoop = MainEvDispatcher) =
    ## Run the event loop until it is empty
    # if inside other thread, needs a channel to get data
    while MainEvDispatcher.pendingCoroutines.len() > 0 or not MainEvDispatcher.selector.isEmpty():
        poll(-1)
        #> problem, when to know if really empty ???

proc suspendUntilTime*(timeout: int) =
    ## Suspend and register the current coroutine inside the Event loop
    ## Coroutine will be resumed when Timer is done
    ## Can only be done inside a coroutine. Use `sleepAsync` if you want to sleep anywhere
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    let dispatcher = getGlobalDispatcher()
    dispatcher.pendingTimers.push(
        (getMonotime() + initDuration(milliseconds = timeout), coro)
    )
    suspend()

proc suspendUntilRead*(fd: AsyncFd) =
    let coro = getRunningCoroutine()
    if coro == nil: raise newException(ValueError, "Can only suspend inside a coroutine")
    let dispatcher = getGlobalDispatcher()
    dispatcher.selector.registerHandle(fd.int, {Read}, AsyncData(readList: @[coro]))
    suspend()


MainEvDispatcher = newDispatcher()