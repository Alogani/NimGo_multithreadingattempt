## Attempt to make coroutines lib using uevent and fibers. But not as efficient and flexible as minicoro.h (and still impure, so...)
## Low level coroutine facility inspired from std/coro and https://github.com/zevv/nimcoro

import std/posix

type CoroContext = Ucontext

type
    CoroStack {.pure.} = object
        top: pointer    # Top of the stack. Pointer used for deallocating stack if we own it.
        bottom: pointer # Very bottom of the stack, acts as unique stack identifier.
        size: int
    
    CoroState* = enum
        CsActive ## Is the current main coroutine
        CsSuspended
        CsFinished
        CsDead ## Finished with an error
    
    CoroutineBase = ref object of RootRef
        ## Untyped base class (to circumvet the impossibility to have generic global var)
        state: CoroState
        entryFn: pointer #-> unclear how the GC handles this correctly
        returnedVal: pointer #-> unclear how the GC handles this correctly
        execContext: CoroContext
        calleeContext: CoroContext
        stack: CoroStack
        exception: ref Exception

    Coroutine*[T] = ref object of CoroutineBase

    EntryFn[T] = proc(): T {.nimcall.}

const DefaultStackSize = 32 * 1024
var CurrentCoroutine {.threadvar.}: CoroutineBase

proc getState*(coro: CoroutineBase): CoroState =
    return coro.state

proc suspend*() =
    ## Suspend current coroutine.
    ## Will return to caller
    discard swapcontext(CurrentCoroutine.execContext, CurrentCoroutine.calleeContext)

proc coroutineMain[T]() {.noconv.} =
    ## Start point of the coroutine.
    ## Can access itself with CurrentCoro global
    try:
        let entryFn = cast[EntryFn[T]](CurrentCoroutine.entryFn)
        when T isnot void:
            let returnedVal = entryFn()
            CurrentCoroutine.returnedVal = cast[pointer](addr returnedVal)
            when T is ref:
                GC_ref(returnedVal)
        else:
            entryFn()
        CurrentCoroutine.state = CsFinished
    except:
        CurrentCoroutine.state = CsDead
        CurrentCoroutine.exception = getCurrentException()
    finally:
        suspend()

proc free(coroutine: CoroutineBase) =
    dealloc(coroutine.stack.top)

proc newImpl[T](OT: type Coroutine, entryFn: EntryFn[T], stacksize: int): Coroutine[T] =
    result = Coroutine[T](
        state: CsSuspended,
        entryFn: cast[pointer](entryFn)
    )
    result.stack.top = alloc(stacksize)
    result.stack.size = stacksize
    result.stack.bottom = cast[pointer](cast[int](result.stack.top) + stacksize)
    discard getcontext(result.execContext)
    result.execContext.uc_stack.ss_sp = result.stack.top
    result.execContext.uc_stack.ss_size = stacksize
    makecontext(result.execContext, coroutineMain[T], 0)

proc new*[T](OT: type Coroutine, entryFn: EntryFn[T], stacksize = DefaultStackSize): Coroutine[T] =
    ## Always call `wait` to clear memory than was allocated
    newImpl(Coroutine[T], entryFn, stacksize)

proc new*(OT: type Coroutine, entryFn: EntryFn[void], stacksize = DefaultStackSize): Coroutine[void] =
    # Due to type pickiness, the compiler needs this
    newImpl(Coroutine[void], entryFn, stacksize)

proc resume*(coroutine: CoroutineBase) =
    ## Will resume the coroutine where it stopped (or start it)
    if coroutine.state != CsSuspended:
        return
    coroutine.state = CsActive
    let frame = getFrameState()
    let lastCoroutine = CurrentCoroutine
    CurrentCoroutine = coroutine
    discard swapcontext(coroutine.calleeContext, coroutine.execContext)
    if CurrentCoroutine.state != CsActive:
        CurrentCoroutine.free()
    else:
        CurrentCoroutine.state = CsSuspended
    CurrentCoroutine = lastCoroutine
    setFrameState(frame)

proc wait*[T](coro: Coroutine[T]): T =
    ## Also resume if not finished
    ## Current implementation makes return value be copied.
    ## Consider using a ref object for large value
    ## Calling it multiple times can lead to undefined behaviour
    while coro.state == CsSuspended:
        coro.resume()
    if coro.exception != nil:
        raise coro.exception
    when T isnot void:
        result = cast[ptr T](coro.returnedVal)[]
        when T is ref:
            GC_unref(result)

proc initializeMainCoroutine() =
    ## Executed on import
    CurrentCoroutine = CoroutineBase()

initializeMainCoroutine()