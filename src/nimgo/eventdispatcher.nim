import ./coroutines {.all.}
import ./private/[threadqueue, threadprimitives, smartptrs]
import std/exitprocs
import std/[deques, heapqueue]
import std/[os, selectors, nativesockets]
import std/[times, monotimes]

export Event

const NimGoNoThread* {.booldefine.} = false
    ## Setting this add some optimizations due to the absence of thread and implies NimGoNoStart
when defined(NimGoNoThread):
    const NimGoNoStart* = true
else:
    const NimGoNoStart* {.booldefine.} = false
    ## Setting this flag prevents NimGo event loop from autostarting

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
## - For now, `onNextTickCoros`, `timers`, `pendingCoros`, `checkCoros` and `closeCoros` are not used
## 


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
        readList: seq[Coroutine] # Also stores all other event kind
        writeList: seq[Coroutine]
        unregisterWhenTriggered: bool

    PollFd* = distinct int
        ## Reprensents a descriptor registered in the EventDispatcher: file handle, signal, timer, etc.

    BoolFlagRef* = ref object
        ## Must be stored globally to avoid GC if used between threads
        value*: bool

    CoroutineWithTimer = tuple[finishAt: MonoTime, coro: Coroutine]

    EvDispatcherObj = object
        running: bool
        # Following need the pollLock.
        # Atomic not used for simpler code on avoiding object copy (elements changed at same time)
        corosCountInPoll: int
        selector: Selector[AsyncData]
        # For the order of execution, see preamble
        externCoros: ThreadQueue[Coroutine] # Coroutines added from another thread
        onNextTickCoros: Deque[Coroutine]
        timers: HeapQueue[CoroutineWithTimer] # Thresold and not exact time
        pendingCoros: Deque[Coroutine]
        checkCoros: Deque[Coroutine]
        closeCoros: Deque[Coroutine]

    EvDispatcher* = SharedPtr[EvDispatcherObj]
        ## The main dispatcher object. It can be copied and moved around thread so that multiple thread share the same dispatcher
        ## A single dispatcher can be run in only one thread (aka the dispatcher thread).
        ## But each thread can create and run its own unique dispatcher.
        ## All coroutines registered in the dispatcher will be run in the dispatcher thread.
        ## It's unsafe to interact with the dispatcher in another thread, at the exception of `registerExternCoros` proc
    
const EvDispatcherTimeoutMs {.intdefine.} = 100 # We don't block on poll phase if new coros were registered
const SleepMsIfInactive = 30 # to avoid busy waiting. When selector is not empty, but events triggered with no associated coroutines
const SleepMsIfEmpty = 50 # to avoid busy waiting. When the event loop is empty
const CoroLimitByPhase = 30 # To avoid starving the coros inside the poll

var InsideDispatcherThread {.threadvar.}: bool
var ActiveDispatcher {.threadvar.}: EvDispatcher

proc newDispatcher*(): EvDispatcher
ActiveDispatcher = newDispatcher()

proc setCurrentThreadDispatcher*(dispatcher: EvDispatcher) =
    ActiveDispatcher = dispatcher

proc getCurrentThreadDispatcher*(): EvDispatcher =
    return ActiveDispatcher

proc newDispatcher*(): EvDispatcher =
    result = newSharedPtr(EvDispatcherObj(
        externCoros: newThreadQueue[Coroutine]()
    ))
    result[].selector = newSelector[AsyncData]()

proc `<`(a, b: CoroutineWithTimer): bool =
    a.finishAt < b.finishAt

proc isDispatcherEmpty*(dispatcher: EvDispatcher = ActiveDispatcher): bool =
    dispatcher[].corosCountInPoll == 0 and
        dispatcher[].externCoros.empty() and
        dispatcher[].onNextTickCoros.len() == 0 and
        dispatcher[].timers.len() == 0 and
        dispatcher[].pendingCoros.len() == 0 and
        dispatcher[].checkCoros.len() == 0 and
        dispatcher[].closeCoros.len() == 0

proc processNextTickCoros(timeout: TimeOutWatcher) {.inline.} =
    while not (ActiveDispatcher[].onNextTickCoros.len() == 0 or timeout.expired):
        ActiveDispatcher[].onNextTickCoros.popFirst().resume()

