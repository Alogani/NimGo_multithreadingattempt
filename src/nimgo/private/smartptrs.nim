# Source: https://github.com/nim-lang/threading/blob/master/threading/smartptrs.nim
# With small tweaks
# This doesn't use isolates, so uniqueness is not guaranted by the compiler

import ./threadprimitives


template checkNotNil*(p: pointer) =
    when compileOption("boundChecks"):
        {.line.}:
            if p == nil:
                raise newException(ValueError, "Attempt to read from nil")

proc allocSharedAndSet*[T](val: sink T): ptr T {.nodestroy.} =
    ## More efficient than allocShared0
    result = cast[ptr T](allocShared(sizeof T))
    result[] = move(val)

type
    UniquePtr*[T] = object
        ## Non copyable pointer to a value of type `T` with exclusive ownership.
        val: ptr T

proc `=destroy`*[T](p: UniquePtr[T]) =
    if p.val != nil:
        `=destroy`(p.val[])
        deallocShared(p.val)
        addr(p.val)[] = nil

proc `=dup`*[T](src: UniquePtr[T]): UniquePtr[T] {.error.}
    ## The dup operation is disallowed for `UniquePtr`, it
    ## can only be moved.

proc `=copy`*[T](dest: var UniquePtr[T], src: UniquePtr[T]) {.error.}
    ## The copy operation is disallowed for `UniquePtr`, it
    ## can only be moved.

proc newUniquePtr*[T](val: sink T): UniquePtr[T] {.nodestroy.} =
    ## Returns a unique pointer. It is not initialized,
    ## so reading from it before writing to it is undefined behaviour!
    result.val = allocSharedAndSet[(T, Atomic[int])](
        (val, newAtomic(0))
    )

proc isNil*[T](p: UniquePtr[T]): bool {.inline.} =
    p.val == nil

proc `[]`*[T](p: UniquePtr[T]): var T {.inline.} =
    p.val[]

type
    SharedPtr*[T] = object
        ## Shared ownership reference counting pointer.
        ## By default is nil
        val: ptr tuple[value: T, counter: Atomic[int]]

proc decr[T](p: SharedPtr[T]) {.inline.} =
    {.cast(raises: []).}:
        if p.val != nil:
            echo "DESTRUCTION", T
            # this `fetchSub` returns current val then subs
            # so count == 0 means we're the last
            if p.val.counter.fetchSub(1, moAcquireRelease) == 0:
                `=destroy`(p.val.value)
                deallocShared(p.val)
                addr(p.val)[] = nil

proc RefInc*[T](p: SharedPtr[T]) =
    p.val.counter.atomicInc()

proc RefDec*[T](p: SharedPtr[T]) =
    p.decr()

proc `=destroy`*[T](p: SharedPtr[T]) {.nodestroy.} =
    p.decr()

proc `=dup`*[T](src: SharedPtr[T]): SharedPtr[T] =
    if src.val != nil:
        discard fetchAdd(src.val.counter, 1, moRelaxed)
    result.val = src.val

proc `=copy`*[T](dest: var SharedPtr[T], src: SharedPtr[T]) =
    if src.val != nil:
        discard fetchAdd(src.val.counter, 1, moRelaxed)
    if dest.val != nil:
        `=destroy`(dest)
    dest.val = src.val

proc newSharedPtr*[T](val: sink T): SharedPtr[T] {.nodestroy.} =
    ## Returns a zero initialized shared pointer
    echo "CREATION", T
    result.val = allocSharedAndSet[(T, Atomic[int])](
        (val, newAtomic(0))
    )

proc isNil*[T](p: SharedPtr[T]): bool {.inline.} =
    p.val == nil

proc `[]`*[T](p: SharedPtr[T]): var T {.inline.} =
    p.val.value

proc `[]=`*[T](p: SharedPtr[T], val: sink T) {.inline.} =
    p.val.value = val

proc getUnsafePtr*[T](p: SharedPtr[T]): pointer =
    ## Will not decrement the ref count
    ## But giving it back with toSharedPtr will increment the rec count
    cast[pointer](p.val)

proc toSharedPtr*[T](t: typedesc[T], p: pointer): SharedPtr[T] =
    ## Will increment the reference count. Borrow/restitute is safer
    var pVal = cast[ptr (T, Atomic[int])](p)
    result = SharedPtr[T](val: pVal)
    if p != nil:
        result.val[].counter.atomicInc()

proc borrowVal*[T](p: SharedPtr[T]): ptr T =
    ## Must be restitute, otherwise leak
    if p.val != nil:
        discard fetchAdd(p.val.counter, 1)
        result = addr p.val[].value

proc restituteVal*[T](p: SharedPtr[T], val: ptr T) =
    if val != nil:
        p.decr()

type
    SharedPtrNoCopy*[T] = object
        p: SharedPtr[T]

proc disableCopy*[T](p: SharedPtr[T]): SharedPtrNoCopy[T] =
    SharedPtrNoCopy[T](p: p)

proc `=dup`*[T](src: SharedPtrNoCopy[T]): SharedPtrNoCopy[T] {.error.}

proc `=copy`*[T](dest: var SharedPtrNoCopy[T], src: SharedPtrNoCopy[T]) {.error.}

proc isNil*[T](p: SharedPtrNoCopy[T]): bool {.inline.} =
    isNil(p.p)

proc `[]`*[T](p: SharedPtrNoCopy[T]): var T {.inline.} =
    `[]`(p.p)

proc `[]=`*[T](p: SharedPtrNoCopy[T], val: sink T) {.inline.} =
    `[]=`(p.p)

template checkNotNil*[T](p: SharedPtr[T]) =
    when compileOption("boundChecks"):
        {.line.}:
            if p.isNil():
                raise newException(ValueError, "Attempt to read from nil")
