# Review local file system plugins

# Second-round review: LocalFileSystem, Navigation, ViewOptions, FolderTabs

All eight files in scope were read in full, plus the kernel protocol, `Parallel`, `CancellationFlag`, `PanelTabs`, the relevant parts of `PanelModel`, and the callers of `places`, `volume` and `watch`. "Confirmed" means reproduced with a standalone experiment against the real sources, or unambiguous from the code. No project file was modified; experiments live under `.../scratchpad/review2/localfs/`.

Paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/` unless they start with `AFMKernel` or `AFMShell`.

## Findings

### 1. HIGH — freeze — `LocalFileSystem/DirectoryWatcher.swift:74,115-119` (reached from `LocalFileSystem.swift:840`)
- **What:** `watch()` runs `realpath()` on every directory, then `FSEventStreamCreate` with `WatchRoot` (which opens each path) and `FSEventStreamStart`, all on the caller's thread. The caller is `PanelCoordinator.updateWatchers` (`AFMShell/Window/PanelCoordinator.swift:171-179`), which is main-thread only and runs on every location change.
- **Trigger:** the right panel shows a folder on an SMB/NFS share that has stalled. The user navigates in the left panel; `updateWatchers` re-resolves both directories and `realpath` on the dead mount blocks the main thread with no timeout.
- **Also:** VirtualFolders passes up to 512 folders per call (`VirtualFolders/VirtualFileSystem.swift:463-469`), so one call can be 512 `realpath`s; I did not check which thread that call runs on.
- **Fix:** have `LocalFileSystem.watch` return the token at once and do resolve/create/start on the watcher's own serial queue, with stop serialised on the same queue. Also skip re-resolving directories whose `locationKey` has not changed.
- **Confidence:** confirmed by code path; the stall itself was not simulated.

### 2. HIGH — freeze — `LocalFileSystem/LocalFileSystem.swift:670-681`
- **What:** `places()` computes a fresh one-second deadline on every call while `knownPlaces == nil`. The comment says only the first question waits; the code waits on every call until the first read finishes.
- **Reach:** it is called on main from `DriveBarView.rebuild` (`AFMShell/Window/ButtonBarView.swift:192`, at launch and on every mount notification), the volume menu (`AFMShell/Panel/PanelViewController.swift:916`) and `NavigationPlugin.swift:161`.
- **Trigger:** launch with a stalled network mount. `readPlaces()` (`mountedVolumeURLs` plus per-volume `resourceValues`, line 733-735) hangs, and each of those main-thread calls freezes the UI for a full second, indefinitely.
- **Related:** even on a healthy machine the first call at launch blocks main until the read is done, against the protocol's "must answer at once". If `readPlaces` hangs, `isReadingPlaces` stays true forever and the list never refreshes again.
- **Fix:** never wait in `places()`; return `fixedPlaces()` until the first read lands and announce the result (see finding 3). Give the reader a watchdog that clears `isReadingPlaces`, and read volumes individually so one bad volume does not hold up the rest.
- **Confidence:** confirmed by reading; that `mountedVolumeURLs` hangs on a dead mount is plausible.

### 3. MEDIUM — correctness — `LocalFileSystem/LocalFileSystem.swift:16-19,692-713`
- **What:** nothing tells clients when the places list has been re-read. `DriveBarView` rebuilds on the same NSWorkspace mount notification that only starts the provider's background refresh, so it gets the old list.
- **Trigger:** plug in a disk. The drive bar does not show it until some later rebuild; after an unmount the stale button stays.
- **Fix:** post a `placesDidChange` notification on main when `knownPlaces` actually changes, and have the bar observe that instead of NSWorkspace.
- **Confidence:** confirmed by reading; not run, as it would need mounting a volume.

### 4. MEDIUM — performance — `LocalFileSystem/DirectoryWatcher.swift:40-54,96-98`
- **What:** there is no coalescing on the client side. Each FSEvents callback becomes one `queue.async` to main, and under load FSEvents flushes far more often than the 0.5 s latency.
- **Measured:** four writers creating and deleting files in the watched folder gave 2,696 main-thread `onChange` calls in 6 s (about 450 per second). Flooding only a sub-sub-folder still gave 115 calls in 6 s, because `MustScanSubDirs` marks every watched folder as changed.
- **Trigger:** a build or `npm install` anywhere below a folder a panel shows keeps the panel re-listing continuously. The shell serialises reloads, so they do not pile up, but they never stop.
- **Also:** because streams are recursive, watching `~` or `/` bridges every event path in the subtree to a Swift `String` on the utility queue.
- **Fix:** keep a pending set in `Watch` and deliver at most one report per interval (trailing-edge timer, 0.3–1 s, longer after `MustScanSubDirs`). Consider `kFSEventStreamCreateFlagIgnoreSelf`.
- **Confidence:** confirmed (measured).

### 5. MEDIUM — freeze — `FolderTabs/FolderTabsPlugin.swift:412-426,259-285`
- **What:** a loaded tab file has no limit on the number of tabs. A 1 MiB file parses to 81,512 tabs (measured, 0.09 s), and `restore` then calls `insertTab` once per tab on main, each firing `onChange` → `tabsChanged`, which does work proportional to the tab count.
- **Trigger:** the user loads a crafted or corrupt `.tab` file. The work is O(n²) on main, and `replace` adds a `firstIndex` plus `closeTab` per old tab; the app hangs.
- **Fix:** cap tabs per side (a few hundred) and caption length. Add a batch insert to `PanelTabs` that fires `onChange` once.
- **Confidence:** parse count confirmed; O(n²) UI cost confirmed by reading, not timed.

### 6. MEDIUM — freeze — `LocalFileSystem/LocalFileSystem.swift:370` and `:334-335`
- **What:** `append` opens with `O_WRONLY` and no `O_NONBLOCK`, and only checks `S_IFREG` after the open. On a FIFO with no reader the open blocks forever and cannot be cancelled. `read()` has the same problem through `FileHandle(forReadingFrom:)`.
- **Trigger:** Resume/Append onto a destination name that is a FIFO or a link to one, or view/stream-copy a FIFO where the caller's `isSpecial` check raced. The job thread hangs.
- **Related:** `copyMetadata(from: plain, to: fifo)` also blocked in the experiment (`copyfile` opening the destination, line 597); treat that as indicative, because the FIFO still had a reader thread blocked on it from the earlier cases in the same run.
- **Fix:** open with `O_NONBLOCK | O_CLOEXEC`, `fstat`, reject non-regular files, then clear `O_NONBLOCK` with `fcntl`. In `copyMetadata`, refuse when the destination's `lstat` says it is neither regular, directory nor link.
- **Confidence:** append confirmed; read inferred from POSIX FIFO semantics, not cleanly isolated by the test; copyMetadata observed once under the caveat above.

### 7. MEDIUM — freeze/threading — `LocalFileSystem/LocalFileSystem.swift:105,249,316,269,301`
- **What:** every symlink in a listing gets a following `stat()`, and every dotted folder gets `resourceValues` or `getattrlist`, on the listing thread or inside `Parallel.map` workers. None of this can be cancelled.
- **Trigger:** a local folder (such as `~`) contains a link into a dead share or an autofs path. The listing of that local folder never completes; the flag is only looked at between buffers. Each stuck call also pins a `ParallelPool` thread for good (the pool is capped at four times its width).
- **Fix:** do not resolve link targets inline. Deliver links unresolved and resolve them lazily, or on a separate bounded queue with a deadline. At minimum skip resolution on non-local volumes (`statfs` `f_flags` of the directory) and check the flag per entry.
- **Confidence:** plausible (code path certain, hang not simulated).

### 8. MEDIUM — correctness (lock bypass) — `LocalFileSystem/LocalFileSystem.swift:472-498,565,617`
- **What:** `lockedCopies` also records copies that keep their final name: every locked destination of `copy()` and every locked item touched by `copyMetadata`, folders included. Nothing ever forgets them.
- **Effect:** for the rest of the session `remove()` and `move()` silently unlock and delete or rename those user-locked files, with no "this item is locked" step.
- **Confirmed:** copy of a `uchg` file followed by `remove(dst)` succeeded; `copyMetadata` onto a folder followed by `move` succeeded.
- **Second problem:** at 4,096 entries the table is wiped (`removeAll`, line 478), which also drops entries for in-flight temporary files of other workers. Their rename then fails with EPERM and `remove` fails too. `FileJob.discard` (`FileOperations/FileJob.swift:738`) retries after unlocking via `setAttributes`, so cleanup still works, but the item fails.
- **Fix:** make the allowance explicit and scoped. For example `copy` returns a token, or the caller passes `allowLocked` to the single rename/remove of its own temp; or the entry expires on first use and after a short TTL. Never bulk-clear; evict the oldest.
- **Confidence:** bypass confirmed; wipe race plausible.

### 9. MEDIUM — security — `LocalFileSystem/LocalFileSystem.swift:359,405-411`
- **What:** `write()` creates files with mode 0644 (confirmed), and the source's permissions are applied only at `close`, by path. `FileManager.setAttributes(ofItemAtPath:)` follows symlinks.
- **Trigger (exposure):** stream-copying a 0600 file (archive or server to disk, or a followed link) leaves its content world-readable in the destination folder for the whole transfer, and permanently if the transfer fails with partial files kept.
- **Trigger (race):** in a shared-writable destination, swapping the just-closed temp for a symlink makes the chmod/utimes land on another file of the user.
- **Fix:** `open(..., 0o600)`, then `fchmod`/`futimens` on the descriptor before closing it; add `O_CLOEXEC`.
- **Confidence:** mode confirmed; race plausible.

### 10. MEDIUM — correctness — `LocalFileSystem/LocalFileSystem.swift:572-584`
- **What:** `setAttributes` examines and unlocks the link itself (`lstat`/`lchflags`) but then changes mode and date through `fm.setAttributes`, which follows the link.
- **Confirmed:** calling it on a symlink changed the target's mode to 777 and its mtime.
- **Trigger:** Change Attributes on a selection containing links, or a job carrying attributes onto a copied link, alters files outside the tree being worked on.
- **Also:** the unlock is not rolled back if the later step fails.
- **Fix:** use `fchmodat(AT_SYMLINK_NOFOLLOW)` and `utimensat(AT_SYMLINK_NOFOLLOW)`, or `setattrlist` with `FSOPT_NOFOLLOW`. Decide explicitly whether links are skipped.
- **Confidence:** confirmed.

### 11. LOW–MEDIUM — freeze — `ViewOptions/ViewOptionsPlugin.swift:200` and `:150-158`
- **What (sort):** when the list changed while a background sort ran, the fallback is `model.setSort(order)`, a synchronous sort on main. I measured 0.5 s for one million entries, on top of the model's filter and index work. With a busy folder (finding 4 bumps `listVersion` constantly, as do computed sizes at `AFMKernel/Panels/PanelModel.swift:705`) the stale path is the normal path.
- **What (filters):** `apply` always calls the synchronous `model.setFilter`, about 0.2 s of single-threaded matching per million entries on main. The kernel's off-thread `PanelModel.filtered` / `setFilter(_:prefiltered:listVersion:)` path is not used.
- **Fix:** on a stale result, re-dispatch the sort with the new snapshot (a loop keyed by `pendingOrders`). Route filters through the prefiltered path above the same threshold.
- **Confidence:** confirmed (timings measured, paths read).

### 12. LOW — correctness — `ViewOptions/ViewOptionsPlugin.swift:198-200`
- **What:** a sort set by another route while a background sort is pending is overwritten when the background result lands. `pendingOrders[id] == order` still holds, so `setSort(order)` runs.
- **Trigger:** a header click, or tab restore in `FolderTabsPlugin.swift:266`, during a pending background sort.
- **Fix:** if `model.sort != from`, drop the result.
- **Confidence:** plausible.

### 13. LOW — security/correctness — `FolderTabs/TabFile.swift:34-47`
- **What:** values are written unescaped. A folder name or tab caption containing a newline injects lines.
- **Confirmed:** a tab at `/tmp/a\n0_path=sftp://evil.example/` with caption `t\n1_path=/etc` reads back as tabs `sftp://evil.example` and `/etc`.
- **Trigger:** a folder with such a name arrives in an extracted archive; the user saves tabs while in it and loads them later.
- **Also:** leading and trailing spaces in a path do not round-trip, because lines are trimmed.
- **Fix:** refuse or escape CR/LF in paths and captions on write; do not trim the value side.
- **Confidence:** confirmed.

