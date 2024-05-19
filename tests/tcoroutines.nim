import nimgo/coroutines

import std/unittest

test "Coroutine":
    let coro = Coroutine.new(proc(): string = "Hello")
    #check coro.getState() == CsSuspended
    echo "here"
    #coro.resume()
    check coro.getReturnValue() == "Hello"
    #check coro.getState() == CsFinished