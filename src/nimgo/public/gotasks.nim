import std/macros

import ../[coroutines, eventdispatcher]
import ./gosemaphores

type
    GoTask*[T] = ref object
        coro: Coroutine
        sem: GoSemaphore

#[
proc goAsyncImpl(fn: proc()): GoTask[void] {.discardable.} =
    var coro = Coroutine.new(fn)
    if runningInAnotherThread():
        getCurrentThreadDispatcher().registerExternCoro coro
    else:
        registerCoro coro
    return GoTask[void](coro: coro)
]#

proc goAsyncImpl[T](sem: GoSemaphore, fn: proc(): T): GoTask[T] {.discardable.} =
    var coro = Coroutine.new(fn)
    if runningInAnotherThread():
        getCurrentThreadDispatcher().registerExternCoro coro
    else:
        registerCoro coro
    return GoTask[T](coro: coro, sem: sem)

template goAsync*[T](fn: proc(): T): GoTask[T] =
    # Hard to do it without macro
    # But this one is fast to compile (and called less often than async/await)
    let semaphore = newGoSemaphore()
    return goAsyncImpl(semaphore,
        proc(): auto =
            `fn`
            semaphore.signal()
    )
