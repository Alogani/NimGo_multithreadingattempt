
import ./[dispatcher, coroutines]

proc test() =
    echo "In"
    suspendUntilRead(AsyncFd(0))
    echo "Read done"

var coro = Coroutine.new(test)
coro.resume()
echo "back to main"
runEventLoop()
echo "event loop over"