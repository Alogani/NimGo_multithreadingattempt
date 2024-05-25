import nimgo/[eventdispatcher, coroutines]
import nimgo/public/gochannels
import os

import std/unittest

#[
    Almost working, following bug create a SIGSEV:
    We try to pass GoChan inside a closure (for example: producerFn).
    But this doesn't in reality copy the object. So the SharedPtr doesn't increment.
    Then because the closure is stored inside unmanaged memory, ARC thinks it's gone
    and will happily free the environment pointer, making our SharedPointer decrement (triggering destruction)
]#

template consumerProducerCode[T]() {.dirty.} =
    proc producerFn[T](chan: GoChan[T]) {.thread.} =
        var chan = chan
        for i in 0..3:
            when T is int:
                discard chan.send(i)
            else:
                discard chan.send("data=" & $i)
        chan.close()

    proc consumerFn[T](chan: GoChan[T]) {.thread.} =
        var chan = chan
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
            consumerProducerCode[T]()
            let producerCoro = Coroutine.new(proc() = producerFn[T](chan))
            let consumerCoro = Coroutine.new(proc() = consumerFn[T](chan))
            registerExternCoro(getCurrentThreadDispatcher(), producerCoro)
            registerExternCoro(getCurrentThreadDispatcher(), consumerCoro)
    suite "int": main(int)
    #suite "string": main(string)


test "Coroutine Channel interleaved":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode[T]()
            let producerCoro = Coroutine.new(proc() = producerFn[T](chan))
            let consumerCoro = Coroutine.new(proc() = consumerFn[T](chan))
            registerExternCoro(getCurrentThreadDispatcher(), producerCoro)
            registerExternCoro(getCurrentThreadDispatcher(), consumerCoro)
    suite "int": main(int)
    #suite "string": main(string)

#[
test "Thread channel fill first":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode[T]()
            var producerThread: Thread[GoChan[T]]
            var consumerThread: Thread[GoChan[T]]
            createThread(producerThread, producerFn[T], chan)
            sleep(100)
            createThread(consumerThread, consumerFn[T], chan)
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)


test "Thread channel interleaved":
    template main(T: typedesc) =
        block:
            var chan = newGoChannel[T]()
            consumerProducerCode[T]()
            var producerThread: Thread[GoChan[T]]
            var consumerThread: Thread[GoChan[T]]
            createThread(consumerThread, consumerFn[T], chan)
            sleep(100)
            createThread(producerThread, producerFn[T], chan)
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)
]#
when defined(NimGoNoStart):
    runEventLoop()