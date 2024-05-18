import std/asyncdispatch
import std/asyncfile

const SpawnNumber = 40_000
#[
    Tested on Fedora OS
    This benchmark don't reflect real usage and shall be taken with a grain of salt.
    (it should be replaced by a better and more realistic example)

    # With SpawnNumber = 100_000
    ## -d:release
    core_dumped (unable to work around 50_000)

     # With SpawnNumber = 40_000
    ## -d:release
    Res Memory: 18K
    Virtual Memory: 21K

    # With SpawnNumber = 50
    ## -d:release
    Res Memory: 1.6K
    Virtual Memory: 4.0K
]#

proc main() =
    var stdinAsync = newAsyncFile(AsyncFD(0))

    proc readTest(afile: AsyncFile) {.async.} =
        echo "Please provide input"
        echo "READ=", await afile.read(10)

    proc nested(i: int) {.async.} =
        if i == SpawnNumber:
            await nested(i + 1)
        else:
            await readTest(stdinAsync)

    waitFor nested(0)

main()