### 14. LOW — correctness — `FolderTabs/TabFile.swift:55-58`
- **What:** a UTF-8 BOM makes the first section header unrecognised. `TabFile(text: "\u{FEFF}[activetabs]…")` returns nil (confirmed), so the user sees "The file holds no tabs". UTF-16 files, which Windows tools write, fail the same way through the lossy decode at `FolderTabsPlugin.swift:410`.
- **Fix:** strip the BOM; detect UTF-16 by its BOM.
- **Confidence:** confirmed.

### 15. LOW — security — `FolderTabs/FolderTabsPlugin.swift:417`
- **What:** tab paths are read with `fileSystems.location(from:)`, so a tab file can name any scheme or path (`sftp://host/…`, `/net/host/…`). The active tab of each side is opened immediately.
- **Trigger:** loading an untrusted `.tab` file makes the app connect to a host of the file's choosing or trigger automounts.
- **Fix:** ask for confirmation when a loaded file contains non-local locations.
- **Confidence:** plausible (depends on what the Network plugin does without a prompt).

### 16. LOW — correctness — `LocalFileSystem/LocalFileSystem.swift:439`
- **What:** `move(..., replacing: true)` between two hard links of the same file returns success while the source still exists (confirmed; `rename(2)` is a no-op there). A Move job reports success and nothing moved.
- **Fix:** when replacing, compare dev/ino of both names and `unlink` the source if they match.
- **Confidence:** confirmed.

