import nimgo/private/threadqueue

import std/unittest

test "Threadqueue int":
    let q = newThreadQueue[int]()
    q.pushLast(1)
    check q.popFirst().get() == 1

test "Threadqueue string":
    let q = newThreadQueue[string]()
    q.pushLast("Hello")
    check q.popFirst().get() == "Hello"