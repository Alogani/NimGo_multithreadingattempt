import ./[coroutines, eventdispatcher]
import ./public/gosemaphores

import std/[os, times, monotimes]

withEventLoopThread:
    var sem = newGoSemaphore()
    let t0 = getMonoTime()
    proc mainCoro() {.gcsafe.} =
        echo "RES=", sem.waitWithTimeout(2000)
        echo "done in ", inMilliseconds(getMonoTime() - t0)

    var coro = newCoroutine(mainCoro)
    registerExternCoro(getCurrentThreadDispatcher(), coro)
    sleep(100)
    sem.signal()
