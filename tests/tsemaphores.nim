import nimgo/[coroutines, eventdispatcher]
import nimgo/public/gosemaphores

import std/[os, times, monotimes]
import std/unittest

proc expectedTimeRange(t0: MonoTime, minMs, maxMs: int) =
    let currentTimeElapsed = inMilliseconds(getMonoTime() - t0)
    check currentTimeElapsed > minMs
    check currentTimeElapsed < maxMs

test "Thread signal - coro waiter / wake up immediatly":
    var sem = newGoSemaphore()
    proc mainCoro() =
        let t0 = getMonoTime() 
        check sem.waitWithTimeout(2000) == true
        expectedTimeRange(t0, 0, 50)

    registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
    sem.signal()

test "Thread signal - coro waiter / wake up after sleep":
    var sem = newGoSemaphore()
    proc mainCoro() =
        let t0 = getMonoTime() 
        check sem.waitWithTimeout(2000) == true
        expectedTimeRange(t0, 500, 550)

    registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
    sleep(500)
    sem.signal()

test "coro waiter / no wake up":
    var sem = newGoSemaphore()
    proc mainCoro() =
        let t0 = getMonoTime() 
        check sem.waitWithTimeout(2000) == false
        expectedTimeRange(t0, 2000, 2050)

    registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))