## Stackful asymmetric coroutines implementation, inspired freely from some language and relying on minicoro c library.
## Lighweight and efficient thanks to direct asm code and optional support for virtual memory.
## No push and pop implementation are provided, because they can't be implemented with type safety, but because closure are supported, using any shared object (like seq or channel) is supported

#[ ********* minicoroutines.h v0.2.0 wrapper ********* ]#
# Choice has been made to rely on minicoroutines for numerous reasons (efficient, single file, clear API, cross platform, virtual memory, etc.)
# Inspired freely from https://git.envs.net/iacore/minicoro-nim

var IncludeBuilder {.compileTime.} = "/*INCLUDESECTION*/" # Ok, that's an awful hack. Using passC could be another solution

when not defined(gcArc) and not defined(gcOrc):
    {.warning: "coroutines is not tested without --mm:orc or --mm:arc".}

when defined(coroUseVMem):
    IncludeBuilder &= "\n#define MCO_USE_VMEM_ALLOCATOR"
    const DefaultStackSize = 2040 * 1024 ## Recommanded by MCO
else:
    const DefaultStackSize = 56 * 1024 ## Recommanded by MCO

when defined(debug):
    IncludeBuilder &= "\n#define MCO_DEBUG"
else:
    IncludeBuilder &= "\n#define MCO_NO_DEBUG"

static:
    IncludeBuilder &= """
        #define MCO_MIN_STACK_SIZE 4096 // We will provide it explicitly
        #define MCO_DEFAULT_STORAGE_SIZE 0 // We won't use premade push and pop
        #define MINICORO_IMPL // Otherwise minicor.h symbols will be private
        #include "./private/minicoro.h"
        """
{.emit: IncludeBuilder.}

type
    McoCoroDescriptor {.importc: "mco_desc".} = object
        ## Contains various propery used to init a coroutine
        user_data: pointer

    McoReturnCode {.pure, importc: "mco_result".} = enum
        Success = 0,
        GenericError,
        InvalidPointer,
        InvalidCoroutine,
        NotSuspended,
        NotRunning,
        Makecontext_Error,
        Switchcontext_Error,
        NotEnoughSpace,
        OutOfMemory,
        InvalidArguments,
        InvalidOperation,
        StackOverflow,

    CoroutineError* = object of OSError

    McoCoroState {.importc: "mco_state".} = enum
        # The original name were renamed for clarity
        McoCsFinished = 0, ## /* The coroutine has finished normally or was uninitialized before finishing. */
        McoCsParenting, ## /* The coroutine is active but not running (that is, it has resumed another coroutine). */
        McoCsRunning, ## /* The coroutine is active and running. */
        McoCsSuspended ## /* The coroutine is suspended (in a call to yield, or it has not started running yet). */

    McoCoroutine {.importc: "mco_coro".} = object

    cstring_const* {.importc:"const char*".} = cstring

