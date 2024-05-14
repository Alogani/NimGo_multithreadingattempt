type
    CoroutineBase = object of RootObj
        entryFn: pointer
        returnedVal: pointer
        exception: ref Exception

    Coroutine[T] = ref object of CoroutineBase
        returnedValTyped: int

var a = Coroutine[int]()
a.returnedValTyped = 56
var b = cast[CoroutineBase](a)
var c = cast[Coroutine[int]](addr b)
echo cast[ptr int](c.returnedValTyped)[]