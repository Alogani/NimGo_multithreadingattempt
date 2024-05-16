
import ./public/eventloop {.all.}
import selectors
import ./coroutines 

registerHandle(MainEvDispatcher, 0, {Event.Read})

proc test() =
    echo "In"
    suspendUntilRead(AsyncFd(0))
    echo "Read done"

var coro = Coroutine.new(test)
coro.resume()
echo "back to main"
runEventLoop()
echo "event loop over"