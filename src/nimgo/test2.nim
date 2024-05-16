import ./coroutines

proc entry() =
    echo "IN"

var coro = Coroutine.new(entry)
coro.destroy()
coro.resume()