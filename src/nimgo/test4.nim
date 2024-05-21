import ./[gochannels, coroutines]

template consumerProducerCode() {.dirty.} =
    #var myChan = newGoChannel[string]()
    let (receiver, sender) = newGoChannel2[int]()

    proc producerFn() {.thread.} =
        for i in 0..3:
            discard sender.trySend(i)
        sender.close()

    proc consumerFn() {.thread.} =
        for data in receiver:
            echo data

consumerProducerCode()
let producerCoro = Coroutine.new(producerFn)
let consumerCoro = Coroutine.new(consumerFn)
consumerCoro.resume()
producerCoro.resume()
echo producerCoro.getState()
echo consumerCoro.getState()