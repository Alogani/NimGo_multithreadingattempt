import nimgo
from nimgo/eventdispatcher import registerExternCoro, getCurrentThreadDispatcher

import os

import std/unittest

withEventLoopThread:
    test "Coroutine Channel fill first":
        proc main[T]() =
            var chan = newGoChannel[T]()
            proc producerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        discard chan.send(i)
                    else:
                        discard chan.send("data=" & $i)
                chan.close()

            proc consumerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        check chan.recv().get() == i
                    else:
                        check chan.recv().get() == ("data=" & $i)
                check chan.recv().isNone()
            let producerCoro = newCoroutine(proc() = producerFn[T](chan))
            let consumerCoro = newCoroutine(proc() = consumerFn[T](chan))
            registerExternCoro(getCurrentThreadDispatcher(), producerCoro)
            registerExternCoro(getCurrentThreadDispatcher(), consumerCoro)
        main[int]()
        main[string]()

    test "Coroutine Channel interleaved":
        proc main[T]() =
            var chan = newGoChannel[T]()
            proc producerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        discard chan.send(i)
                    else:
                        discard chan.send("data=" & $i)
                chan.close()

            proc consumerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        check chan.recv().get() == i
                    else:
                        check chan.recv().get() == ("data=" & $i)
                check chan.recv().isNone()
            let producerCoro = newCoroutine(proc() = producerFn[T](chan))
            let consumerCoro = newCoroutine(proc() = consumerFn[T](chan))
            registerExternCoro(getCurrentThreadDispatcher(), consumerCoro)
            registerExternCoro(getCurrentThreadDispatcher(), producerCoro)
        main[int]()
        main[string]()


    test "Thread channel fill first":
        proc main[T]() =
            var chan = newGoChannel[T]()
            proc producerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        discard chan.send(i)
                    else:
                        discard chan.send("data=" & $i)
                chan.close()

            proc consumerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        check chan.recv().get() == i
                    else:
                        check chan.recv().get() == ("data=" & $i)
                check chan.recv().isNone()
            var producerThread: Thread[GoChan[T]]
            var consumerThread: Thread[GoChan[T]]
            createThread(producerThread, producerFn[T], chan)
            sleep(100)
            createThread(consumerThread, consumerFn[T], chan)
            joinThreads(producerThread, consumerThread)
        main[int]()
        main[string]()


    test "Thread channel interleaved":
        proc main[T]() =
            var chan = newGoChannel[T]()
            proc producerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        discard chan.send(i)
                    else:
                        discard chan.send("data=" & $i)
                chan.close()

            proc consumerFn[T](chan: GoChan[T]) {.thread.} =
                for i in 0..3:
                    when T is int:
                        check chan.recv().get() == i
                    else:
                        check chan.recv().get() == ("data=" & $i)
                check chan.recv().isNone()
            var producerThread: Thread[GoChan[T]]
            var consumerThread: Thread[GoChan[T]]
            createThread(consumerThread, consumerFn[T], chan)
            sleep(100)
            createThread(producerThread, producerFn[T], chan)
            joinThreads(producerThread, consumerThread)
        main[int]()
        main[string]()
