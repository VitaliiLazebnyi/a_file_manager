# Status: localfs

| ID   | Status            | Note                                                                                                                                                                                                                                              |
| ---- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L001 | fixed             | DirectoryWatcher.swift: watch() only records the request; realpath, FSEventStreamCreate/Start run on the watcher own queues, per folder on its own thread with a 2 s patience. Skipping non-local volumes not done (see Decisions).               |
| L002 | duplicate of L001 |                                                                                                                                                                                                                                                   |
| L003 | fixed             | as L001; resolutions are cached per folder, so unchanged folders are not re-resolved. The 512-folder virtual route is now harmless for the caller.                                                                                                |
| L004 | fixed             | LocalFileSystem.swift: places() never waits, returns last/fixed list; watchdog (8 s) abandons a stuck read, at most 2 abandoned reads at once.                                                                                                    |
| L005 | fixed             | Watch coalesces: one pending set, one delivery per 0.3 s (1 s after rescan), never sooner than 0.5 s after the previous. IgnoreSelf not used.                                                                                                     |
| L006 | fixed             | LocalSupport.swift LinkResolver: targets on local mounts stat inline, others on a helper thread with 1.5 s patience and a cap of 8 stuck questions; cancellation checked per entry in entries(of:). Limit: locality is judged from the link text. |
| L007 | fixed             | places() posts LocalFileSystem.placesDidChange (raw name AFMPlacesDidChange) on main when the list changed; shell already observes it (shell.md item 8).                                                                                          |
| L008 | fixed             | write() creates 0600 with O_CLOEXEC, fchmod/futimens on the descriptor at close.                                                                                                                                                                  |
| L009 | fixed             | read/append open with O_NONBLOCK, fstat, refuse non-regular, clear the flag; copyMetadata refuses pipes/devices.                                                                                                                                  |
| L010 | fixed             | lockedCopies only for temporary names, TTL 6 h, oldest-first eviction, never wiped; folders via copyMetadata not remembered; entry dropped on rename/remove.                                                                                      |
| L011 | fixed             | setAttributes uses utimensat/lchmod with NOFOLLOW; lock restored if a later step fails.                                                                                                                                                           |
| L012 | duplicate of L004 |                                                                                                                                                                                                                                                   |
| L013 | duplicate of L004 |                                                                                                                                                                                                                                                   |
| L014 | duplicate of L001 |                                                                                                                                                                                                                                                   |
| L015 | duplicate of L005 |                                                                                                                                                                                                                                                   |
| L016 | needs other area  | Target size is computed (LinkResolver) but FileItem has no field; request in cross-requests/localfs.md item 1.                                                                                                                                    |
| L017 | duplicate of L009 |                                                                                                                                                                                                                                                   |
| L018 | duplicate of L010 |                                                                                                                                                                                                                                                   |
| L019 | not a defect      | Verdict confirming the refusal of a user locked original and a job-copied locked file; behaviour kept (tests added).                                                                                                                              |
| L020 | fixed             | as L011; callers FileJob/SyncPlan are safe unchanged.                                                                                                                                                                                             |
| L021 | duplicate of L004 |                                                                                                                                                                                                                                                   |
| L022 | fixed             | watched is set only after a started stream; the next request retries.                                                                                                                                                                             |
| L023 | not fixed         | rename/unlink/lchflags/xattr/trash have no cancel hook in the provider API; open/read/write are interruptible, the rest cannot be ended without a signal around every call.                                                                       |
| L024 | fixed             | Reader and Writer implement interrupt() (signal to the blocked thread); append checks the flag around open and truncate.                                                                                                                          |
| L025 | fixed             | link stat guarded by LinkResolver (see L006); failed-entry lstat is local to the directory being listed.                                                                                                                                          |
| L026 | fixed             | partly: names that are not valid UTF-8 are detected and the item is marked isSpecial (never opened); Foundation URLs cannot carry the raw bytes.                                                                                                  |
| L027 | fixed             | full listing drops an entry whose bulk attributes and lstat both failed.                                                                                                                                                                          |
| L028 | fixed             | isPackage skips shares mount points; link/folder questions bounded (L006). contentsOfDirectory fallback is unchanged (only on volumes without bulk reads).                                                                                        |
| L029 | not fixed         | createDirectory must stay idempotent for many callers (copy into a linked folder, ensureFolder); needs a new exclusive API, requested in cross-requests/localfs.md item 5.                                                                        |
| L030 | fixed             | move(replacing:true) between two hard links unlinks the source, only when both names are exact stored names of distinct entries (never after a case/accent-only rename).                                                                          |
| L031 | fixed             | copy() takes regular files and links only; folders throw EISDIR, special files EINVAL.                                                                                                                                                            |
| L032 | not fixed         | copyfile is cancellable only through its progress callback, as the API allows; metadata and clone steps are short.                                                                                                                                |
| L033 | fixed             | O_CLOEXEC on all opens; EINTR retried for open and getattrlistbulk.                                                                                                                                                                               |
| L034 | fixed             | totalSize walks run with the dataless-file materialisation policy off (per thread).                                                                                                                                                               |
| L035 | fixed             | totalSize checks the flag before every buffer; listing/entries per buffer and per entry.                                                                                                                                                          |
| L036 | fixed             | readPlaces asks each volume on its own thread with 3 s patience, falls back to last known; watchdog as L004.                                                                                                                                      |
| L037 | fixed             | volume(of:) runs on a helper thread with 3 s patience, mount found via getfsstat(MNT_NOWAIT); a stuck mount is answered from the last known info at once.                                                                                         |
| L038 | fixed             | spareSpace entries carry f_fsid; a different volume at the same path starts afresh.                                                                                                                                                               |
| L039 | fixed             | a measurement older than 30 s is taken for lost and started again.                                                                                                                                                                                |
| L040 | fixed             | per-buffer cancellation in totalSize; COPYFILE_DATA_SPARSE added to copy.                                                                                                                                                                         |
| L041 | fixed             | teardown does streamQueue.sync{} after invalidate, on the control queue.                                                                                                                                                                          |
| L042 | fixed             | read() refuses non-regular files; Descript/Checksum callers get an error instead of a hang.                                                                                                                                                       |
| L043 | needs other area  | Writer.close now by descriptor (fixed here); Unpacker createDirectory / openat walking belong to archives; see L029 request.                                                                                                                      |
| L044 | duplicate of L004 |                                                                                                                                                                                                                                                   |
| L045 | duplicate of L008 |                                                                                                                                                                                                                                                   |
| L046 | fixed             | as L010: no wholesale wipe.                                                                                                                                                                                                                       |
| L047 | fixed             | unlockOwnCopy opens with O_SYMLINK and checks/unlocks through fstat/fchflags on the descriptor.                                                                                                                                                   |

