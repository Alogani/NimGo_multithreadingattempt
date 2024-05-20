# Source: https://github.com/nim-lang/threading/blob/master/threading/smartptrs.nim
# With small tweaks

import ./atomics

type
    SharedPtr*[T] = object
        ## Shared ownership reference counting pointer.
        val: ptr tuple[value: T, counter: AtomicInt[int]]

proc decr[T](p: SharedPtr[T]) {.inline.} =
    if p.val != nil:
        # this `fetchSub` returns current val then subs
        # so count == 0 means we're the last
        if p.val.counter.fetchSub(1) == 0:
            `=destroy`(p.val.value)
            deallocShared(p.val)

when defined(nimAllowNonVarDestructor):
    proc `=destroy`*[T](p: SharedPtr[T]) =
        p.decr()
else:
    proc `=destroy`*[T](p: var SharedPtr[T]) =
        p.decr()

proc `=dup`*[T](src: SharedPtr[T]): SharedPtr[T] =
    if src.val != nil:
        discard fetchAdd(src.val.counter, 1)
    result.val = src.val

proc `=copy`*[T](dest: var SharedPtr[T], src: SharedPtr[T]) =
    if src.val != nil:
        discard fetchAdd(src.val.counter, 1)
    `=destroy`(dest)
    dest.val = src.val

proc newSharedPtr0*[T](t: typedesc[T]): SharedPtr[T] =
    ## Returns a zero initialized shared pointer
    result.val = cast[typeof(result.val)](allocShared0(sizeof(result.val[])))
    result.val[].counter.set(0)

proc isNil*[T](p: SharedPtr[T]): bool {.inline.} =
  p.val == nil

proc `[]`*[T](p: SharedPtr[T]): var T {.inline.} =
  p.val.value

proc unsafeGetPtr*[T](p: SharedPtr[T]): pointer =
    cast[pointer](p.val)

proc toSharedPtr*[T](t: typedesc[T], p: pointer): SharedPtr[T] =
    ## Will increment the reference count. Borrow/restitute is safer
    var pVal = cast[ptr (T, AtomicInt[int])](p)
    result = SharedPtr[T](val: pVal)
    if p != nil:
        result.val[].counter.inc(1)

proc borrowVal*[T](p: SharedPtr[T]): ptr T =
    ## Must be restitute, otherwise leak
    if p.val != nil:
        discard fetchAdd(p.val.counter, 1)
        result = addr p.val[].value

proc restituteVal*[T](p: SharedPtr[T], val: ptr T) =
    if val != nil:
        p.decr()