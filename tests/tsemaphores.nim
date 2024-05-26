import nimgo/[coroutines, eventdispatcher]
import nimgo/public/gosemaphores

import std/[os, times, monotimes]
import std/unittest

proc expectedTimeRange(t0: MonoTime, minMs, maxMs: int) =
    let currentTimeElapsed = inMilliseconds(getMonoTime() - t0)
    check currentTimeElapsed >= minMs
    check currentTimeElapsed < maxMs

test "Thread signal - coro waiter / wake up immediatly":
    proc main() =
        var sem = newGoSemaphore()
        let t0 = getMonoTime()
        proc mainCoro() =
            check sem.waitWithTimeout(2000) == true
            expectedTimeRange(t0, 0, 60) # Empty event loop has a bigger sleep thresold

        registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
        sem.signal()
    main()

test "Thread signal - coro waiter / wake up after sleep":
    proc main() =
        var sem = newGoSemaphore()
        let t0 = getMonoTime()
        proc mainCoro() =
            check sem.waitWithTimeout(2000) == true
            expectedTimeRange(t0, 500, 520)

        registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
        sleep(500)
        sem.signal()
    main()

test "coro waiter / no wake up":
    proc main() =
        var sem = newGoSemaphore()
        let t0 = getMonoTime()
        proc mainCoro() =
            check sem.waitWithTimeout(2000) == false
            expectedTimeRange(t0, 2000, 2020)

        registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
    main()

test "Coro signal - thread waiter / wake up immediatly + no wake up":
    proc main() =
        var sem = newGoSemaphore()
        proc mainCoro() =
            sem.signal()
        registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
        let t0 = getMonoTime()
        check sem.waitWithTimeout(2000) == true
        check sem.waitWithTimeout(100) == false
        expectedTimeRange(t0, 100, 160)
    main()

test "Coro signal - thread waiter / wake up after sleep":
    proc main() =
        var sem = newGoSemaphore()
        proc mainCoro() =
            let currentCoro = getCurrentCoroutine()
            registerOnSchedule(currentCoro, 500)
            suspend(currentCoro)
            sem.signal()
        registerExternCoro(getCurrentThreadDispatcher(), newCoroutine(mainCoro))
        let t0 = getMonoTime()
        check sem.waitWithTimeout(2000) == true
        expectedTimeRange(t0, 500, 560)
    main()
