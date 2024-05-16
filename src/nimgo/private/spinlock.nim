type
    atomic_flag {.importc, header: "<stdatomic.h>".} = object

proc atomic_flag_clear(lock: var atomic_flag) {.importc, header: "<stdatomic.h>".}
proc atomic_flag_test_and_set(lock: var atomic_flag): bool {.importc, header: "<stdatomic.h>".}


type SpinLock* = atomic_flag
        ## Non reentrant lock
        ## Highly efficient under low contention

proc acquire*(lock: var SpinLock) =
    while atomic_flag_test_and_set(lock):
        ## Busy wait
        discard

proc release*(lock: var SpinLock) =
    atomic_flag_clear(lock)