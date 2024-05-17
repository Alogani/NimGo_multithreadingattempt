
import ./eventdispatcher {.all.}
import selectors
import ./coroutines
import ./public/io

proc asyncCtxt() =
    var afile: AsyncFile
    discard openAsync(afile, FileHandle(0))

    var buf = newString(100)
    discard afile.readBuffer(addr(buf[0]), 100)
    echo "BUF=", buf

var coro = Coroutine.new(asyncCtxt)
coro.resume()
runEventLoop()