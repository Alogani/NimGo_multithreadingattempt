import nimgo/[coroutines, gochannels]
import os

import std/unittest

template consumerProducerCode() {.dirty.} =
    #var myChan = newGoChannel[string]()
    let (receiver, sender) = newGoChannel2[int]()

    proc producerFn() {.thread.} =
        for i in 0..3:
            discard sender.trySend(i)

    proc consumerFn() {.thread.} =
        for i in 0..3:
            check receiver.tryRecv().get() == i

test "Coroutine Channel fill first":
    consumerProducerCode()
    let producerCoro = Coroutine.new(producerFn)
    let consumerCoro = Coroutine.new(consumerFn)
    producerCoro.resume()
    consumerCoro.resume()
    check producerCoro.getState() == CsFinished
    check consumerCoro.getState() == CsFinished

test "Coroutine Channel interleaved":
    consumerProducerCode()
    let producerCoro = Coroutine.new(producerFn)
    let consumerCoro = Coroutine.new(consumerFn)
    consumerCoro.resume()
    producerCoro.resume()
    check producerCoro.getState() == CsFinished
    check consumerCoro.getState() == CsFinished

test "Thread channel fill first":
    consumerProducerCode()
    var producerThread: Thread[void]
    var consumerThread: Thread[void]
    createThread(producerThread, producerFn)
    sleep(100)
    createThread(consumerThread, consumerFn)
    joinThreads(producerThread, consumerThread)

test "Thread channel interleaved":
    consumerProducerCode()
    var producerThread: Thread[void]
    var consumerThread: Thread[void]
    createThread(consumerThread, consumerFn)
    sleep(100)
    createThread(producerThread, producerFn)
    joinThreads(producerThread, consumerThread)