proc processExternCoros(timeout: TimeOutWatcher) =
    ## This coro should be not started (otherwise not safe). This is the reason why we don't check/wait for them to be suspended
    for i in 0 ..< CoroLimitByPhase:
        let coro = ActiveDispatcher[].externCoros.popFirst()
        if coro.isNone() or timeout.expired():
            break
        resume(coro.unsafeGet())
        processNextTickCoros(timeout)

proc processTimers(coroLimitForTimer: var int, timeout: TimeOutWatcher) =
    while coroLimitForTimer < CoroLimitByPhase or ActiveDispatcher[].corosCountInPoll == 0:
        if timeout.expired():
            break
        if ActiveDispatcher[].timers.len() == 0:
            break
        if getMonotime() < ActiveDispatcher[].timers[0].finishAt:
            break
        ActiveDispatcher[].timers.pop().coro.resume()
        processNextTickCoros(timeout)
        coroLimitForTimer += 1

proc runOnce(timeoutMs: int) =
    ## Run the event loop. The poll phase is done only once
    ## Timeout is a thresold and can be taken in account lately
    let timeout = TimeOutWatcher.init(timeoutMs)
    processNextTickCoros(timeout)
    # Phase 1: process timers
    var coroLimitForTimer = 0
    processTimers(coroLimitForTimer, timeout)
    # Phase 2: process pending
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher[].pendingCoros.len() == 0 or timeout.expired():
            break
        ActiveDispatcher[].pendingCoros.popFirst().resume()
        processNextTickCoros(timeout)
    processExternCoros(timeout)
    # Phase 1 again
    processTimers(coroLimitForTimer, timeout)
    # PrePhase 3: calculate the poll timeout
    if timeout.expired:
        return
    var pollTimeoutMs: int
    if not ActiveDispatcher[].timers.len() == 0:
        if timeout.hasNoDeadline():
            pollTimeoutMs = clampTimeout(
                inMilliseconds(ActiveDispatcher[].timers[0].finishAt - getMonoTime()),
                EvDispatcherTimeoutMs)
        else:
            pollTimeoutMs = clampTimeout(min(
                inMilliseconds(ActiveDispatcher[].timers[0].finishAt - getMonoTime()),
                timeout.getRemainingMs()
            ), EvDispatcherTimeoutMs)
    elif not timeout.hasNoDeadline():
        pollTimeoutMs = clampTimeout(timeout.getRemainingMs(), EvDispatcherTimeoutMs)
    else:
        pollTimeoutMs = EvDispatcherTimeoutMs
    # Phase 3: poll for I/O
    while ActiveDispatcher[].corosCountInPoll != 0:
        # The event loop could return with no work if an event is triggered with no coroutine
        # If so, we will sleep and loop again
        var readyKeyList = ActiveDispatcher[].selector.select(pollTimeoutMs)
        var hasResumedCoro: bool
        if readyKeyList.len() == 0:
            break # timeout expired
        for readyKey in readyKeyList:
            var asyncData = getData(ActiveDispatcher[].selector, readyKey.fd)
            var writeList: seq[Coroutine]
            var readList: seq[Coroutine]
            if Event.Write in readyKey.events:
                writeList = move(asyncData.writeList)
            if readyKey.events.card() > 0 and {Event.Write} != readyKey.events:
                readList = move(asyncData.readList)
            ActiveDispatcher[].corosCountInPoll -= writeList.len() + readList.len()
            if writeList.len() > 0 or readList.len() > 0:
                hasResumedCoro = true
            for coro in writeList:
                coro.resume()
                processNextTickCoros(timeout)
            for coro in readList:
                coro.resume()
                processNextTickCoros(timeout)
            if asyncData.unregisterWhenTriggered:
                ActiveDispatcher[].selector.unregister(readyKey.fd)
        if hasResumedCoro:
            break
        sleep(SleepMsIfInactive)
    # Phase 1 again
    processTimers(coroLimitForTimer, timeout)
    # Phase 4: process "check" coros
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher[].checkCoros.len() == 0 or timeout.expired:
            break
        ActiveDispatcher[].checkCoros.popFirst().resume()
        processNextTickCoros(timeout)
    # Phase 5: process "close" coros, even if timeout is expired
    for i in 0 ..< CoroLimitByPhase:
        if ActiveDispatcher[].closeCoros.len() == 0:
            break
        ActiveDispatcher[].closeCoros.popFirst().resume()
        processNextTickCoros(timeout)

