# NimGo

_NimGo: Asynchronous Library Inspired by Go's Asyncio. Or for Purists: Stackful Coroutines library associated with an I/O Pollable Event Loop and Dispatcher_

This repository is currently in the ideation phase, and no alpha release is expected in the near future.

## Goal
Provide a simple, concise and efficient library for I/O.

No async/await, no pragma, no Future[T] everywhere !

Only one word to remember : **goAsync** (and optionaly **wait**, but seriously who needs that ?)

## Roadmap

- [X] Implements the stackful coroutine API
- [ ] Implements the Event loop API in the same thread
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
  - lightweigth on memory
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
    - More memory is consumed by I/O operations, but slighlty compensated by the fact that:
        - data doesn't need anymore to be encapsulated in a Future[T] object
        - virtual memory can be used
    - The end user doesn't know anymore if data inside the library is async or not
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

proc main()
proc read(file: File, count: int)

## Example 1
var task = goAsync main(id = 1) # main is scheduled to be executed. It won't run necessarly immediatly. It will be executed in async context, meaning all I/O operations will be done in a async way (using epoll/select, etc, it won't spawn threads)/
main(id = 2) # main will be executed inside an non-async context (all I/O operations will be sync UNLESS goAsync is explictly used inside main)
wait task

## Example 2
when not defined(spawnGoAsyncThread):
  goAsync main(id = 1)
  main(id = 2) ## Here main(id = 2) is guaranted to be executed before main(id = 1)
  runEventloop() ## This call is necessary, otherwise main(id = 1) will never be executed
  ## This code could be useful when you want to have multiple threads with each one its event loop
else:
  ## Here on thread is spawn, for the event loop. No other threads shall be spawn for I/O operations, so there will be only two threads (one running sync code, and another running async code)
  goAsync main(id = 1)
  main(id = 2) ## Here main(id = 2) is not guaranted to be executed before main(id = 1)
  ## The main thread will wait for the event loop to finish, the call to runEventLoop() is useless

proc main(id: int) =
  ## This is the end user code
  discard goAsync myFile1.write("data") ## operation is scheduled but won't happen yet
  wait goAsync myFile2.write("data") ## -> will do I/O in a async way (traiting pending operations) but wait until it is done
  myFile2.write(id) ## if id == 1, we are in async context, so the I/O will be done in a async way and be waited. Otherwise it will be done in a sync way
  echo goAsync myFile3.readAll()

proc read(file: File, count: int) =
  ## This is implementation detail that the end user won't know
  if isAsyncThread:
    EventLoop.register(file)
    suspendUntilReadAvailable(file)
    return file.readBlocking(count)
  else:
    return file.readBlocking(count)
```
