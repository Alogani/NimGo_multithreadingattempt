import std/macros

import ../coroutines
import ../eventdispatcher

type
    GoTask*[T] = ref object
        coro: Coroutine

proc goAsyncImpl(fn: proc()): GoTask[void] {.discardable.} =
    var coro = Coroutine.new(fn)
    if runningInAnotherThread():
        getCurrentThreadDispatcher().registerExternCoro coro
    else:
        registerCoro coro
    return GoTask[void](coro: coro)

proc goAsyncImpl[T](fn: proc(): T): GoTask[T] {.discardable.} =
    var coro = Coroutine.new(fn)
    if runningInAnotherThread():
        getCurrentThreadDispatcher().registerExternCoro coro
    else:
        registerCoro coro
    return GoTask[T](coro: coro)

macro goAsync*(fn: untyped): untyped =
    # Hard to do it without macro
    # But this one is fast to compile (and called less often than async/await)
    case fn.kind
    of nnkCall:
        return quote do:
            goAsyncImpl proc(): auto =
                `fn`
    of nnkIdent:
        return quote do:
            goAsyncImpl `fn`
    else:
        error("Provide a function")
