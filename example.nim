import nimgo

## # Basic I/O
proc readAndPrint(file: AsyncFile) =
    var data: string
    ## Async depending on the context:
    ##  - If readAndPrint or any function calling readAndPrint has been called with *goAsync*
    ##      then the read is async, and function will be paused until readAll return.
    ##      This will give control back to one of the function that used goAsync and allow execution of other functions
    ##  - If goAsync was not used in one of the callee, the read is done in a sync way, blocking main thread
    data = file.readAll()
    ## Always sync, no matter the context
    data = file.readAllSync()
    ## Always async, no matter the context
    data = file.readAllAsync()
    data = wait goAsync file.readAll()


var myFile = AsyncFile.new("path", fmRead)
## Inside sync context:
readAndPrint()
## Inside async context:
goAsync readAndPrint()


## # Coroutines communication

## ## Returning a value:
proc getDataFromFile(f: AsyncFile): string =
    f.readAll()
## With sync context:
echo "DATA=", getDataFromFile(myFile)
## With async context:
echo "DATA=", wait goAsync getDataFromFile(myFile)

## ## With closures:
proc main() =
    ## Channels, queues, and any other data structure can be used
    var sharedData: string 
    proc myClosure() =
        sharedData = "Inside the coroutine"
    wait goAsync myClosure()


## # Coroutines order of execution

## See *About NimGo Threading model* inside README.md to have more information of how and why

when defined(nimGoNoThread):
    var task = goAsync scheduledFunction()
    executedBefore()
    wait task ## `scheduledFunction` is called here

when defined(nimGoNoThread):
    goAsync scheduledFunction()
    executedBefore()
    runEventloop() ## `scheduledFunction` is called here

when not defined(nimGoNoThread):
    ## This is the default behaviour. 
    goAsync scheduledFunction() ## Will be scheduled as soon as possible inside EventLoop thread
    executedParellely() ## Will be executed inside main thread
    # No need to wait or use runEventLoop here

## Nested execution and more

proc getDataFromFile(file: AsyncFile): string =
    return file.readAll()

proc getDataAndModify(file: AsyncFile): string =
    return getDataFromFile(file)

proc getDataAndModifyTask(file: AsyncFile): Task[string] =
    return goAsync getDataAndModify(file)

let task1 = getDataAndModifyTask(myFile)
let task2 = getDataAndModifyTask(myFile)
let allTasks = task1 and task2
while not allTasks.finished:
    poll()
for data in wait allTasks:
    echo "DATA=", data