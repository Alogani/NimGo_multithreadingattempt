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
- [X] Implements the possibility to run the Event loop in a second thread
- [X] Implements the basic I/O operations for files
- [ ] Implements all the I/O operations for files
- [X] Implements "GoSemaphore": a blocking primitive working on both coroutines and threads
- [X] Implements "GoChannel": a blocking queue working on both coroutines and threads
- [ ] Allow to smoothly pass data into coroutines (like closures) thread safely
- [X] Implement the *goAsync* template to add a coroutine inside the event loop
- [X] Introduce a *Task[T]* type as the return type of *goAsync*
- [ ] Introduce some utilities for *Task[T]* :
 - `proc wait[T](task: Task[T]): T` (will block the current thread/or delegate to the event loop)
 - `proc isCompleted[T](task: Task[T]): bool`
 - `proc waitAll[T](task: seq[Task[T]]): seq[T]`
 - `proc waitAny[T](task: seq[Task[T]])`
 - etc. ?
- [X] Implements the I/O operations for timers/process/events/signals
- [ ] Implements the basic I/O operations for sockets
- [ ] Implements all the I/O operations for sockets
- [ ] See if an interoperability layer can be implemented between NimGo's *Task[T]* and std/asyncdispatch's *Future[T]*

## Comparisons with alternatives I/O handling paradigm

### Compared to sync operations:

- **Advantages**:
  - The possibility to run concurrent code:
    - faster for sending multiple I/O requests
    - Or to facilitate complex intercommunications
- **Drawbacks**:
  - slightly slower for very fast I/O operations (files)
  - usage of more memory (barely noticeable for few I/O operations)

### Compared to threads
_The advantages and drawbacks are similar than comparing async/await with threads_

- **Advantages**:
  - simpler to spawn, simpler to pass data between coroutines and have a result
  - more lightweight on memory
  - No spawn limit (hundreds of thousands of courintes can be spawned)
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
  - Should be slightly faster _to confirm_
  - Async/await uses many templates, which slow down the compilation (however mitigitated by incremental compilation)
- **Drawbacks**:
    - More memory is consumed for each new Coroutine:
        - this can made it less suitable for very high demanding servers (basic benchmarks in nimgo/benchmarks show that async/await memory don't grow, whereas nimgo grows at a constant pace. However asyncdispatch crashed on higher loads)
        - The higher memory consumption has to be relativised because :
            - data doesn't need anymore to be encapsulated in a Future[T] object which is passed around
            - for most usages, the difference of memory usage should be barely noticeable (only 50 kB for 1K spawns)
    - The async nature of I/O operation is not explicit anymore. If a library uses blocking I/O and `goAsync` is used it will block the event loop
    - Async/await allows more control on the data flow

### Compared to CPS I/O library (continuation passing style)

_Having never coded with CPS, my point of view shall be taken with a grain of salt. Please let me know if some informations are wrong. But CPS seems like a cool project !_

CPS in itself is a coding style/paradigm. In itself, it is not concurrent, but can be used to implements Stackless coroutines and to enable concurrency. To my knowledge, no I/O library with CPS has been implemented yet.

Stackless and stackful coroutines should not be confused, as they design two very different way to suspend the execution of the code, but often people uses those terms interchangeably

You can see https://github.com/nim-works/cps for more details, and I think [nimskull](https://github.com/nim-works/nimskull/pull/1249) are working on stackless coroutines with CPS 


- **Advantages**:
  - CPS even if they don't directly colors functions, imposes a coding style
  - CPS is more complex and requires to manually manage the control flow
  - Therefore CPS is less intuitive, less readable, and more verbose
  - CPS may be less interoperable with an existing sync codebase
  - CPS might have a little computing overhead (not sure, it might be more efficient ?) due to more function calls and memory allocations
  - CPS uses many templates, which slow down the compilation (however mitigitated by incremental compilation)
- **Drawbacks**:
  - CPS answers some problematics beyond I/O (Doesn't answer necessarly the same problematics). It shines for example inside compilers
  - CPS is efficient on memory and more suited in constrained environment
  - CPS allow fine grained control of the data flow without hiding the details, and so is more flexible
  - CPS might be easier to debug


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