## Decisions

- Non-local volumes are still watched (the stream is made in the background, so a dead share cannot freeze anything);
  skipping them would remove auto-refresh on shares.
- `kFSEventStreamCreateFlagIgnoreSelf` is not used: the app relies on seeing its own changes to refresh panels.
- Coalescing: 0.3 s after the first report (1 s after a rescan flag), at least 0.5 s between deliveries.
- The lock allowance of `lockedCopies` is kept only for copies whose name looks temporary (leading dot plus `.tmp` or
  `.afm-`); a locked copy under a final name is as locked as its source.
- `read` refuses folders, pipes, devices and sockets with an error; `append` refuses links (ELOOP error) and pipes.
- A new file without given permissions gets 0644 less the umask at close (read once at start).
- `places()` returns the fixed places (Home, Desktop, Documents, Downloads, Applications) until the first read lands;
  volumes appear with `placesDidChange`.
- Blocked calls are ended with a no-op SIGURG handler sent to the blocked thread (repeated for up to 5 s); SIGURG is
  unblocked on threads that make such calls.
- `createDirectory` stays idempotent (L029).
- Extra, additive: `LocalFileSystem.deviceID(of:)`, `isMountPoint(_:)`, `placesDidChange`.
- Data loss fix from the find agent: move(replacing:true) no longer unlinks the source after a case-only or NFC/NFD
  rename.

## Tests

New: `Tests/PluginTests/Review2LocalfsTests.swift` (suites Review2LocalFileSystem, Review2DirectoryWatcher). Updated for
deliberate changes: LocalFileSystemTests, LocalFileSystemMoreTests, KernelFixLocalTests (places settle first; watcher
test keeps writing until the first report), KernelApiLocalTests (spare-space tuple; locked folder copy uses a temporary
name). Final run (filter
Review2LocalFileSystem|Review2DirectoryWatcher|LocalDisk|LocalDiskExtras|KernelApiOnLocalDisks|LocalDiskFixes): 59 tests
in 14 suites passed. The full PluginTests run was not completed: it hangs in the Network tests' fake FTP server (not
this area); on an earlier snapshot with older sibling sources it ran with no failure attributable to this area. The
accent-only/case-only move-with-replace data-loss bug is tested in
`aRenameOfOnlyTheLettersCaseOrTheFormOfAnAccentNeverRemovesTheFile` (passes).

## Not done

- L016 (needs `FileItem` field), L029 (needs exclusive createDirectory API), L023/L032 (no cancel hook for
  rename/unlink/copyfile), raw-byte names (L026 only marks them), openat/unlinkat tree removal (fileops item 11), link
  locality is judged by the link text (a path through an intermediate link to a share is not recognised).
