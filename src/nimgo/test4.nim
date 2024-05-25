import std/macros

macro dumpT(body: typed): untyped =
    echo body.treeRepr()


proc main() =
    var a, b, c: int
    c = 43
    dumpT():
        echo c
        proc closure() =
            echo c


main()

