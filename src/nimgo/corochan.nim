## Channels for coroutines. Incompatible with thread channels

import std/deques
import ./private/sharedptrs
import ./coroutines {.all.}

type
    CoroChanObj[T] = object
        listener: CoroutineBase
        suspendedListening: bool
        data: Deque[T]
        closed: bool

    CoroChan*[T] = SharedPtr[CoroChanObj[T]]

proc newCoroChan*[T](): CoroChan[T] =
    result = newSharedPtr0(CoroChanObj[T])

proc setListener*[T](chan: CoroChan[T], coro: CoroutineBase) =
    chan[].listener = coro

proc close*[T](chan: CoroChan[T]) =
    chan[].closed = true
    if chan[].suspendedListening:
        chan[].listener.resume()

proc send*[T](chan: CoroChan[T], data: T) =
    if chan[].closed:
        raise newException(ValueError, "CoroChan is closed")
    chan[].data.addLast data
    if chan[].suspendedListening:
        chan[].listener.resume()

proc receive*[T](chan: CoroChan[T]): T =
    if chan[].closed:
        raise newException(ValueError, "CoroChan is closed")
    if chan[].data.len() == 0:
        chan[].suspendedListening = true
        suspend()
        if chan[].closed:
            raise newException(ValueError, "CoroChan is closed")
    return chan[].data.popFirst()

iterator items*[T](chan: CoroChan[T]): T {.inline.} =
    while not chan[].closed:
        if chan[].data.len() == 0:
            chan[].suspendedListening = true
            suspend()
        else:
            yield chan[].data.popFirst()