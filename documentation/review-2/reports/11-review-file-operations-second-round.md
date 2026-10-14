# Review file operations second round

# Second-round review: FileOperations, Clipboard, FileProperties, MacIntegration

I read every file in scope in full, plus the kernel provider protocol, `CancellationFlag`, `Parallel`, `LocalFileSystem`, `ProgressJobService` and the relevant parts of `VirtualFolders`. No project file was modified.

"Confirmed" means either reproduced or established by reading the code path; findings 1, 2, 3, 4, 5, 8 and 21 were reproduced in a throwaway package built from copies of the sources at `/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/fileops/exp` (cases `t1`–`t8` and `tsan` in `Sources/Exp/main.swift`). A ThreadSanitizer run of a parallel copy with verify, a filtered move and a parallel delete with the log on reported no race.

## Findings

### 1. CRITICAL — data-loss — a Move whose destination is a `vfolder:` URL deletes the file it just "moved" (confirmed: t1, t6, t1b)

- **Where:** `FileJob.swift:586-596` (`plan`), `708-735` (`put`), `536-544` (source removal), `959-987` (`transferFolder`), `362-369` (`targetsSourceFolder`), `1583-1639` (`FileIdentity`); `ClipboardPlugin.swift:140-154`; `FileOperationsPlugin.swift:223-257`, `418-449`.
- **What is wrong:** In a branch view the items have real `file:` URLs but `model.directory` is `vfolder://branch…`. Relative targets, Paste and the multi-rename build destinations in the `vfolder:` scheme. Then:
  - `isSameLocation` is false (different schemes).
  - `entry(at: destination)` returns the real item, so `FileIdentity.sameEntry` is true and `plan` returns `.write(destination, replacing: true)` without a question, assuming `put` will rename.
  - `put` renames only when `from === to`. Local is not the virtual provider, so it stream-copies to a temp, renames the temp over the destination (which is the source), returns `isMove`, and the worker then runs `remove(item.url)` on that same file.
- **Triggers:**
  - Branch view, Cmd+X on a top-level file, Cmd+V in the same panel: the file is gone, with no prompt (t6: `asked: [] completed: 1 dir now: []`). The Clipboard "same folder" filter at line 149 compares `file:` with `vfolder:` and lets it through.
  - Branch view, F6, type the same name in another letter case: same result (t1).
  - By reading: with folders listed, the same on a folder merges it "into itself" and then deletes every file and the folder.
- **Related damage, same root cause:**
  - Every rename by F6 with a plain name, Shift+F6 with several items (`TargetSpec(directory: directory, …)` at line 448) and Shift+F5 in a branch view is a stream copy plus delete. t1b showed a new inode and the extended attributes lost; a large file is copied in full.
  - `destination.isInside(source)` and `FileIdentity.isInside` are also blind here, so "into own subfolder" is not detected.
- **Fix:**
  - Resolve a virtual directory to its real one before building any `TargetSpec` (`VirtualLocation.realDirectory`), in `FileOperations.transfer`, `renameSelection`, the transfer service and Clipboard paste.
  - In `FileJob`, never remove a source unless the destination is proven to be a different entry. If `sameEntry` was the reason for `replacing: true` and `from !== to`, refuse.
  - Make `FileIdentity` compare what `entry(at:)` returned, and re-check identity immediately before the source removal.
  - `ArchiveFileSystem` also has "outside" URLs that alias local files; check the same class there.

### 2. HIGH — freeze — a named pipe in a streamed transfer hangs the job; Cancel has no effect and the app cannot quit (confirmed: t3b)

- **Where:** `FileJob.swift:776`, `842`, `852`, `879`, `914`; `Checksum.swift:15`; `JobBridge.swift:96`.
- **What is wrong:** `FileItem.isSpecial` exists for this and FileJob never looks at it. Any streamed path opens the source with `provider.read`, and for a FIFO `open()` blocks for good. The local reader has no `interrupt`. Affected paths: local to archive or server, followed links, Append/Resume, and "Compare contents" in the Overwrite dialog (which also holds `decisions`).
- **Trigger:** copy a folder containing a FIFO into a zip or to FTP. t3b: still running 4 s after cancel. `isBusy` stays true, every file command stays blocked, and `Shell.swift:105` waits for `cancelAll` forever, so quitting needs a force quit. (Local-to-local copy and verify of a FIFO does not hang; `copyItem` fails cleanly.)
- **Fix:** skip or report `isSpecial` items in `transfer`, `verify`, `extend` and compare; open with `O_NONBLOCK` and `fstat` in the local reader.

