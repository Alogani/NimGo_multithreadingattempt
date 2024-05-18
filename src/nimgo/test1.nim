
import ./eventdispatcher {.all.}
import ./public/task
import ./asyncio

const SpawnNumber = 100_000
#[
    # -d:release
    Res Memory: 880M
    Virtual Memory: 5510M
    # -d:corousevmem -d:release
    Res Memory: 3344M
    Virtual Memory: 195G
]#

proc main() =
    var stdinAsync: AsyncFile
    discard openAsync(stdinAsync, FileHandle(0))

    proc readTest(afile: AsyncFile) =
        var buf = newString(100)
        echo "Please provide input"
        discard afile.readBuffer(addr(buf[0]), 100)
        echo "READ=", buf

    proc nested(i: int) =
        if i == 100_000:
            goAsync readTest(stdinAsync)
        else:
            goAsync nested(i + 1)

    goAsync nested(0)
main()

when defined(NimGoNoThread):
    runEventLoop()