### 17. LOW — correctness/freeze — `LocalFileSystem/LocalFileSystem.swift:506-511`
- **What:** `copy()` hands anything that is not a regular file to `fm.copyItem`. If a caller passes a directory, the whole tree is copied with no progress and no cancellation (confirmed: zero progress calls). The contract says "one file or link", but nothing enforces it.
- **Fix:** allow only `S_IFLNK` (via `symlink`/`copyfile` with NOFOLLOW) and throw for directories and special files.
- **Confidence:** confirmed.

### 18. LOW — correctness — `LocalFileSystem/LocalFileSystem.swift:353-355`
- **What:** `createDirectory` succeeds silently when the directory already exists, or when the name is a symlink to a directory (both confirmed). Callers cannot tell "created" from "was there", and a tree copy writes through a pre-existing link.
- **Fix:** `mkdir` the leaf yourself and report EEXIST; let the caller decide about merging; `lstat` the leaf.
- **Confidence:** confirmed.

### 19. LOW — correctness — `LocalFileSystem/LocalFileSystem.swift:238-245` versus `:99-101`
- **What:** an entry whose attributes failed in bulk and whose `lstat` also fails (deleted meanwhile) is still delivered by the full listing, as a zero-byte 1970 non-file. The lean `entries(of:)` drops it.
- **Fix:** drop it in both.
- **Confidence:** plausible.

