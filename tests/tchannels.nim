import nimgo/[eventdispatcher, coroutines, gochannels]
import os

import std/unittest

template consumerProducerCode(T: typedesc) {.dirty.} =
    #var myChan = newGoChannel[string]()
    let chan = newGoChannel[T]()

    proc producerFn() {.thread.} =
        for i in 0..3:
            when T is int:
                discard chan.send(i)
            else:
                discard chan.send("data=" & $i)
        chan.close()

    proc consumerFn() {.thread.} =
        for i in 0..3:
            when T is int:
                check chan.recv().get() == i
            else:
                check chan.recv().get() == ("data=" & $i)
        check chan.recv().isNone()

test "Coroutine Channel fill first":
    template main(T: typedesc) =
        block:
            consumerProducerCode(T)
            let producerCoro = Coroutine.new(producerFn)
            let consumerCoro = Coroutine.new(consumerFn)
            registerCoro producerCoro
            registerCoro consumerCoro
    suite "int": main(int)
    suite "string": main(string)

test "Coroutine Channel interleaved":
    template main(T: typedesc) =
        block:
            consumerProducerCode(T)
            let producerCoro = Coroutine.new(producerFn)
            let consumerCoro = Coroutine.new(consumerFn)
            registerCoro producerCoro
            registerCoro consumerCoro
    suite "int": main(int)
    suite "string": main(string)

test "Thread channel fill first":
    template main(T: typedesc) =
        block:
            consumerProducerCode(T)
            var producerThread: Thread[void]
            var consumerThread: Thread[void]
            createThread(producerThread, producerFn)
            sleep(100)
            createThread(consumerThread, consumerFn)
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)

test "Thread channel interleaved":
    template main(T: typedesc) =
        block:
            consumerProducerCode(T)
            var producerThread: Thread[void]
            var consumerThread: Thread[void]
            createThread(consumerThread, consumerFn)
            sleep(100)
            createThread(producerThread, producerFn)
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)