proc runEventLoop(
        timeoutMs = -1,
        dispatcher = ActiveDispatcher,
        stopWhenEmpty = BoolFlagRef(value: true)
    ) =
    ## run is done in same thread
    ## The same event loop cannot be run twice.
    ## It is automatically run in another thread if `NimGoNoThread` is not set.
    ## If stopWhenEmpty is set to false with no timeout, it will run forever.
    ## Running forever can be useful when run a thread is dedicated to the event loop
    ## Two kinds of deadlocks can happen when stopWhenEmpty = true and no timeoutMs:
    ## - if at least one coroutine waits for an event that never happens
    ## - if a coroutine never stops, or recursivly add coroutines
    let oldDispatcher = ActiveDispatcher
    ActiveDispatcher = dispatcher
    if dispatcher[].running:
        raise newException(ValueError, "Cannot run the same event loop twice")
    let timeout = TimeOutWatcher.init(timeoutMs)
    dispatcher[].running = true
    InsideDispatcherThread = true
    defer:
        dispatcher[].running = false
        InsideDispatcherThread = false
        ActiveDispatcher = oldDispatcher
    while not timeout.expired:
        if dispatcher.isDispatcherEmpty():
            if stopWhenEmpty.value:
                break
            else:
                sleep(SleepMsIfEmpty)
        else:
            runOnce(timeout.getRemainingMs())

when not defined(NimGoNoThread):
    proc runEventLoopThreadImpl(args: (int, EvDispatcher, BoolFlagRef)) {.thread.} =
        runEventLoop(args[0], args[1], args[2])
        

    proc spawnEventLoop*(
            timeoutMs = -1,
            dispatcher = ActiveDispatcher,
            stopWhenEmpty = BoolFlagRef(value: false),
        ) =
        ## eventLoop will run in its dedicated thread
        ## An exit proc will be added to prevent the main thread to stop before the event lopo is empty
        var EventLoopThread: Thread[(int, EvDispatcher, BoolFlagRef)]
        createThread(EventLoopThread, runEventLoopThreadImpl, (-1, dispatcher, stopWhenEmpty))
        #activeDispatchersInThreads.add dispatcher
        addExitProc(proc() =
            if getProgramResult() == 0 and dispatcher[].running:
                stopWhenEmpty.value = true
                joinThread(EventLoopThread)
            )

proc running*(dispatcher = ActiveDispatcher): bool =
    dispatcher[].running

proc runningInAnotherThread*(dispatcher = ActiveDispatcher): bool =
    dispatcher[].running and dispatcher == ActiveDispatcher and not InsideDispatcherThread

#[ *** Coroutine API *** ]#

proc registerExternCoro*(
    coro: Coroutine,
    dispatcher = ActiveDispatcher,
) =
    ## Thread safe, but only if coro were never started
    ## Register in the dispatcher of the same thread
    ## Will register just after the "pending phase"
    dispatcher[].externCoros.addLast coro

proc registerCoro*(coro: Coroutine) =
    ## Not thread safe
    ## Will register in the "pending phase"
    ActiveDispatcher[].pendingCoros.addLast coro

proc registerOnTimer*(coro: Coroutine, timeoutMs: int) =
    ## Not thread safe
    ## Equivalent to a sleep directly handled by the dispatcher
    ActiveDispatcher[].timers.push (
        getMonoTime() + initDuration(milliseconds = timeoutMs),
        coro)

proc registerOnNextTick*(coro: Coroutine) =
    ## Not thread safe
    ActiveDispatcher[].onNextTickCoros.addLast coro

proc registerOnCheckPhase*(coro: Coroutine) =
    ## Not thread safe
    ActiveDispatcher[].checkCoros.addLast coro

proc registerOnClosePhase*(coro: Coroutine) =
    ## Not thread safe
    ActiveDispatcher[].closeCoros.addLast coro

#[ *** Poll fd API *** ]#

proc registerEvent*(
    ev: SelectEvent,
    coros: seq[Coroutine] = @[],
) =
    ## Not thread safe
    if coros.len() > 0: ActiveDispatcher[].corosCountInPoll += coros.len()
    ActiveDispatcher[].selector.registerEvent(ev, AsyncData(readList: coros))

