import ./coroutines

type
    ShowHooks = object
        val: int

    ShowHooksRef = ref ShowHooks

proc `=copy`*(dest: var ShowHooks, src: ShowHooks) =
    echo "Copy"
    dest.val = src.val

proc `=dup`*(src: ShowHooks): ShowHooks =
    echo "Dup"
    result.val = src.val

proc `=sink`(dest: var ShowHooks; src: ShowHooks) =
    echo "Sink"
    dest.val = src.val

proc `=wasMoved`(x: var ShowHooks) =
    echo "WasMoved"

proc `=destroy`*(x: ShowHooks) =
    echo "Destroy"

var cb1: Coroutine
var cb2: Coroutine
proc main() =
    var myObject = ShowHooks(val: 42)
    proc consumer() =
        echo myObject.val
        myObject.val = 54

    proc producer() =
        echo myObject.val

    
    cb1 = Coroutine.new(consumer)
    cb2 = Coroutine.new(producer)
    
main()
cb1.resume()
cb2.resume()