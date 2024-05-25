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
        Gc_ref(val)
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

proc isNil*[T](container: SafeContainer[T]): bool =
    when T is ref or T is string or T is seq:
        container.val == nil
    else:
        false

proc destroy*[T](container: SafeContainer[T]) =
    ## Not needed if toVal has been called
    when T is ref or T is string or T is seq:
        if container.val != nil:
            GC_unref(container.val)
    else:
        discard
    