import nimgo/[coroutines, gochannels]
import os

import std/unittest

template consumerProducerCode(T: typedesc) {.dirty.} =
    #var myChan = newGoChannel[string]()
    let (receiver, sender) = newGoChannel2[T]()

    proc producerFn() {.thread.} =
        for i in 0..3:
            when T is int:
                discard sender.trySend(i)
            else:
                discard sender.trySend("data=" & $i)
        sender.close()

    proc consumerFn() {.thread.} =
        for i in 0..3:
            when T is int:
                check receiver.tryRecv().get() == i
            else:
                check receiver.tryRecv().get() == ("data=" & $i)
        check receiver.tryRecv().isNone()

test "Coroutine Channel fill first":
    template main(T: typedesc) =
        block:
            consumerProducerCode(T)
            let producerCoro = Coroutine.new(producerFn)
            let consumerCoro = Coroutine.new(consumerFn)
            producerCoro.resume()
            consumerCoro.resume()
            check producerCoro.getState() == CsFinished
            check consumerCoro.getState() == CsFinished
    suite "int": main(int)
    suite "string": main(string)

test "Coroutine Channel interleaved":
    template main(T: typedesc) =
        block:
            consumerProducerCode(T)
            let producerCoro = Coroutine.new(producerFn)
            let consumerCoro = Coroutine.new(consumerFn)
            consumerCoro.resume()
            producerCoro.resume()
            check producerCoro.getState() == CsFinished
            check consumerCoro.getState() == CsFinished
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
