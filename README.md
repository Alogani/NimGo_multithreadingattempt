This repository was an early attempt at creating NimGo, and now serves as an archive of that work.

The original goal was to make the dispatcher run in a separate thread. However, due to the significant complexity involved in safely handling garbage collection (GC) memory in a multi-threaded environment, the decision was made to switch to a single-threaded implementation instead.

For the current, active implementation of NimGo, you should refer to https://github.com/Alogani/NimGo. The single-threaded approach was chosen to avoid the challenges posed by managing GC memory across multiple threads.
