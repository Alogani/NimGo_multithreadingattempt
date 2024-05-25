import std/macros

import ../[coroutines, eventdispatcher]
import ./gochannels

type
    GoTask*[T] = ref object
        chan: GoChan[T]

#[
proc goAsyncImpl(fn: proc()): GoTask[void] {.discardable.} =
    var coro = Coroutine.new(fn)
    if runningInAnotherThread():
        getCurrentThreadDispatcher().registerExternCoro coro
    else:
        registerCoro coro
    return GoTask[void](coro: coro)
]#

proc goAsyncImpl[T](fn: proc(): T): GoTask[T] {.discardable.} =
    var coro = Coroutine.new(fn)
    var chan = newGoChannel[T]()
    if runningInAnotherThread():
        getCurrentThreadDispatcher().registerExternCoro coro
    else:
        registerCoro coro
    return GoTask[T](coro: coro)

macro goAsync*(fn: untyped): untyped =
    # Hard to do it without macro
    # But this one is fast to compile (and called less often than async/await)
    return quote do:
        goAsyncImpl proc(): auto =
            `fn`
