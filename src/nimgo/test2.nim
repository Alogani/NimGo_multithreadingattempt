import ./coroutines
import ./corochan
import ./eventdispatcher

import ./public/task

var mychan = newCoroChan[string]()

proc client() =
    mychan.setListener(getCurrentCoroutine())
    for data in mychan:
        echo "data=", data

proc producer() =
    for i in 0..5:
        mychan.send("blah=" & $i)
        discard registerTimer(500, false, @[getCurrentCoroutine()])
        suspend()
    mychan.close()

goAsync client
goAsync producer