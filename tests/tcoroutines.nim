import nimgo/coroutines

import std/unittest

test "Coroutine":
    let coro = Coroutine.new(proc() = echo "Hello")
    check coro.getState() == CsSuspended
    coro.resume()
    check coro.getState() == CsFinished