### 3. HIGH — data-loss — several sources that land on one target name destroy each other under "Overwrite all" (confirmed: t5)

- **Where:** `FileJob.swift:498-503`, `586-622`, `644-646`.
- **What is wrong:** `claimed` only serialises the workers. Afterwards the earlier file of this same job is treated as any existing file.
- **Trigger:** Move of `a.doc`, `a.pdf`, `a.rtf` with mask `*.txt` and Overwrite all: one `a.txt` remains, sources are empty, `completed: 3`. By reading, the same applies to:
  - a branch view or search result with equally named files from different subfolders;
  - `File.txt` and `file.txt` from a case-sensitive source to a case-insensitive target;
  - NFC/NFD twins;
  - "Overwrite older" (the second file is newer than the copy of the first).
- **Fix:** remember per target folder the folded names this job produced; a collision with the job's own output always asks, or auto-renames, whatever the mode.

### 4. MEDIUM — correctness — F5/F6 towards a panel in branch view creates a real folder named "dir (branch)" (confirmed: t8)

- **Where:** `FileOperationsPlugin.swift:234-235`, `263`; `TargetSpec.swift:124-128`.
- **What is wrong:** the proposal is `displayPath(target) + "/" + name`. Only the bare display path reads back as the virtual folder; with a suffix it is a plain file path. `makeJob` then silently creates that folder and transfers into it.
- **Fix:** propose the real directory of a virtual target, or refuse a list as target.

### 5. MEDIUM — data-loss — Resume on a target that is a symlink truncates and overwrites the file the link points to (confirmed: t4)

- **Where:** `FileJob.swift:616-618`, `830-832`, `876-886`.
- **What is wrong:** a link has size 0, so Resume is offered and passes `existing.size < item.size`. `startsWithPartial` with length 0 is trivially true. `append(to:at: 0)` opens through the link and cuts the target.
- **Also:** the rewrite path at `837-862` (file systems without `.append`) has no prefix check at all unless Verify is on.
- **Fix:** no Resume or Append when `existing.isSymlink` or `isSpecial`; `O_NOFOLLOW` in `append`; do the last-block check in both paths.

### 6. MEDIUM — data-loss — the 2-second tolerance applies to every volume (confirmed by reading)

- **Where:** `FileJob.swift:647-648`, `653`, `658-664`.
- **What is wrong:**
  - "Overwrite all older" skips a source that is genuinely newer by up to 2 s (save, copy, save again, copy again loses the update in the copy).
  - "Overwrite older and same age" overwrites a target that is newer by up to 2 s.
- **Fix:** apply the tolerance only where a side has coarse timestamps (FAT, exFAT, non-local, or a whole even second); compare exactly on APFS.

### 7. MEDIUM — data-loss — Delete and Move descend through mount points (plausible; read from the code, not run)

- **Where:** `FileJob.swift:1222-1245`, `1270-1288`.
- **What is wrong:** there is no `st_dev` comparison. A folder containing a mounted disk image or share has the contents of that volume deleted one by one.
- **Fix:** stop at a device change and ask.

### 8. MEDIUM — correctness — "follow links" cycle detection is textual only (confirmed: t2)

- **Where:** `FileJob.swift:1108-1119`, `1558-1565`.
- **What is wrong:** a link to a directory outside the tree that contains a link back to itself (`Y/m -> .`) is not seen as a cycle.
- **Trigger:** t2 produced 34 nested levels of copies before the kernel's link limit stopped it. With two such links the walk branches at every level, in the count before the job as well.
- **Fix:** compare the resolved target against the resolved ancestors, or keep a set of visited `(dev, ino)`.

### 9. MEDIUM — freeze — job-thread provider calls that cannot be cancelled (plausible)

- **Where:** `FileJob.swift:540`, `1002`, `1043`, `1173`, `1255`, `745`, `1059-1064`.
- **What is wrong:** `remove`, `move`, `createDirectory`, `setAttributes`, `copyMetadata` and `quarantine` have no cancellable variant. A stalled server or share holds `run()` until the provider times out, with the same quit consequence as finding 2.
- **Also:** `makePool` (`450-453`) looks only at the first source's folder, so a search result that starts on the SSD puts pool workers on slow volumes too.
- **Fix:** cancellable variants or time limits; check every source folder in `makePool`.

### 10. MEDIUM — correctness — "keep partial files" makes Retry impossible (confirmed by reading)

