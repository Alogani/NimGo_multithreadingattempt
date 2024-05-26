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

proc recv*[T](chan: GoChan[T], timeoutMs = -1): Option[T] =
    ## Blocking, except if timeout == 0
    ## Return false if channel is closed
    ## Return false if data is not avalaible when timeout is set
    if timeoutMs == 0 or chan[].closed:
        if not chan[].semaphore.tryAcquire():
            return none(T)
        return chan[].queue.popFirst()
    elif timeoutMs == -1:
        chan[].semaphore.wait()
        return chan[].queue.popFirst()
    else:
        if not chan[].semaphore.waitWithTimeout(timeoutMs):
            return none(T)
        return chan[].queue.popFirst()

iterator items*[T](chan: GoChan[T]): T {.inline.} =
    while true:
        let data = chan.recv()
        if data.isNone():
            break
        yield data.unsafeGet()
