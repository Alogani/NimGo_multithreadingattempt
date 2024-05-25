import ./private/safecontainer

var C = 54

proc main() =
    var a: int = 43
    proc closure(): int =
        echo a, C
        return a

    var contained = closure.toContainer()
    echo "A=", contained.toVal()()

main()