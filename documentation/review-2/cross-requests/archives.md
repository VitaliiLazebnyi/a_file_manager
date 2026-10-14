# Cross-requests from the archives area

Nothing here blocks the archives fixes: each item has a local fallback that is in place.

## 1. Kernel + shell: let plugins finish their work before the program quits (A006, A008, A009, A010, A014, A032)

**Now (inside the archives area):** `ArchivesPlugin.stop()` no longer writes on the main thread. It starts the writes on
a background thread and waits for them while it keeps the main run loop turning (so a server that asks for a password on
the main thread is answered instead of deadlocking), for at most `ArchiveEnvironment.quitTimeout` (120 s), then cancels
the writes and keeps the unwritten members on disk. That is correct and cannot deadlock, but the user sees no progress
and cannot cancel.

**Wanted:**

- `AFMKernel/PluginAPI/Kernel.swift`, protocol `Plugin`: a new optional requirement with a default,
  `func prepareToQuit(cancellation: CancellationFlag, completion: @escaping () -> Void)` (default: calls `completion()`
  at once), and `Kernel.prepareToQuit(cancellation:completion:)` that calls it on every plugin and calls `completion` on
  the main thread when all are done.
- `AFMShell/App/Shell.swift`, `applicationShouldTerminate`: after the job queue is drained, call `kernel.prepareToQuit`
  and return `.terminateLater`; show a "Saving archives…" sheet with Cancel (which sets the flag); reply to the
  application from the completion.
- The archives plugin already has what this needs: `ArchivesPlugin.hasPendingChanges` and
  `ArchivesPlugin.writePendingChanges(cancellation:completion:)`. Once the hook exists, `ArchivesPlugin.prepareToQuit`
  is one line forwarding to it; `stop()` stays as the safety net.

## 2. Network plugin: keep sessions until the archives are written (A032)

`NetworkPlugin.stop` runs before `ArchivesPlugin.stop` and drops its sessions, so an archive that lies on a server and
still has to be uploaded at quit opens a new session, which asks for the password if it is not in the Keychain. With
item 1 in place the upload happens in `prepareToQuit`, before any plugin stops. Until then the question is answered (the
main run loop turns), but it should not be asked at all.

## 3. Kernel / FileOperations / LocalFileSystem: commit an open archive before its file is used (A044)

Changes made inside a ZIP are written into the archive file after a delay (up to 60 s when the whole archive has to be
rewritten). If the user copies, moves, uploads or deletes that archive file in another panel meanwhile, the file is
stale. The archives area cannot see those operations.

**Wanted:** a kernel hook that operations call for every source file before they read, move or delete it, e.g. in
`AFMKernel/FileSystem/FileSystemProvider.swift`, `FileSystemRegistry`:
`func addFlusher(_ flush: @escaping (URL, CancellationFlag) throws -> Void)` and
`func flushPendingWrites(to url: URL, cancellation: CancellationFlag) throws`, called by `FileJob` (copy, move, delete,
pack sources), the uploaders and the viewer. The archives plugin would register
`{ url, flag in try store.commit(url, cancellation: flag) }`, which is a table look-up for a file that is not an open
archive. Optionally a `FileItem`/panel mark for "has changes that are not written yet".

## 4. FileOperations: read the members of a stream archive in archive order (A041)

Copying many files out of a large `.tar.gz`/`.7z` that is too big for a temporary copy (> 256 MB) reads them in panel
order; each file that lies before the previous one restarts the decompression from the beginning.
`OpenArchive.readInOnePass` reads any set of members in one pass, and Unpack uses it; a copy job cannot.

**Wanted:** either an optional provider method `func readOrder(of urls: [URL]) -> [URL]` that `FileJob` uses to order
the files of one source folder tree before copying, or a batch read
(`func read(_ urls: [URL], cancellation:, body: (URL, FileReader) throws -> Void) throws`) with a default that loops.
The archives file system would implement either from `ArchiveEntry.order`.
