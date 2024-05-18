import std/syncio

import ./eventdispatcher

type AsyncFile* = ref object
    fd: PollFd # PollFd is the same as the file fd
    file: File
    registeredEvents: set[Event]
    pollable: bool

proc syncioModeToEvent(mode: FileMode): set[Event] =
    case mode:
    of fmRead:
        {Event.Read}
    of fmWrite, fmAppend:
        {Event.Write}
    of fmReadWrite, fmReadWriteExisting:
        {Event.Read, Event.Write}

when defined(linux):
    import std/posix

    proc isPollable(fd: FileHandle): bool =
        ## EPOLL will throw error on regular file and /dev/null (warning: /dev/null not checked)
        ## Solution: no async on regular file
        var stat: Stat
        discard fstat(fd, stat)
        not S_ISREG(stat.st_mode)
else:
     proc isPollable(fd: FileHandle): bool = true

proc openAsync*(filename: string, mode = fmRead; bufSize: int = -1): AsyncFile =
    let file = open(filename, mode, bufsize)
    let fd = file.getOsFileHandle()
    let events = syncioModeToEvent(mode)
    let pollable = isPollable(fd)
    return AsyncFile(
        fd: if pollable: registerHandle(fd, events) else: PollFd(fd),
        file: file,
        registeredEvents: events,
        pollable: pollable
    )

proc openAsync*(afile: var AsyncFile, fd: FileHandle, mode = fmRead): bool =
    var file: File
    result = open(file, fd, mode)
    let fd = file.getOsFileHandle()
    let events = syncioModeToEvent(mode)
    let pollable = isPollable(fd)
    afile = AsyncFile(
        fd: if pollable: registerHandle(fd, events) else: PollFd(fd),
        file: file,
        registeredEvents: events,
        pollable: pollable
    )

proc getOsFileHandle(afile: AsyncFile): FileHandle =
    FileHandle(afile.fd)

proc close*(afile: AsyncFile) =
    afile.fd.unregister()
    afile.file.close()

proc readBuffer*(afile: AsyncFile, buffer: pointer, len: Natural): int =
    if afile.pollable and runnedFromEventLoop():
        if Event.Read notin afile.registeredEvents:
            updateEvents(afile.fd, {Event.Read})
        suspendUntilRead(afile.fd)
    afile.file.readBuffer(buffer, len)

