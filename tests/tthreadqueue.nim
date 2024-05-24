import nimgo/private/threadqueue
import os

import std/unittest

test "Threadqueue int":
    let q = newThreadQueue[int]()
    q.addLast(1)
    check q.popFirst().get() == 1

test "Threadqueue string":
    let q = newThreadQueue[string]()
    q.addLast("Hello")
    check q.popFirst().get() == "Hello"

template consumerProducerCode(T: typedesc) {.dirty.} =
    let queue = newThreadQueue[T]()

    proc producerFn() {.thread.} =
        for i in 0..3:
            when T is int:
                queue.addLast(i)
            else:
                queue.addLast("data=" & $i)

    proc consumerFn() {.thread.} =
        for i in 0..3:
            when T is int:
                check queue.popFirst().get() == i
            else:
                check queue.popFirst().get() == ("data=" & $i)
        check queue.popFirst().isNone()

test "Thread queue fill first":
    ## Interleaved won't work, because threadQueue is non blocking
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