proc registerHandle*(
    fd: int | SocketHandle,
    events: set[Event],
): PollFd =
    ## Not thread safe
    result = PollFd(fd)
    ActiveDispatcher[].selector.registerHandle(fd, events, AsyncData())

proc registerProcess*(
    pid: int,
    coros: seq[Coroutine] = @[],
    unregisterWhenTriggered = true,
): PollFd =
    ## Not thread safe
    if coros.len() > 0: ActiveDispatcher[].corosCountInPoll += coros.len()
    result = PollFd(ActiveDispatcher[].selector.registerProcess(pid, AsyncData(
            readList: coros,
            unregisterWhenTriggered: unregisterWhenTriggered
        )))

proc registerSignal*(
    signal: int,
    coros: seq[Coroutine] = @[],
    unregisterWhenTriggered = true,
): PollFd =
    ## Not thread safe
    if coros.len() > 0: ActiveDispatcher[].corosCountInPoll += coros.len()
    result = PollFd(ActiveDispatcher[].selector.registerSignal(signal, AsyncData(
        readList: coros,
        unregisterWhenTriggered: unregisterWhenTriggered
    )))

proc registerTimer*(
    timeoutMs: int,
    oneshot: bool = true,
    coros: seq[Coroutine] = @[],
): PollFd =
    ## Not thread safe.
    ## Timer is registered inside the poll, not inside the event loop.
    ## Use another function to sleep inside the event loop (more reactive, less overhead for short sleep)
    ## Coroutines will only be resumed once, even if timer is not oneshot. You need to associate them to the fd each time for a periodic action
    if coros.len() > 0: ActiveDispatcher[].corosCountInPoll += coros.len()
    result = PollFd(ActiveDispatcher[].selector.registerTimer(timeoutMs, oneshot, AsyncData(
        readList: coros,
        unregisterWhenTriggered: oneshot
    )))

proc unregister*(fd: PollFd) =
    ## Not thread safe
    var asyncData = ActiveDispatcher[].selector.getData(fd.int)
    ActiveDispatcher[].selector.unregister(fd.int)
    ActiveDispatcher[].corosCountInPoll -= asyncData.readList.len() + asyncData.writeList.len()
    # If readList or writeList contains coroutines, they should be destroyed thanks to sharedPtr

proc addInsideSelector*(fd: PollFd, coro: seq[Coroutine], event: Event) =
    ## Not thread safe
    ## Will not update the type event listening
    ActiveDispatcher[].corosCountInPoll += 1
    if event == Event.Write:
        ActiveDispatcher[].selector.getData(fd.int).writeList.add(coro)
    else:
        ActiveDispatcher[].selector.getData(fd.int).readList.add(coro)

proc addInsideSelector*(fd: PollFd, coro: Coroutine, event: Event) =
    ## Not thread safe
    ## Will not update the type event listening
    ActiveDispatcher[].corosCountInPoll += 1
    if event == Event.Write:
        ActiveDispatcher[].selector.getData(fd.int).writeList.add(coro)
    else:
        ActiveDispatcher[].selector.getData(fd.int).readList.add(coro)

proc updatePollFd*(fd: PollFd, events: set[Event]) =
    ## Not thread safe
    ActiveDispatcher[].selector.updateHandle(fd.int, events)

proc suspendUntilRead*(fd: PollFd) =
    ## If multiple coros are suspended for the same PollFd and one consume it, the others will deadlock
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    let coro = getCurrentCoroutine()
    #if coro.isNil(): raise newException(ValueError, "Can only suspend inside a coroutine")
    addInsideSelector(fd, coro, Event.Read)
    suspend()

proc suspendUntilWrite*(fd: PollFd) =
    ## If multiple coros are suspended for the same PollFd and one consume it, the others will deadlock
    ## If PollFd is not a file, by definition only the coros in the readList will be resumed
    let coro = getCurrentCoroutine()
    #if coro.isNil(): raise newException(ValueError, "Can only suspend inside a coroutine")
    addInsideSelector(fd, coro, Event.Write)
    suspend()

when not defined(NimGoNoStart) and not defined(NimGoNoThread):
    spawnEventLoop()