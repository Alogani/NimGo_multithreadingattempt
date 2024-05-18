
import ./eventdispatcher {.all.}
import selectors
import ./public/task
import ./coroutines
import ./asyncio

proc main() =
    var stdinAsync: AsyncFile
    discard openAsync(stdinAsync, FileHandle(0))
    var stdoutAsync: AsyncFile
    discard openAsync(stdoutAsync, FileHandle(1), fmWrite)

    proc writeTest(afile: AsyncFile) =
        var buf = "TO THE OUTPUT"
        discard afile.writeBuffer(addr(buf[0]), buf.len())
        echo "BUF=", buf
    
    proc readTest(afile: AsyncFile) =
        #var buf = newString(100)
        #discard afile.readBuffer(addr(buf[0]), 100)
        goAsync writeTest(stdoutAsync)

    proc nested() =
        goAsync readTest(stdinAsync)

    echo "Begin Read sync"
    #readTest()

    echo "Begin Write async"
    goAsync nested()

main()

echo "Run the ev loop"
when NimGoNoThread:
    runEventLoop()