### 20. LOW — correctness — `LocalFileSystem/LocalFileSystem.swift:150,892`
- **What:** `String(cString:)` repairs invalid UTF-8 in names with U+FFFD. On volumes that allow such names (NFS, some FUSE) the item's URL then names a file that does not exist, so open/copy/delete fail with ENOENT.
- **Fix:** detect the repair and either keep the raw bytes (percent-encoded URL built from bytes) or mark the item unreadable.
- **Confidence:** plausible.

### 21. LOW — performance — `LocalFileSystem/LocalFileSystem.swift:873-914`
- **What:** `totalSize` checks the flag only once per directory, not per buffer; a million-entry folder is read to the end after Cancel.
- **Also:** `copy` does not pass `COPYFILE_DATA_SPARSE`, so a cross-volume copy of a sparse image is written out in full and can fill the target disk.
- **Confidence:** confirmed by reading.

### 22. LOW — correctness — `LocalFileSystem/LocalFileSystem.swift:777,797-811`
- **What:** `spareSpace` is keyed by mount-point path and only dropped when a re-measure fails. After eject and re-mount of a different volume at the same path (`/Volumes/Untitled`), the old spare figure is added to the new volume's free space until the next measurement (3 s or more).
- **Fix:** key by `f_fsid`, or store it and compare.
- **Confidence:** plausible.

