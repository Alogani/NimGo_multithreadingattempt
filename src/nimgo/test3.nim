import ./private/threadqueue


type OmyRef = ref object
    val: int

var q = newThreadQueue[OmyRef]()
for i in 1..10:
    q.push(OmyRef(val: i))

while not q.empty():
    echo repr q.pop()

`=destroy`(q)