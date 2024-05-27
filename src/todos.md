_Short term tasks_

# Bugs / Deceptive behaviours

* addExitProc destroy global memory. Solutions:
    * replace it by waitEventLoop() ?
* EventDispatcher.timersShared can be filled with nil dispatcher, delaying the end of the program. Solutions:
    * Clean it up at each runOnce ?
    -> maybe need a custom heapqueue to maintain efficacity

* NimGoNoThread not implemented

# Next steps

* Finish implementation of gotasks
    * goAsync
    * wait
    * etc
* add sleepAsync
* Refactor asyncfile