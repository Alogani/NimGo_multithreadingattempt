
import ./eventdispatcher {.all.}
import selectors
import ./coroutines
import ./asyncio

var afile: AsyncFile
discard openAsync(afile, FileHandle(0))

proc readTest() =
    var buf = newString(100)
    discard afile.readBuffer(addr(buf[0]), 100)
    echo "BUF=", buf

echo "Begin Read sync"
readTest()

echo "Begin Read async"
var coro = Coroutine.new(readTest)
coro.resume()

echo "Run the ev loop"
when NimGoNoThread:
    runEventLoop()