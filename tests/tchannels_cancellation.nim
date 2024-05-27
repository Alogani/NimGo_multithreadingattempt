import nimgo

from nimgo/eventdispatcher import registerExternCoro, getCurrentThreadDispatcher

import std/unittest

withEventLoopThread:
    test "Coroutine Channel":
        proc main[T]() =
            var chan = newGoChannel[T]()
            proc producerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..1:
                    when T is int:
                        discard chan.send(i)
                    else:
                        discard chan.send("data=" & $i)

            proc consumerFn[T](chan: GoChan[T]) {.thread.} =
                when T is int:
                    check chan.recv(100).get() == 0
                    check chan.recv(100).get() == 1
                else:
                    check chan.recv(100).get() == ("data=" & $0)
                    check chan.recv(100).get() == ("data=" & $1)
                check chan.recv(0).isNone()
                check chan.recv(100).isNone()
            let producerCoro = newCoroutine(proc() = producerFn[T](chan))
            let consumerCoro = newCoroutine(proc() = consumerFn[T](chan))
            registerExternCoro(getCurrentThreadDispatcher(), producerCoro)
            registerExternCoro(getCurrentThreadDispatcher(), consumerCoro)
        main[int]()
        main[string]()