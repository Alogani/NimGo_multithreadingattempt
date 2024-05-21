import ./coroutines
import ./gochannels
#import ./eventdispatcher

#import ./public/task

proc main() =
    var myChan = newGoChannel[string]()
    var myChan2 = myChan

    proc client() {.thread.} =
        var myChan = myChan.getReceiver()
        echo "Inclient"
        for i in 0..10:
            let data = myChan3.tryRecv()
            if data.isSome():
                echo "data=", data.get()
            else:
                echo "nodata"
        #for data in mychanRecv:
        #    echo "data=", data

    proc producer() {.thread.} =
        var myChan = myChan2.getSender()
        echo "Inproducer"
        for i in 0..4:
            discard myChan.trySend("blah=" & $i)
        #mychanSender.close()


    var clientCoro = Coroutine.new(client)
    var producerCoro = Coroutine.new(producer)
    clientCoro.resume()
    producerCoro.resume()
    let error = clientCoro.getException()
    if error != nil:
        raise error

main()