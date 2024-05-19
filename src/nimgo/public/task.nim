import std/macros

import ../coroutines
import ../eventdispatcher

type
    Task*[T] = ref object
        coro: Coroutine[T]

proc goAsyncImpl(fn: proc()): Task[void] {.discardable.} =
    var coro = Coroutine.new(fn)
    addToPending coro
    return Task[void](coro: coro)

proc goAsyncImpl[T](fn: proc(): T): Task[T] {.discardable.} =
    var coro = Coroutine.new(fn)
    addToPending coro
    return Task[T](coro: coro)

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
