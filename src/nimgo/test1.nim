
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
    
    proc readTest(afile: AsyncFile) =
        var buf = newString(100)
        discard afile.readBuffer(addr(buf[0]), 100)
        echo "READ=", buf

    proc nested(i: int) =
        if i == 10000:
            goAsync readTest(stdinAsync)
        else:
            goAsync nested(i + 1)

    echo "Begin Read sync"
    #readTest()

    echo "Begin Write async"
    goAsync nested(0)

main()


echo "Run the ev loop"
when NimGoNoStart:
    runEventLoop()