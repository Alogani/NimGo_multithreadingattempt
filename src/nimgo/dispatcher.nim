import ./coroutines {.all.}
import std/[selectors, heapqueue, times, monotimes]

## Following to resolve:
## - runEventLoop never stops (need to empty selector)
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

    EventDispatcher = ref object
        ## Resume coroutines when events are triggered
        selector: Selector[AsyncData]
        pendingCoroutines: seq[CoroutineBase]
        pendingTimers: HeapQueue[tuple[finishAt: MonoTime, fut: CoroutineBase]]

    AsyncFd* = distinct int

var MainEvDispatcher: EventDispatcher # Automatically set on import

proc getGlobalDispatcher*(): EventDispatcher =
    return MainEvDispatcher

proc setGlobalDispatcher*(): EventDispatcher =
    ## A default globbal dispatcher is already set
    return MainEvDispatcher

proc newDispatcher*(): EventDispatcher =
    EventDispatcher(
        selector: newSelector[AsyncData]()
    )

proc poll*(timeoutMs: int) =
    ## Run the event loop once with a limited wait time
    ## Wait time is not guaranted to be accurate
    let dispatcher = getGlobalDispatcher()
    let timeout = TimeOutWatcher.init(timeoutMs)
    for coro in dispatcher.pendingCoroutines:
        coro.resume()
    var readyKeyList = dispatcher.selector.select(timeout.getRemainingMs())
    for readyKey in readyKeyList:
        if Event.Write in readyKey.events:
            for coro in getData(dispatcher.selector, readyKey.fd).writeList:
                coro.resume()
        if {Event.Write} != readyKey.events:
            for coro in getData(dispatcher.selector, readyKey.fd).readList:
                coro.resume()
    
proc runEventLoop*() =
    ## Run the event loop until it is empty
    # if inside other thread, needs a channel to get data
    while MainEvDispatcher.pendingCoroutines.len() > 0 or not MainEvDispatcher.selector.isEmpty():
        poll(-1)

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