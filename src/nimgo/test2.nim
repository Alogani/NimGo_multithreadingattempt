import std/macros
import std/threading

macro dumpT(fn: typed) =
    echo fn.treeRepr()

macro dumpU(fn: untyped) =
    echo fn.treeRepr()

proc read(a, b, c: int): int =
    discard

dumpT read

dumpU read