- **Where:** `FileJob.swift:725-733`.
- **What is wrong:** after a failed stream the partial takes the real name. Retry copies in full and then fails its exclusive rename with "already exists", and the complete copy is discarded.
- **Fix:** on Retry treat the kept partial as replaceable (or resume it), or keep it under a recognisable name.

### 11. MEDIUM — security/correctness — typing `755` over a prefilled `4755` keeps set-user-ID (confirmed by reading)

- **Where:** `AttributeChange.swift:30-31`, `87`; `FilePropertiesPlugin.swift:418-419`, `493`.
- **What is wrong:** three digits mean "keep special bits", so the dialog cannot clear setuid unless the user types `0755`.
- **Same logic, other edge:** a single folder with Recurse ticked and the prefilled mode left alone changes nothing and returns silently (`change.isEmpty`, line 180).
- **Fix:** when the prefilled text had four digits, read three as absolute; when Recurse is ticked and the field is untouched, ask or say so.

### 12. LOW — threading/freeze — Pause details

- **Where:** `FileJob.swift:1440-1443`, `1470-1480`, `811-818`, `1164-1178`, `1409`.
- **What is wrong:**
  - A paused thread sits in the gate holding `counters`. Every other worker stops at its next counter update with its reader and writer open, for as long as the pause lasts (server connections time out, then error dialogs).
  - Pause is not honoured while deferred sources are removed or during `commit`.
  - Abort chosen in a dialog that opened just after Pause sets `stop`, but the gate watches only `cancellation`; the job stays "Paused" until Resume.
- **Fix:** report progress outside `counters` (snapshot under the lock, call the delegate after); let Abort open the gate.

### 13. LOW — security — residual check-then-use races on paths

- **Where:** `FileJob.swift:1222-1259`; `AttributeChange.swift:334-343`.
- **What is wrong:** a folder swapped for a symlink between listing and use leads Delete, or the source removal of a Move, into the link's target. Recursive chmod and date changes follow a link put in place after the listing.
- **Fix:** `openat`/`unlinkat`/`fchmodat` with no-follow in the local provider.

### 14. LOW — security — untrusted names and modes

- `FileJob.swift:412`: top-level source names are not passed through `isSafeName`; a provider entry named `..` would merge into the target's parent (plausible; depends on the providers).
- `FileJob.swift:807-809`: streamed permissions are applied unmasked, including setuid and world-writable bits from an archive or server (plausible).
- `FileJob.swift:789`, `860`, `897`, `1063-1064`: `setQuarantine` failures are ignored, and for folders it runs after `copyMetadata`, which may have locked the folder.
- `FileJob.swift:1071-1078`: `RemoteFileSystem` has no `quarantine(of:)`, so downloads carry no mark while the general opener starts anything.
- `NameTemplate.swift:180-183` with `FileOperationsPlugin.swift:515`: `[X]` keeps `/`, `..` and `~` from the clipboard.

### 15. LOW — correctness — OperationLog

- `OperationLog.swift:114-121`: names and error texts go in raw; a newline in a file name forges log lines. Escape control characters.
- `170-176`: the handle is not `O_APPEND`; an external truncation leaves a hole of NULs, and a second writer is overwritten.
- `143-148`: after one rotation in a burst, `size` is 0 and no further rotation happens in that burst.
- By reading: concurrency, flush at quit and pruning are sound. The size-rotation and prune path ran clean in the `tsan` case.

### 16. LOW — freeze/correctness — descript.ion

- `Descript.swift:217`, `235`; `PropertyDetails.swift:124`: a FIFO, or a link to one, named `descript.ion` blocks the Comment column threads and hangs the Properties and Edit Comment jobs (plausible; same class as finding 2).
- `Descript.swift:68-78`, `127`: names containing `"` or a line break are written unescaped and read back as other entries.
- `275-280`: a symlinked or hidden comment file is replaced by a plain, possibly unhidden one.
- By reading: the size cap, strict decoding, atomic replace and read-once condition are sound.

### 17. LOW — freeze — main-thread calls

- `ClipboardPlugin.swift:169-175` (from `paste`, line 143) and `FileOperationsPlugin.swift:480`: `pasteboard.data` and `string` on the main thread; a large or lazily provided item waits for the other application.
- `MacIntegrationPlugin.swift:62-70`, `152`: `urlsForApplications(toOpen:)` on the main thread.
- `161-162`: `activateFileViewerSelecting` with a large selection.
- `172-175`: with Quick Look open, every cursor move builds the whole operand list.

