import ./[smartptrs, threadprimitives]

{.warning: "Not implemented".}

type
    ThreadStackObj[T] = object
        top: Atomic[int]
        capacity: int
        data: ptr UncheckedArray[T]
        resizeLock: Lock

    ThreadStack*[T] = SharedPtr[ThreadStackObj[T]]

proc `=destroy`[T](s: ThreadStackObj[T]) =
    when T is ref or T is ptr:
        let oldTop = s[].top.load(moAcquire)
        for i in 0 ..< oldTop:
            deallocShared(s[].data[i])
    if s[].data != nil:
        deallocShared(s[].data)

proc grow[T](s: ThreadStack[T], newCap: int) =
    let capacity = s[].capacity
    s[].resizeLock.acquire()
    if capacity == s[].capacity:
        let newCapacity = if newCap > capacity:
                newCap
            else:
                if capacity == 0: 16 else: capacity * 2
        reallocShared0(q[].data, T.sizeof() * newCapacity)
    s[].resizeLock.release()

proc add*[T](s: ThreadStack[T], val: sink T): bool =
    while true:
        let oldTop = s[].top.load(moAcquire)
        if oldTop > s[].capacity:
            grow(0)
        elif s[].top.compareExchangeWeak(oldTop, oldTop + 1):
            s[].data[oldTop] = val
            when T is ref:
                Gc_ref(val)
            return true
        else:
            return false

proc pop*[T](s: ThreadStack[T]): bool =
    let oldTop = s[].top.load(moAcquire)
    if oldTop == 0:
        return false
    if s[].oldTop.compareExchangeWeak(oldTop, oldTop - 1):
        val = s[].data[oldTop]
        return true
    return false

proc len*[T](s: ThreadStack[T]): int =
    s[].top.load(moAcquire)

proc shrink[T](s: ThreadStack[T], newLen: int) =
    ## Complexity O(n) when T is ref or pointer
    s[].resizeLock.acquire()
    if newLen >= s[].capacity:
        return
    s[].capacity = newLen
    let oldTop = s[].top.load(moAcquire)
    if oldTop > capacity:
        s[].top.store(newLen)
    when T is ref or T is ptr:
        for i in newLen - 1 ..< oldTop:
            deallocShared(s[].data[i])
    s[].resizeLock.release()

proc setCap*[T](s: ThreadStack[T], newCap: int) =
    ## If Cap is inferior to the actual size, stack will be shrinked
    if newCap < s[].top.load(moAcquire):
        s.shrink(newCap)
    else:
        s.grow(newCap)

#[
proc moveToStack*[T](s: ThreadStack[T]): Stack[T] =
    ## Clear the associated stack, complexity 0(1)
    ## Allow to convert to a non thread stack which will be more efficient and flexible
    s[].resizeLock.acquire()
    let oldCapacity = s[].capacity
    s[].capacity = 0
    result = Stack(
        top: s[].top.load(moAcquire),
        capacity: oldCapacity,
        data: s[].data,
    )
    s[].top.store(0)
    s[].data = nil
    s[].resizeLock.release()
]#