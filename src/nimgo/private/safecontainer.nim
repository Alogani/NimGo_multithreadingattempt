type
    GcRefContainer[T] = ref object
        val: T

    SafeContainer*[T] = object
        when T is seq or T is string:
            val: GcRefContainer[T]
        else:
            val: T

proc toContainer*[T](val: sink T): SafeContainer[T] =
    when T is ref:
        Gc_ref(val)
    elif T is string or T is seq:
        let val = GcRefContainer[T](val: val)
    return SafeContainer[T](val: val)

proc toVal*[T](container: sink SafeContainer[T]): T =
    when T is ref:
        result = move(container.val)
        GC_unref(result)
    elif T is string or T is seq:
        let gcContainer = move(container.val)
        Gc_unref(gcContainer)
        result = move(gcContainer.val)
    else:
        result = move(container.val)