proc initMcoDescriptor(entryFn: proc (coro: ptr McoCoroutine) {.cdecl.}, stackSize: uint): McoCoroDescriptor {.importc: "mco_desc_init".}
proc uninitMcoCoroutine(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_uninit".}
proc createMcoCoroutine(outCoro: ptr ptr McoCoroutine, descriptor: ptr McoCoroDescriptor): McoReturnCode {.importc: "mco_create".}
proc destroyMco(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_destroy".}
proc resume(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_resume".}
proc suspend(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_yield".}
proc getState(coro: ptr McoCoroutine): McoCoroState {.importc: "mco_status".}
proc getUserData(coro: ptr McoCoroutine): pointer {.importc: "mco_get_user_data".}
proc getActiveMco(): ptr McoCoroutine {.importc: "mco_running".}
proc prettyError(returnCode: McoReturnCode): cstring_const {.importc: "mco_result_description".}

proc checkMcoReturnCode(returnCode: McoReturnCode) =
    if returnCode != Success:
        raise newException(CoroutineError, $returnCode.prettyError())


#[ ********* API ********* ]#

type
    CoroState* = enum
        CsRunning ## Is the current main coroutine
        CsParenting ## The coroutine is active but not running (that is, it has resumed another coroutine).
        CsSuspended
        CsFinished
        CsDead ## Finished with an error
    
    EntryFn[T] = proc(): T
        ## Supports at least closure and nimcall calling convention

    CoroutineBase = ref object of RootRef
        # During execution, we don't know the real type
        mcoCoroutine: ptr McoCoroutine
        exception: ref Exception

    Coroutine*[T] = ref object of CoroutineBase
        # To ensure type and GC safety at the beginning and end of execution
        returnedVal: T
        entryFn: EntryFn[T]   

proc coroutineMain[T](mcoCoroutine: ptr McoCoroutine) {.cdecl.} =
    ## Start point of the coroutine.
    var coro = cast[Coroutine[T]](mcoCoroutine.getUserData())
    try:
        when T isnot void:
            coro.returnedVal = coro.entryFn()
        else:
            coro.entryFn()
    except:
        coro.exception = getCurrentException()


proc newImpl[T](OT: type Coroutine, entryFn: EntryFn[T], stacksize = DefaultStackSize): Coroutine[T] =
    result = Coroutine[T](entryFn: entryFn)
    var mcoCoroDescriptor = initMcoDescriptor(coroutineMain[T], stacksize.uint)
    mcoCoroDescriptor.user_data = cast[pointer](result)
    checkMcoReturnCode createMcoCoroutine(addr(result.mcoCoroutine), addr mcoCoroDescriptor)

proc new*[T](OT: type Coroutine, entryFn: EntryFn[T], stacksize = DefaultStackSize): Coroutine[T] =
    ## Always call `wait` to clear memory than was allocated
    newImpl(Coroutine[T], entryFn, stacksize)

proc new*(OT: type Coroutine, entryFn: EntryFn[void], stacksize = DefaultStackSize): Coroutine[void] =
    # Due to type pickiness, the compiler needs this
    newImpl(Coroutine[void], entryFn, stacksize)

proc destroy*(coro: CoroutineBase) =
    ## Allow to destroy an unfinished coroutine (finished coroutine autoclean themselves).
    ## Don't works on running coroutine
    if coro.mcoCoroutine != nil:
        checkMcoReturnCode uninitMcoCoroutine(coro.mcoCoroutine)
        checkMcoReturnCode destroyMco(coro.mcoCoroutine)
    coro.mcoCoroutine = nil

proc resume*(coro: CoroutineBase) =
    ## Will resume the coroutine where it stopped (or start it).
    ## Will do nothing if coroutine is finished
    if getState(coro.mcoCoroutine) == McoCsFinished:
        return
    let frame = getFrameState()
    checkMcoReturnCode resume(coro.mcoCoroutine)
    setFrameState(frame)

proc suspend*() =
    let frame = getFrameState()
    checkMcoReturnCode suspend(getActiveMco())
    setFrameState(frame)

proc getException*(coro: CoroutineBase): ref Exception =
    ## nil if state is different than CsDead
    coro.exception

proc getState*(coro: CoroutineBase): CoroState =
    case coro.mcoCoroutine.getState():
    of McoCsFinished:
        if coro.exception == nil:
            CsFinished
        else:
            CsDead
    of McoCsParenting:
        CsParenting
    of McoCsRunning:
        CsRunning
    of McoCsSuspended:
        CsSuspended

proc wait*[T](coro: Coroutine[T], reRaise = true): T =
    ## Also resume if not finished
    ## If reraise is set to false, use your own exception handling (like std/options)
    while coro.mcoCoroutine.getState() == McoCsSuspended:
        coro.resume()
    if coro.exception != nil and reRaise:
        raise coro.exception
    when T isnot void:
        return coro.returnedVal
