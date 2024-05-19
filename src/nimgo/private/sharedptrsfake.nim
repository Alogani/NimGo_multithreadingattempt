# Source: https://nimble.directory/pkg/threading
# With some tweaks


type
    SharedPtr*[T] = object
        ## Shared ownership reference counting pointer.
        val: ref T

proc newSharedPtr0*[T](t: typedesc[T]): SharedPtr[T] =
    ## Returns a zero initialized shared pointer
    result.val = new T

proc isNil*[T](p: SharedPtr[T]): bool {.inline.} =
  p.val == nil

proc `[]`*[T](p: SharedPtr[T]): ref T {.inline.} =
  p.val
