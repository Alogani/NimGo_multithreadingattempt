## Efficient channels, that works both between threads and coroutines
## Blocking behaviour inside a couroutine suspend, otherwise main thread is blocked

import ./[gosemaphores]
import ../private/[smartptrs, threadprimitives, threadqueue]

export options

type
    GoChanObj[T] = object
        queue: ThreadQueue[T]
        semaphore: GoSemaphore
        closed: bool

    GoChan*[T] = SharedPtr[GoChanObj[T]]
        ## Channel object that can be exchanged both between threads and coroutines
        ## Coroutines can only be suspended if they belong to a dispatcher/event loop. Otherwise the whole thread will block

proc newGoChannel*[T](maxItems = 0): GoChan[T] =
    return newSharedPtr(GoChanObj[T](
        queue: newThreadQueue[T](),
        semaphore: newGoSemaphore(),
        closed: false,
    ))

proc close*[T](chan: GoChan[T]) =
    chan[].closed = true
    chan[].semaphore.signalUpTo(1)

proc closed*[T](chan: GoChan[T]) =
    chan[].closed

proc send*[T](chan: GoChan[T], data: sink T): bool =
    ## Return false if channel closed
    if chan[].closed:
        return false
    chan[].queue.addLast data
    chan[].semaphore.signal()

proc tryRecv*[T](chan: GoChan[T]): Option[T] =
    ## Non blocking
    ## Return false if channel is closed or data is not available
    if not chan[].semaphore.tryWait():
        return none(T)
    return chan[].queue.popFirst()

proc recv*[T](chan: GoChan[T]): Option[T] =
    ## Blocking
    ## Return false if channel is closed
    if chan[].closed:
        if not chan[].semaphore.tryWait():
            return none(T)
    else:
        chan[].semaphore.wait()
    return chan[].queue.popFirst()

iterator items*[T](chan: GoChan[T]): T {.inline.} =
    while true:
        let data = chan.recv()
        if data.isNone():
            break
        yield data.unsafeGet()
