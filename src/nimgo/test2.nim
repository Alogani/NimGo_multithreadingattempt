import ./private/spinlock

var lock = SpinLock()

proc deadlock() =
    echo "in"
    lock.acquire()
    echo "acquire 1"
    lock.acquire()
    echo "acquire 2"
    lock.release()
    echo "release 1"
    lock.release()
    echo "release 2"

deadlock()