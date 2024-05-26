import ./[coroutines, eventdispatcher]
import ./public/gosemaphores

import os

var sem = newGoSemaphore()
proc mainCoro() =
    echo "Begin waiting"
    echo "RES=", sem.waitWithTimeout(2000)
    echo "done waiting"

var coro = newCoroutine(mainCoro)
registerExternCoro(getCurrentThreadDispatcher(), coro)
sem.signal()