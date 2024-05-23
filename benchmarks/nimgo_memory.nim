import nimgo/public/task
import nimgo/asyncio

const SpawnNumber = 1_000_000
#[
    Tested on commit number 37, with Fedora OS. Memory was mesured at `await readTest(stdinAsync)`
    This benchmark don't reflect real usage and shall be taken with a grain of salt.
    (it should be replaced by a better and more realistic example)

    # With SpawnNumber = 100_000
    ## -d:release -d:nimgonothread
    Res Memory: 4452M
    Virtual Memory: 5501M
    ## -d:corousevmem -d:release -d:nimgonothread
    Res Memory: 4646M
    Virtual Memory: 194G
    ## -d:release
    Res Memory: 921M #-> this result seems a bit strange, maybe the presence of thread mess it up
    Virtual Memory: 5510M

    # With SpawnNumber = 1000
    ## -d:release -d:nimgonothread
    Res Memory: 47K
    Virtual Memory: 60K

    # With SpawnNumber = 50
    ## -d:release -d:nimgonothread
    Res Memory: 4.2K
    Virtual Memory: 6.8K
    ## d:corousevmem -d:release -d:nimgonothread
    Res Memory: 2.3K
    Virtual Memory: 107M
    ## -d:release
    Res Memory: 2.4K
    Virtual Memory: 72M
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
        if i == SpawnNumber:
            goAsync readTest(stdinAsync)
        else:
            goAsync nested(i + 1)

    goAsync nested(0)
main()

when defined(NimGoNoThread):
    import ../src/nimgo/eventdispatcher
    runEventLoop()