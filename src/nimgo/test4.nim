import ./coroutines

proc main() =
    echo "in coro"
    let coro = getCurrentCoroutine()
    echo "resumed"
    suspend(coro)
    echo "resumed again"

let coro = Coroutine.new(main)
coro.resume()
echo "suspend 1"
coro.suspend()
echo "suspend 2"
coro.suspend()
coro.resume()