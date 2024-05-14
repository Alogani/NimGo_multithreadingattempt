import goasync/[dispatcher, coroutines]

type
    Task*[T] = distinct Coroutine[T]

template goAsync*[T](fn: proc(): T): Task[T] =
    ## Code will be scheduled inside the dispatcher
    registerAsyncFn(fn)

proc finished*[T](task: Task[T]): bool =
    return task.finished

proc wait*[T](task: Task[T]): T =
    ## Blocking
    while not task.finished:
        poll()