
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
    
    proc willWrite() =
        echo "Will write"
        writeTest(stdoutAsync)
        echo "Now suspend"
        suspend()
        echo "Reumed"
    
    goAsync willWrite()

main()


echo "Run the ev loop"
when NimGoNoStart:
    runEventLoop()