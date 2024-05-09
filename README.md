# goAsync

_A new take on asyncio, for the Nim language_

This repository is currently in the ideation phase, and no alpha release is expected in the near future.

## Problem Statement

### The issue with async/await

In the current implementation, the "async" nature of code is determined from the bottom up. This means that if any part of the code uses async, the entire codebase must also be async. This approach has several fundamental flaws:

- It "colors" functions, forcing all code depending on async to also be async. More information can be found [here](https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/) about this problem.
- It introduces verbosity with the constant use of await or callbacks.
- It incurs overhead by encapsulating results in Futures and rewriting functions to make them async.
- The Nim implementation of async still suffers from memory leaks.
- etc.


### The issue with coroutines/threads

In this type of implementation, async behavior is determined from the top down, allowing high-level code or end users to decide which code will run asynchronously. This approach makes more sense; however, a problem arises when the underlying code relies solely on blocking I/O and does not utilize the system events scheduler efficiently. This inefficient approach leads to the spawning of numerous threads for each blocking operation, resulting in high costs and limitations.

### The issue with CPS (continuation passing style)

Although CPS provides clear flow control and efficiency, it becomes challenging to mix synchronous code with CPS style, as CPS is not designed to return. It is a complex and unfamiliar approach, characterized by verbosity and function coloring.

## The Proposed Solution

In my opinion, a good async API should :
- Be simple, concise, and resemble synchronous code.
- Allow easy integration with synchronous code.

To achieve this, I propose utilizing two distinct threads: one for synchronous tasks and another for asynchronous tasks, representing them as colored threads rather than functions. The synchronous thread, when performing I/O operations directly, will solely employ blocking code or leverage the capabilities of the asynchronous thread. On the other hand, the asynchronous thread will handle I/O operations through an event loop. This clear differentiation ensures that there will be no function coloring within either thread.

This transition can be triggered using a keyword in the synchronous thread: **goAsync**.

#### Example:
```
Possible example:
proc main() =
  ## Inside the synchronous thread:
  discard goAsync myFile.write("data")
  echo goAsync myFile.readAll()

proc read(file: File, count: int) =
  if isAsyncThread:
    EventLoop.register(file)
    suspendUntilReadAvailable(file)
    return file.readBlocking(count)
  else:
    return file.readBlocking(count)
```

## Roadmap

1. Implement an event loop.
2. Implement a way to "suspendAndPoll" procs inside the asynchronous thread (considered a crucial aspect).
3. Implement the ioselectors and synchronous operations.
4. Implement the *goAsync* template to spawn a proc inside the asynchronous thread.
5. Introduce a *Task[T]* type as the return type of *goAsync* using channels, which can be awaited in a blocking manner using the *wait* keyword.
6. Add additional procs for *Task[T]*, such as `proc isCompleted[T](task: Task[T]): bool`, `proc waitAll[T](task: Task[T]): seq[T]`, `proc waitAny[T](task: Task[T])`, etc.

I am uncertain if this implementation is feasible, as some aspects are currently beyond my knowledge. However, this repository serves as an attempt to explore these ideas, and contributions are welcome.
