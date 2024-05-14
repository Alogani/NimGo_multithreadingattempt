import ./coroutines {.all.}
import std/[selectors, times]

type
    AsyncData = object
        readList: seq[CoroutineBase] # Also stores all other event kind
        writeList: seq[CoroutineBase]

    EventDispatcher = object
        ## Resume coroutines when events are triggered
        selector: Selector[AsyncData]
        pendingCoroutines: seq[CoroutineBase]

var MainEvDispatcher: EventDispatcher

proc getGlobalDispatcher*(): EventDispatcher =
    return MainEvDispatcher

proc setGlobalDispatcher*(): EventDispatcher =
    ## A default globbal dispatcher is already set
    return MainEvDispatcher

proc newDispatcher*(): EventDispatcher =
    discard

proc poll*(timeoutMs: int) =
    ## Run the event loop a limited time period
    let dispatcher = getGlobalDispatcher()
    var beginTime: Time
    if timeoutMs != -1: beginTime = getTime()
    for coro in dispatcher.pendingCoroutines:
        coro.resume()
    let remainingTimeout = (if timeoutMs != -1:
            let remaining = timeoutMs - (getTime() - beginTime).inMilliseconds()
            if remaining < 0:
                return
            remaining
        else:
            timeoutMs)
    var readyKeyList = dispatcher.selector.select(remainingTimeout)
    for readyKey in readyKeyList:
        if Event.Write in readyKey.events:
            for coro in getData(dispatcher.selector, readyKey.fd).writeList:
                coro.resume()
        if {Event.Write} != readyKey.events:
            for coro in getData(dispatcher.selector, readyKey.fd).readList:
                coro.resume()

    
proc runForever*() =
    ## Run the event loop forever
    # if inside other thread, needs a channel to get data
    while MainEvDispatcher.pendingCoroutines.len() > 0 and not MainEvDispatcher.selector.isEmpty():
        poll(-1)
