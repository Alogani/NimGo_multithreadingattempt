# NimGo

_NimGo: Asynchronous Library Inspired by Go's Asyncio. Or for Purists: Stackful Coroutines library associated with an I/O Pollable Event Loop and Dispatcher_

This repository is currently in the ideation phase, and no alpha release is expected in the near future.

## Goal
Provide a simple, concise and efficient library for I/O.

No async/await, no pragma, no Future[T] everywhere !

Only one word to remember : **goAsync** (and optionaly **wait**, but seriously who needs that ?)

## Roadmap

- [X] Implements the stackful coroutine API
- [X] Implements the Event loop API in the same thread
- [ ] Implements the possibility to run the Event loop in a second thread
- [ ] Implements the sync I/O operations for files
- [ ] Implements the async I/O operations for files
- [ ] Implement the *goAsync* template to add a coroutine inside the event loop
- [ ] Introduce a *Task[T]* type as the return type of *goAsync*
- [ ] Introduce some utilities for *Task[T]* :
 - `proc wait[T](task: Task[T]): T` (will block the current thread/or delegate to the event loop)
 - `proc isCompleted[T](task: Task[T]): bool`
 - `proc waitAll[T](task: seq[Task[T]]): seq[T]`
 - `proc waitAny[T](task: seq[Task[T]])`
 - etc. ?
- [ ] Implements the sync I/O operations for timers/process/events/signals
- [ ] Implements the async I/O operations for timers/process/events/signals
- [ ] Implements the sync I/O operations for sockets
- [ ] Implements the async I/O operations for sockets
- [ ] See if *Task[T]* can be converted to *Future[T]* from std/asyncdispatch to allow user to use both paradigm

## Comparisons with alternatives I/O handling paradigm

### Compared to sync operations:

- **Advantages**:
  - The possibility to run concurrent code:
    - faster for sending multiple I/O requests
    - Or to facilitate complex intercommunications
- **Drawbacks**:
  - slightly slower for very fast I/O operations (files)
  - usage of more memory -> to estimate, but maybe 4 KB (using virtual memory) to 56 kB (using physical memory) by active I/O waiting operation

### Compared to threads
_The advantages and drawbacks are similar than comparing async/await with threads_

- **Advantages**:
  - easiness to pass data
  - much more lightweight on memory, no OS limitations on the "spawning" count
  - faster for I/O
- **Drawbacks**:
  - Code is not running parellelly (Doesn't answer necessarly the same problematics)
  - No speed gain for CPU operations (instead added overhead)

### Compared to async/await

- **Advantages**:
  - No function coloring (see [here](https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/) for more details)
    - Less verbosity
    - Integration with sync code with almost no refactoring
    - I/O operations handling become implementation details, not polluting the end user
    - Compilation speed: almost no macro is necessary in coroutines implementation
  - An overall simpler implementation (current async/await implementation in nim still suffers from memory leaks and inefficiencies)
  - Slighlty faster (because Future[T] doesn't need to be passed each time anymore) -> to confirm
- **Drawbacks**:
    - More memory is consumed by I/O operations:
        - this can made it less suitable for very high demanding servers (hundreds of thousands of connections, see comparisons between go and rust)
        - The higher memory consumption has to be relativised because :
            - data doesn't need anymore to be encapsulated in a Future[T] object which is passed around
            - virtual memory can be used
            - for most usages, the difference of memory usage should be barely noticeable (-> to determine: a thresold where it can be noticeable)
    - The async nature of I/O operation is not explicit anymore
    - The end user can't control as much the flow of operations

### Compared to CPS (continuation passing style)
_having few knowledge of CPS, please take my assumptions with a grain of salt_

- **Advantages**:
  - No function coloring (see advantages compared to async/await for details)
  - Simpler to use
- **Drawbacks**:
  - _Same drawbacks as compared to async/await_
  - Doesn't answer necessarly the same problematics
  - Can't be moved between threads

## Example
_The exact and definitive API is susceptible to change_
```
import nimgo

## # Basic I/O
proc readAndPrint(file: AsyncFile) =
    var data: string
    ## Async depending on the context:
    ##  - If readAndPrint or any function calling readAndPrint has been called with *goAsync*
    ##      then the read is async, and function will be paused until readAll return.
    ##      This will give control back to one of the function that used goAsync and allow execution of other functions
    ##  - If goAsync was not used in one of the callee, the read is done in a sync way, blocking main thread
    data = file.readAll()
    ## Always sync, no matter the context
    data = file.readAllSync()
    ## Always async, no matter the context
    data = file.readAllAsync()
    data = wait goAsync file.readAll()


var myFile = AsyncFile.new("path", fmRead)
## Inside sync context:
readAndPrint()
## Inside async context:
goAsync readAndPrint()
```

See [example.nim](https://github.com/Alogani/nimgo/tree/main/example.nim) for more examples

## About NimGo Threading model

The distincion has to be made between OS Threads (or simply threads) and coroutines. Coroutines are lightweight, cooperative multitasking units within a single thread, whereas OS threads are separate execution units managed by the operating system that can run in parallel on multiple cores.
NimGo doesn't need OS Threads and won't spawn them for doing I/O operations.

But, by default, for efficiency and to avoid intervention from callee, a thread is spawned to run the event loop (and all coroutines). For clarification, it is the only thread spawned, no new thread will be spawned for each I/O operations, only coroutines.
This means that even if the user spawn multiple threads, only one thread will be responsible for I/O and handle it.

The user can prevent this behaviour by defining the variable nimGoNoThread `nim r -d:nimGoNoThread myProgram.nim`
In that case, no coroutines will be executed until either `wait` proc is used or `runEventLoop`.
This allow the user to spawn multiple threads with each their own I/O event loop (allowing more scalability for high demands)
