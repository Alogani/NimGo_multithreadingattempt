import nimgo/[eventdispatcher, coroutines, gochannels]
import os

import std/unittest


import nimgo/private/smartptrs
template consumerProducerCode[T](chan: GoChan[T]) {.dirty.} =
    proc producerFn[T]() {.thread.} =
        for i in 0..3:
            when T is int:
                discard chan.send(i)
            else:
                discard chan.send("data=" & $i)
        chan.close()

    proc consumerFn[T]() {.thread.} =
        for i in 0..3:
            when T is int:
                check chan.recv().get() == i
            else:
                check chan.recv().get() == ("data=" & $i)
        check chan.recv().isNone()


test "Coroutine Channel fill first":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode(chan)
            let producerCoro = Coroutine.new(producerFn[T])
            let consumerCoro = Coroutine.new(consumerFn[T])
            registerCoro producerCoro
            registerCoro consumerCoro
    suite "int": main(int)
    suite "string": main(string)

test "Coroutine Channel interleaved":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode(chan)
            let producerCoro = Coroutine.new(producerFn[T])
            let consumerCoro = Coroutine.new(consumerFn[T])
            registerCoro producerCoro
            registerCoro consumerCoro
    suite "int": main(int)
    suite "string": main(string)

test "Thread channel fill first":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode(chan)
            var producerThread: Thread[void]
            var consumerThread: Thread[void]
            createThread(producerThread, producerFn[T])
            sleep(100)
            createThread(consumerThread, consumerFn[T])
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)


test "Thread channel interleaved":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode(chan)
            var producerThread: Thread[void]
            var consumerThread: Thread[void]
            createThread(consumerThread, consumerFn[T])
            sleep(100)
            createThread(producerThread, producerFn[T])
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)

when not defined(NimGoNoStart):
    runEventLoop()