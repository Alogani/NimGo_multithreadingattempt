type Context = enum
    Async, Sync

when defined(NimGoNoThread):
    var CurrentContext {.threadvar.} = Sync
else:
    var CurrentContext = Sync

type Task*[T] = ref object
    data: T

proc goAsync*[T](fn: proc(): T): Task[T] {.discardable.} =
    CurrentContext = Async
    fn()
    CurrentContext = Sync