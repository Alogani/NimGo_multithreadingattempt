when not defined(NimGoNoThread):
    import std/atomics
    export atomics

    proc newAtomic*[T](val: sink T): Atomic[T] =
        result.store(val, moRelaxed)

else:
    discard
    ## Flag to introduce fake atomics. This will allow efficient coroutine usage in single threaded usage