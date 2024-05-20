## Channels for coroutines. Incompatible with thread channels

import std/deques
import ./private/smartptrs
import ./coroutines

type
    DequePtr = ptr Deque[]

    CoChannelObj[T] = object
        ## 
        listeners: Deque[Coroutine]
        data: Deque[T]
        closed: bool

    CoChannel*[T] = SharedPtr[CoChannelObj[T]]

proc newCoChannel*[T](maxItems = 0): CoChannel[T] =
    result = newSharedPtr(CoChannelObj[T])

proc close*[T](chan: CoChannel[T]) =
    chan[].closed = true
    for 
        chan[].listener.resume()

proc send*[T](chan: CoChannel[T], data: T) =
    if chan[].closed:
        raise newException(ValueError, "CoChannel is closed")
    chan[].data.addLast data
    if chan[].suspendedListening:
        chan[].listener.resume()

proc receive*[T](chan: CoChannel[T]): T =
    if chan[].closed:
        raise newException(ValueError, "CoChannel is closed")
    if chan[].data.len() == 0:
        chan[].suspendedListening = true
        suspend()
        if chan[].closed:
            raise newException(ValueError, "CoChannel is closed")
    return chan[].data.popFirst()

iterator items*[T](chan: CoChannel[T]): T {.inline.} =
    while not chan[].closed:
        if chan[].data.len() == 0:
            chan[].suspendedListening = true
            suspend()
        else:
            yield chan[].data.popFirst()