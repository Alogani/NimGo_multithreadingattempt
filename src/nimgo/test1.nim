
import ./eventdispatcher {.all.}
import selectors
import ./coroutines

var afd = registerHandle(0, {Event.Read})

proc test() =
    echo "In"
    suspendUntilRead(afd)
    echo "Read done"

var coro = Coroutine.new(test)
coro.resume()
echo "back to main"
#runEventLoop()
echo "event loop over"
