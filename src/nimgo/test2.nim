import os

import aloganimisc/fasttest

import ./private/spinlock
import locks

const Rep = 100_000
runBench("syslock"):
    var lock: Lock
    for i in 1..Rep:
        acquire(lock)
        release(lock)
runBench("spinlock"):
    var lock: SpinLock
    for i in 1..Rep:
        acquire(lock)
        release(lock)
