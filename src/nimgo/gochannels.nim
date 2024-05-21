## Efficient channels, that works both between threads and coroutines
## Blocking behaviour inside a couroutine suspend, otherwise main thread is blocked

import ./coroutines
import ./private/[atomics, smartptrs, threadqueue]

export options

type
    GoChanState = enum
        IsEmpty
        HasData
        ReceiverSuspended # Coroutine
        ReceiverWaiting # Thread

    GoChanObj[T] = object
        data: ThreadQueue[T]
        suspendedCoro: Coroutine
        suspendedThreadId: int
        state: Atomic[GoChanState]
        closed: bool

    GoChanReceiver*[T] = distinct SharedPtrNoCopy[GoChanObj[T]]
        ## There can only be one receiver reference.
        ## It need to be moved to be used

    GoChanSender*[T] = distinct SharedPtrNoCopy[GoChanObj[T]]
        ## There can only be one receiver reference.
        ## It need to be moved to be used
    
    GoChan*[T] = object
        receiver: SharedPtr[GoChanObj[T]]
        sender: SharedPtr[GoChanObj[T]]

proc `[]`[T](chan: GoChanReceiver[T] or GoChanSender[T]): var GoChanObj[T] =
    SharedPtrNoCopy[GoChanObj[T]](chan)[]

proc `isNil`[T](chan: GoChanReceiver[T] or GoChanSender[T]): bool =
    SharedPtrNoCopy[GoChanObj[T]](chan).isNil()

proc newGoChannel2*[T](maxItems = 0): tuple[receiver: GoChanReceiver[T], sender: GoChanSender[T]] =
    let chan = newSharedPtr(GoChanObj[T](
        data: newThreadQueue[T](),
        suspendedThreadId: -1,
    ))
    result = (
        receiver: GoChanReceiver[T](chan.disableCopy()),
        sender: GoChanSender[T](chan.disableCopy())
    )

proc newGoChannel*[T](maxItems = 0): GoChan[T] =
    let chan = newSharedPtr(GoChanObj[T](
        data: newThreadQueue[T](),
        suspendedThr)eadId: -1,
    )
    result = GoChan[T](
        receiver: chan,
        sender: chan
    )

proc getReceiver*[T](chan: var GoChan[T]): GoChanReceiver[T] =
    ## This can be called only once
    when defined(debug):
        if chan.receiver.isNil():
            raise newException(ValueError, "Can't get receiver more than once")
    return GoChanReceiver[T](move(chan.receiver).disableCopy())

proc getSender*[T](chan: var GoChan[T]): GoChanSender[T] =
    ## This can be called only once
    when defined(debug):
        if chan.sender.isNil():
            raise newException(ValueError, "Can't get sender more than once")
    return GoChanSender[T](move(chan.sender).disableCopy())

proc close*[T](chan: GoChanReceiver[T] or GoChanSender[T]) =
    chan[].closed = true
    if not chan[].suspendedCoro.isNil():
        chan[].suspendedCoro.resume()

proc trySend*[T](chan: GoChanSender[T], data: sink T): bool =
    ## Return false if channel closed
    if chan[].closed:
        return false
    chan[].data.pushLast data
    let actualState = chan[].state.exchange(HasData, moAcquireRelease)
    case actualState:
    of ReceiverSuspended:
        while chan[].suspendedCoro.isNil():
            discard # Spinlock
        chan[].suspendedCoro.resume()
    of ReceiverWaiting:
        discard
    else:
        discard
    return true

proc tryRecv*[T](chan: GoChanReceiver[T]): Option[T] =
    ## Return false if channel closed
    var isEmptyVal = IsEmpty
    if chan[].state.load() == isEmptyVal:
        if chan[].closed:
            return none(T)
        let currentCoro = getCurrentCoroutine() # Fast but not free
        if not currentCoro.isNil():
            if chan[].state.compareExchange(isEmptyVal, ReceiverSuspended):
                chan[].suspendedCoro = currentCoro
                suspend(currentCoro)
        else:
            if chan[].state.compareExchange(isEmptyVal, ReceiverWaiting):
                discard
    result = chan[].data.popFirst()
    if chan[].data.empty():
        chan[].state.store(IsEmpty)
        if not chan[].data.empty():
            chan[].state.store(HasData)

iterator items*[T](chan: GoChanReceiver[T]): T {.inline.} =
    while true:
        let data = chan.tryRecv()
        if data.isNone():
            break
        yield data.unsafeGet()
