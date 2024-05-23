when not defined(NimGoNoThread):
    import std/[atomics, locks]
    export atomics, locks

    proc newAtomic*[T](val: sink T): Atomic[T] =
        result.store(val, moRelaxed)

else:
    discard
    ## Flag to introduce fake atomics. This will allow efficient coroutine usage in single threaded usage
