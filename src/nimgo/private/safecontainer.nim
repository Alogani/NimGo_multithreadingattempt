type
    GcRefContainer[T] = ref object
        val: T

template mustGoInsideRef(T: typedesc): bool =
    # Non closures proc don't need to be stored inside ref, but simpler this way
    T is void or T is seq or T is string or T is proc

type
    SafeContainer*[T] = object
        when mustGoInsideRef(T):
            val: GcRefContainer[T]
        else:
            val: T

proc toContainer*[T](val: sink T): SafeContainer[T] =
    when T is ref:
        Gc_ref(val)
    elif mustGoInsideRef(T):
        let val = GcRefContainer[T](val: val)
        Gc_ref(val)
    return SafeContainer[T](val: val)

proc toVal*[T](container: sink SafeContainer[T]): T =
    when T is ref:
        result = move(container.val)
        GC_unref(result)
    elif mustGoInsideRef(T):
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
    