### 23. LOW — correctness — `LocalFileSystem/DirectoryWatcher.swift:77,97-98`
- **What:** if `FSEventStreamCreate` fails, `watched` is already set, so a later `watch()` with the same folders returns early and never retries.
- **Fix:** set `watched` only after a successful start.
- **Confidence:** confirmed by reading.

### 24. LOW — leak/robustness — `LocalFileSystem/LocalFileSystem.swift:68,180,359,370,860`
- **What:** no raw `open` uses `O_CLOEXEC`. No syscall retries EINTR (`open` on interruptible NFS, `getattrlistbulk`, `ftruncate`).
- **Confidence:** confirmed by reading.

### 25. LOW — freeze — `LocalFileSystem/LocalFileSystem.swift:68,180,860`
- **What:** listing a dataless iCloud or File Provider directory materialises it and blocks until the provider answers, with no timeout. A `totalSize` over iCloud Drive materialises every folder. File contents are never downloaded, since nothing opens files.
- **Fix:** consider `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, …OFF)` for size and tree walks, and surface EDEADLK as "not downloaded".
- **Confidence:** plausible.

### 26. LOW — freeze — `Navigation/NavigationPlugin.swift:133`
- **What:** `pasteboard.string(forType:)` runs on main. A lazily provided or very large clipboard blocks for as long as the owning app takes.
- **Confidence:** plausible.

## Blocking calls that can hang on a dead mount