### 18. LOW — correctness — attribute changes

- `AttributeChange.swift:337`, `340`: symbolic modes and partial dates start from the listed (possibly stale) values, not the file's current ones.
- `343`: any mode containing owner-write silently unlocks a Finder-locked file through the provider, even with "Locked: Unchanged".
- `FilePropertiesPlugin.swift:435`: a symbolic mode passed as a parameter is dropped when the dialog is shown.

### 19. LOW — performance

- `FileJob.swift:377/1532`, `418`, `590`: each top-level source is looked up three times; on servers that is three round trips per selected file although the panel already had the items.
- `1027`: two display strings and two URL appends per child even when the report is throttled.
- `1431-1434`: record strings are built before the log's filter.
- `206-214`: the measure cache can hold 100,000 long keys, which is tens of megabytes rather than "a few".
- `1128-1130`: `isKept` is linear with a key built per element.

### 20. LOW — leak/correctness — smaller items

- `FileJob.swift:740-748`: `.afm-<uuid>.tmp` files stay forever when `discard` fails or the app dies.
- `539-542`: the source removal of a cross-volume move does not use the unlock route, so each locked file errors.
- `837-862`: Append rewrites the target as a new file, losing its extended attributes, ACL and creation date.
- `1360-1371`: any EPERM counts as "locked" and adds owner-write to the file even when the retry fails.
- `ClipboardPlugin.swift:192-194`: a failed paste-as-file leaves a partial `Clipboard.txt`.
- `FileOperationsPlugin.swift:446-456`: "Overwrite all" does not carry across the per-item jobs of a multi-rename.

### 21. Answers to the specific questions asked

- **Cut then paste:** the source is removed only after the destination has its real name, except in finding 1.
- **Deferred-writes Move:** nothing is removed before a successful `commit`; a failed or cancelled commit keeps all pending sources and their parents; partial batches are sound.
- **Folder ordering:** create, children settled, `setAttributes`, `copyMetadata`, quarantine, source `rmdir` (only if empty) is correct.
- **Skip All / Overwrite All between workers:** serialised under `decisions`.
- **Exceptions in pool work:** only `Cancelled` can escape; both pools are waited for on every exit path.
- **Parallel delete:** symlinks are never followed, and unsafe names are rejected and keep the parent.
- **Save Details:** the write is atomic (draft plus rename, after asking).

## Shared mutable state in scope

| State | Protection | Sufficient? |
|---|---|---|
| `mode`, `skipAllErrors`, `deleteAllNonEmpty`, `mergeAll`, `confirmedForAll` | `decisions`, which is also held while a dialog is open | Yes; one question at a time, no nesting with other locks |
| `done`, `total`, `inFlightBytes`, `currentLines`, `lastReport`, `failures`, `createdFolders`, `Flight.bytes` | `counters` | Yes for races; held across Pause (finding 12) |
| `measures` | `remembered` | Yes |
| `deferred`, `kept` | `pendingRemovals` | Yes |
| `Batch.outcomes`, `cancelled` | the batch's own lock | Yes |
| `Batch.claimed`, `staysOnVolume`, `origins`, `predictedRenames` | job thread only | Yes (checked every caller) |
| `Tally` in the delete pool | its own lock | Yes |
| `pool`, `deletePool`, `defersRemovals`, `options` | set before any worker starts | Yes |
| `StorageMedium.known`, `LocalInfo` name caches | static locks | Yes |
| `OperationLog` pending lines and handle | serial queue | Yes |
| `CommentStore.remembered`, `beingRead` | `NSCondition`, broadcast under the lock | Yes |
| `ProgressMeter`, `AttributeJob.outcome` | their own locks | Yes; the meter also holds its lock across Pause, by design |
| Clipboard `cutChangeCount`, MacIntegration `opened`/`log`, Quick Look state | main thread only | Yes |

Lock order: `decisions`, `counters` and the leaf locks are never nested with each other. The main thread takes none of them. `Pool.drain()` and the semaphores have a single waiter. I found no inversion or lost wake-up.

## Not reviewed

- The internals of the Archives and Network providers (their `remove`, `move` and `commit` semantics, and how they sanitise listed names) beyond the calls FileJob makes.
- The shell's dialogs and progress window beyond `ProgressJobService`.
- Behaviour on case-sensitive, FAT/exFAT, SMB or spinning volumes, and a real full disk; everything ran on local APFS.
- The existing test suite was not run.
