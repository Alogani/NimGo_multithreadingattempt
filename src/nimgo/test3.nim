import aloganimisc/fasttest

import std/options

import ./coroutines {.all.}

type MyObj = object
    val: array[1024, int]

var MyVal = MyObj()


proc doReturnOption(): Option[MyObj] =
    some(MyVal)

proc doReturn(): (MyObj, bool) =
    (MyVal, true)

var Additionnier: int

runBench("doReturnOption"):
    for i in 0..10_000:
        Additionnier += doReturnOption().get().val.len()

runBench("doReturn"):
    for i in 0..10_000:
        let data = move doReturn()
        if data[1]:
            Additionnier += doReturn()[0].val.len()

echo Additionnier