| Call (line in `LocalFileSystem.swift` unless noted) | Reaching thread | Timeout or cancel |
|---|---|---|
| `realpath`, `FSEventStreamCreate` (`DirectoryWatcher.swift:117,97`) | **main** | none (finding 1) |
| `places()` condition wait (675) | **main** | 1 s per call, repeated (finding 2) |
| `mountedVolumeURLs`, `resourceValues`, `fileExists` in `readPlaces` (730-735) | global queue | none; stuck forever blocks refresh |
| `open` + `getattrlistbulk` (68/81, 180/197, 860/874) | listing, job and pool threads | flag checked between buffers only (not at all inside `totalSize`'s loop) |
| `stat`/`lstat` per link or failed entry (100, 105, 249, 308, 316, 908) | listing and pool threads | none |
| `resourceValues(.isPackage)`, `getattrlist` (269, 301) | listing and pool threads | none |
| `contentsOfDirectory` fallback (53) | listing thread | none |
| `fileExists` loop, `resourceValues`, `statfs` in `volume(of:)` (756-761) | listing thread (`AFMKernel/Panels/Listing.swift:81`), utility queue, jobs | none |
| `measureSpareSpace` (819) | utility queue | none; `isMeasuring` stays set |
| `FileHandle` open/read/write/close; `open`/`fstat`/`ftruncate`/`lseek` in `append` | job threads | no `interrupt()` on Reader or Writer; `append` checks the flag once |
| `copyfile` (539, 597), `fm.copyItem` (508) | job threads | progress callback between chunks only; none for metadata or `copyItem` |
| `rename`/`renamex_np`, `unlink`/`rmdir`, `lchflags`, `setxattr`/`getxattr`, `setattrlist`, `fm.setAttributes`, `trashItem`, `createDirectory` | job threads | none |

Apart from the first two rows, I found no main-thread path into blocking storage calls within my scope. Navigation, ViewOptions and FolderTabs do their storage work in jobs.

## Shared mutable state

| State | Protection | Verdict |
|---|---|---|
| `knownPlaces`, `placesRead`, `isReadingPlaces`, `placesChangedMeanwhile` | `placesCondition` | Locking correct; wait policy wrong (finding 2) |
| `mountObservers` | written in `init`, read in `deinit` | Fine |
| `packageExtensions` | `packageLock`, never held across syscalls | Sufficient; benign duplicate asks |
| `lockedCopies` | `lockedLock` | Lock sufficient; table semantics wrong (finding 8); small `lstat`→`lchflags` window in `unlockOwnCopy` |
| `spareSpace` | `spareLock`, released around measuring | Sufficient; first-question race only duplicates a 15 ms measure; stale key (finding 22) |
| `DirectoryWatcher.stream/watch/watched` | unsynchronised, single owner | Fine while each watcher has one owner |
| `Watch.stopped` | `NSLock` | Sufficient |
| `Watch` lifetime | retained by the stream's context | Sound (see below) |
| ViewOptions `applied`, `pendingOrders`; FolderTabs `closedTabs` | main thread only | Fine; `ObjectIdentifier` reuse is guarded by the weak-model check, or by the closure retaining the model |
| `copy`'s `Progress` object | used only on the copying thread | Fine |

## Checked and found sound

- **Bulk parse:** attribute order, the error word after the returned set, name offset relative to its reference, unaligned loads, and optional fields driven by the returned set are all correct. Lengths are trusted from the kernel.
- **Parallel item building:** order is preserved, the entry buffer is read-only, and each piece has its own URL.
- **Lean `totalSize`:** links are not followed, the descriptor is closed before recursing, and a 480-level tree ran on a 512 KB-stack thread without overflow.
- **Watcher teardown:** 3,000 start/stop cycles under an event flood gave no crash and zero client calls after `stop`. All 1,000 `Watch` states were freed in an instrumented copy. Clients are called on the requested queue (main for the provider).
- **Stream count:** one stream per provider for both panels' active folders. Unmount and rename of the watched folder are covered by `WatchRoot` → `RootChanged`.
- **`copy`:** `COPYFILE_CLONE` implies `NOFOLLOW_SRC` and EXCL per the man page; a link source is cloned as a link (tested). After a cancelled block copy, `copyfile` removes the destination itself and the descriptor stays valid until `copyfile_state_free`, so the dev/ino-guarded cleanup never removes a foreign file (tested). EEXIST is returned before any cleanup.
- **`move`:** `RENAME_EXCL` is atomic; a case-only rename with `replacing: false` works on APFS (tested); the ENOTSUP fallback's case-only problem is handled by the caller (`FileOperations/FileOperationsPlugin.swift:398-403`).
- **`write`:** `O_EXCL` never opens an existing file or follows a final link.
- **`append`:** every error path closes the descriptor.
- **`remove`:** never follows links.
- **Quarantine, creation-date and flag calls:** all use NOFOLLOW variants.
- **Volume refresh:** no notification loop (a notification makes clients ask, but within 3 s nothing re-measures); a vanished volume drops its entry; no retain cycle.
- **Tab save:** done in a job, temp file plus rename, overwrite confirmed, temp removed on failure. Load is capped at 1 MiB, refuses directories and special files, and tolerates CRLF.
- **Background sort:** double clicks and reverse-twice resolve correctly; a tab closed meanwhile is harmless.

## Not reviewed or not verified

- Real stalled network mounts, iCloud dataless folders, and volumes without bulk reads or `RENAME_EXCL` (exFAT, SMB). An SMB share is mounted on this machine; I did not touch it.
- `copyfile` behaviour when metadata cannot be stored on the target (FAT/SMB): whether it returns -1, which would make `copy()` delete an otherwise complete file.
- The 4,096-entry wipe race and the `lstat`→`lchflags` swap in `unlockOwnCopy` were reasoned about, not reproduced.
- `FSEventStreamInvalidate` semantics come from stress testing, not from source.
- `fm.trashItem` on volumes without a Trash; ACL inheritance on copies.
- Whether the shell's `tabsChanged` cost is exactly O(n) per call (read only in part).
