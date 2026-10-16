# FSEvents closes descriptor 0 when it fails to make a stream

Found on 2026-10-16 (macOS 27.0.1, 26A434), while looking into a crash of a full PluginTests run.

## What was seen

The PluginTests process ended with `EXC_GUARD` (`GUARD_TYPE_FD`, "CLOSE on file descriptor 0 (guarded)"), report
`swiftpm-testing-helper-2026-10-16-073947.ips`. The faulting stack:

```text
close
_FSEventStreamDeallocate
_FSEventStreamCreate
FSEventStreamCreate
DirectoryWatcher.Core.startedStream(for:folders:on:)
DirectoryWatcher.Core.reconcile()
```

Running at that moment, among others: `CoverageLocalWatcher.aFolderTheSystemCannotWatchIsTriedAgain`, which asked the
watcher for a folder with a path of 5,000 characters, in the shared test process.

## The cause

`FSEventStreamCreate` keeps one slot per requested path, in memory that starts as zeros; a slot holds the descriptors
the stream opens for that path and its parents. When the call fails part-way, `_FSEventStreamDeallocate` closes the
descriptor of every slot, also of the slots it never filled, and those still say 0. So it closes descriptor 0, which
the stream never owned, once for every path it had not set up.

Descriptor 0 is the standard input, or, once that is closed, whatever the program opens next: the lowest free number is
always taken first. The next failure closes that one under its owner. In the tests that was a socket, a pipe or a file
being written of another test running at the same time. In the crash above, the number 0 had a guard on it (most
likely it had gone, after an earlier silent close, to a descriptor that its owner guards), and the kernel ended the
process at the second close.

In plain words: a watcher test asked FSEvents for an impossible folder; FSEvents failed and, while cleaning up, closed a
descriptor that belonged to somebody else. Every retry did it again, to whoever had that number by then.

## When the call fails part-way

Measured with a probe (`FSEventStreamCreate` with `kFSEventStreamCreateFlagWatchRoot`, as the watcher makes them):

| Request                                                  | Stream | Descriptor 0         |
| -------------------------------------------------------- | ------ | -------------------- |
| one path of 1,023 bytes                                  | made   | stays                |
| one path of 1,024 bytes or more (`PATH_MAX` with the 0)  | none   | **closed**           |
| a short path and a long one                              | none   | **closed**           |
| 341 × "é": 683 bytes as UTF-8, 1,024 bytes decomposed    | none   | **closed**           |
| a missing folder, a relative path, an empty string       | made   | stays                |
| no path at all                                           | none   | stays                |
| one folder, 0 to 39 descriptors left (11 kinds of path)  | some   | stays (440 of 440)   |
| two folders, 1 or 2 descriptors left                     | none   | **closed**           |
| three folders, 1 to 7 descriptors left                   | none   | **closed**           |
| the 513th running stream of the process (not started)    | made   | stays                |

So two things reach the clean-up: a path that does not fit in `PATH_MAX` bytes as the file system spells it (decomposed;
one such path is enough), and running out of descriptors part-way through a request for more than one folder. The
per-process limit of 512 streams is harmless: the 513th is made, and `FSEventStreamStart` refuses it.

A running stream holds a descriptor for the folder and for each of its parents, and a few of its own: 3 for `/`, 6 for
`/private/tmp`, 71 for a folder 67 levels down. A program started from the Finder has a soft limit of 256 descriptors.

## What the watcher does now

`Sources/Plugins/LocalFileSystem/FSEvSystem.swift`, `FSEvDescriptors.swift`, `FSEvCore.swift`:

- A folder whose real path does not fit (`CFStringGetFileSystemRepresentation` into `PATH_MAX` bytes) is left out: it is
  never asked for, and not tried again. (Such folders exist: a path can be longer than `PATH_MAX` on disk, `realpath`
  then fails and the watcher used to pass the long path on.)
- One stream per folder. The program only ever asks for one folder per watcher; tests ask for more, and each now gets a
  stream of its own, so running out of descriptors can only fail a one-folder request, which leaves descriptor 0 alone.
- Before it makes streams, the watcher checks that the process has their cost in descriptors to spare and still keeps
  64 for the rest of the program; if not, it makes none, counts the refusal and tries again later, as for a refusal of
  the system.
- If the system fails all the same, descriptor 0 is given `/dev/null` back when it is free. That is safe whatever other
  threads do: `open` takes the lowest free number, so it lands on 0 only when 0 is free; otherwise it lands elsewhere
  and is closed again.

What makes the streams and counts the descriptors is a seam (`FSEvSystem`), so the failures are tested without the
system: `Tests/PluginTests/FSEvDescriptorZeroTests.swift`. The tests that let the real system fail or change the
descriptor limit run in a process of their own (exit tests).

## Other closes of a descriptor that was not one's own (tests)

Found while looking for further causes; each needs a `listen` or `pipe` that fails (out of descriptors), and each now
leaves nothing to close:

- `TestFTPServer`'s session kept the number of a passive listener it had closed when no new one could be made; a later
  transfer accepted on it and closed it, and so did the end of the session (`NetworkServerForTests.swift`).
- `CoverageNetworkServer.Line.openPassive`: the same, closed again in `deinit`.
- `Review2LocalfsTests.aBlockedCallIsEndedByInterrupt` and `CrossRequestTests` started their pipe pair as `[0, 0]` and
  closed both ends whether or not the pipe was made.

The probe is `/private/tmp/claude-501/sp/w101-fsevents/probe.swift` (not kept in the repository); the table above is
its output.
