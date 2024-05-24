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

template consumerProducerCode[T]() {.dirty.} =
    proc producerFn[T](queue: ThreadQueue[T]) {.thread.} =
        for i in 0..3:
            when T is int:
                queue.addLast(i)
            else:
                queue.addLast("data=" & $i)

    proc consumerFn[T](queue: ThreadQueue[T]) {.thread.} =
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
            let queue = newThreadQueue[T]()
            consumerProducerCode[T]()
            var producerThread: Thread[ThreadQueue[T]]
            var consumerThread: Thread[ThreadQueue[T]]
            createThread(producerThread, producerFn[T], queue)
            sleep(100)
            createThread(consumerThread, consumerFn[T], queue)
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)

test "Thread queue with closure":
    ## Interleaved won't work, because threadQueue is non blocking
    template main(T: typedesc) =
        block:
            let queue = newThreadQueue[T]()
            consumerProducerCode[T]()
            var producerThread: Thread[void]
            var consumerThread: Thread[void]
            createThread(producerThread, proc() {.thread.} = producerFn(queue))
            sleep(100)
            createThread(consumerThread, proc() {.thread.} = consumerFn(queue))
            joinThreads(producerThread, consumerThread)
    suite "int": main(int)
    suite "string": main(string)