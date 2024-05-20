import ./private/sharedptrs
import std/macros

import aloganimisc/fasttest

type
    Parent = ptr object of RootObj
        valUntyped: int
    
    Child[T] = ptr object of Parent
        valTyped: T
        val2: int
        val3: int

proc echoParent(p: Parent) =
    echo p[].valUntyped


var c: Child[float]
c = cast[Child[float]](alloc0(sizeof c[]))
echo sizeof c[]

echoParent(c)
echoParent(cast[Parent](c))

type MyRef = ref object
    val: int

var a = MyRef()
echo a[].val