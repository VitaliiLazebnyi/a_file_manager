# Review 2 — localfs

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### L001 [finding, critical] realpath() on main for every watched panel directory (blocking call)

**Outcome:** fixed — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/DirectoryWatcher.swift:76,117,100; AFMShell/Window/PanelCoordinator.swift:171-179;
  Plugins/LocalFileSystem/LocalFileSystem.swift:840; Plugins/VirtualFolders/VirtualFileSystem.swift:441-470
- **Basis:** read (reported as confirmed)
- **Detail:** Path: PanelCoordinator.panelDidChangeLocation -> updateWatchers() -> LocalFileSystem.watch ->
  DirectoryWatcher.watch -> resolve -> realpath. FSEventStreamCreate with WatchRoot at :100 also opens the path.
  Trigger: either panel shows a folder on a stalled SMB/NFS/AFP mount and either panel then changes location; every
  panel directory is re-resolved, so navigating the healthy panel also hangs. Duration: the mount timeout, 30-600 s.
  Second route: VirtualFileSystem.watch forwards up to 512 real folders, so up to 512 realpath calls on main.
- **Proposed fix:** Create and replace the stream on the watcher's own queue, and return the handle at once. Skip
  watching when model.volume?.isLocal == false.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### L002 [finding, critical] B1: realpath() on main for every watched panel folder hangs the app on a stalled mount

**Outcome:** duplicate of L001 — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/DirectoryWatcher.swift:76; Plugins/LocalFileSystem/DirectoryWatcher.swift:117;
  Plugins/LocalFileSystem/DirectoryWatcher.swift:100; AFMShell/Window/PanelCoordinator.swift:171-179;
  Plugins/LocalFileSystem/LocalFileSystem.swift:840; Plugins/VirtualFolders/VirtualFileSystem.swift:441-470
- **Basis:** read (blocking call, confirmed)
- **Detail:** Path: PanelCoordinator.panelDidChangeLocation -> updateWatchers -> LocalFileSystem.watch ->
  DirectoryWatcher.watch -> resolve. FSEventStreamCreate with WatchRoot at :100 is also on main and may touch the path
  itself. Trigger: either panel on a stalled SMB/NFS mount and either panel navigates; both directories are re-resolved
  so navigating the healthy panel hangs too. Duration 30-600 s. A virtual list forwards up to 512 folders through the
  same route.
- **Proposed fix:** Build and replace the stream on the watcher's own queue and return the handle at once; skip watching
  where volume?.isLocal == false.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### L003 [finding, high] watch() runs realpath, FSEventStreamCreate and Start on the caller's (main) thread, so a stalled SMB/NFS mount freezes the UI on any location change

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/DirectoryWatcher.swift:74,115-119; LocalFileSystem/LocalFileSystem.swift:840;
  AFMShell/Window/PanelCoordinator.swift:171-179; VirtualFolders/VirtualFileSystem.swift:463-469
- **Basis:** read (confirmed by code path; the stall was not simulated)
- **Detail:** Category: freeze. watch() runs realpath() on every directory, then FSEventStreamCreate with WatchRoot
  (which opens each path) and FSEventStreamStart, all on the caller's thread. The caller is
  PanelCoordinator.updateWatchers (main-thread only, runs on every location change). Trigger: the right panel shows a
  folder on an SMB/NFS share that has stalled; the user navigates in the left panel; updateWatchers re-resolves both
  directories and realpath on the dead mount blocks main with no timeout. Also: VirtualFolders passes up to 512 folders
  per call, so one call can be 512 realpaths; which thread that call runs on was not checked.
- **Proposed fix:** Have LocalFileSystem.watch return the token at once and do resolve/create/start on the watcher's own
  serial queue, with stop serialised on the same queue. Also skip re-resolving directories whose locationKey has not
  changed.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L004 [finding, high] places() computes a fresh one-second deadline on every call while knownPlaces is nil, so main freezes 1 s per call with a stalled mount at launch

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:670-681; AFMShell/Window/ButtonBarView.swift:192;
  AFMShell/Panel/PanelViewController.swift:916; Navigation/NavigationPlugin.swift:161;
  LocalFileSystem/LocalFileSystem.swift:733-735
- **Basis:** read (confirmed by reading; that mountedVolumeURLs hangs on a dead mount is plausible)
- **Detail:** Category: freeze. The comment says only the first question waits; the code waits on every call until the
  first read finishes. Reached on main from DriveBarView.rebuild (at launch and on every mount notification), the volume
  menu and NavigationPlugin. Trigger: launch with a stalled network mount; readPlaces() (mountedVolumeURLs plus
  per-volume resourceValues) hangs, and each main-thread call freezes the UI for a full second, indefinitely. Related:
  even on a healthy machine the first call at launch blocks main until the read is done, against the protocol's 'must
  answer at once'. If readPlaces hangs, isReadingPlaces stays true forever and the list never refreshes again.
- **Proposed fix:** Never wait in places(); return fixedPlaces() until the first read lands and announce the result (see
  finding 3). Give the reader a watchdog that clears isReadingPlaces, and read volumes individually so one bad volume
  does not hold up the rest.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L005 [finding, medium] DirectoryWatcher has no client-side coalescing; each FSEvents callback becomes one main-thread onChange, about 450/s under load

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/DirectoryWatcher.swift:40-54,96-98
- **Basis:** measured
- **Detail:** Category: performance. Each FSEvents callback becomes one queue.async to main, and under load FSEvents
  flushes far more often than the 0.5 s latency. Measured: four writers creating and deleting files in the watched
  folder gave 2,696 main-thread onChange calls in 6 s (about 450 per second). Flooding only a sub-sub-folder still gave
  115 calls in 6 s, because MustScanSubDirs marks every watched folder as changed. Trigger: a build or npm install
  anywhere below a folder a panel shows keeps the panel re-listing continuously; the shell serialises reloads so they do
  not pile up, but they never stop. Also: because streams are recursive, watching ~ or / bridges every event path in the
  subtree to a Swift String on the utility queue.
- **Proposed fix:** Keep a pending set in Watch and deliver at most one report per interval (trailing-edge timer, 0.3-1
  s, longer after MustScanSubDirs). Consider kFSEventStreamCreateFlagIgnoreSelf.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L006 [finding, medium] Every symlink and dotted folder in a listing gets an uncancellable stat/resourceValues/getattrlist, so a link into a dead share hangs the listing and pins pool threads

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:105,249,316,269,301
- **Basis:** inferred (plausible; code path certain, hang not simulated)
- **Detail:** Category: freeze/threading. Every symlink in a listing gets a following stat(), and every dotted folder
  gets resourceValues or getattrlist, on the listing thread or inside Parallel.map workers. None can be cancelled.
  Trigger: a local folder (such as ~) contains a link into a dead share or an autofs path; the listing never completes
  (the flag is only looked at between buffers). Each stuck call also pins a ParallelPool thread for good (the pool is
  capped at four times its width).
- **Proposed fix:** Do not resolve link targets inline. Deliver links unresolved and resolve them lazily, or on a
  separate bounded queue with a deadline. At minimum skip resolution on non-local volumes (statfs f_flags of the
  directory) and check the flag per entry.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L007 [finding, medium] Nothing tells clients when the places list has been re-read, so the drive bar shows stale volumes

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:16-19,692-713
- **Basis:** read (confirmed by reading; not run)
- **Detail:** Category: correctness. DriveBarView rebuilds on the same NSWorkspace mount notification that only starts
  the provider's background refresh, so it gets the old list. Trigger: plug in a disk; the drive bar does not show it
  until some later rebuild; after an unmount the stale button stays.
- **Proposed fix:** Post a placesDidChange notification on main when knownPlaces actually changes, and have the bar
  observe that instead of NSWorkspace.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L008 [finding, medium] write() creates files 0644 and applies the source permissions only at close by path, exposing 0600 content and allowing a symlink race

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:359,405-411
- **Basis:** reproduced (mode confirmed; race plausible)
- **Detail:** Category: security. write() creates files with mode 0644 (confirmed); source permissions are applied only
  at close, by path. FileManager.setAttributes(ofItemAtPath:) follows symlinks. Exposure: stream-copying a 0600 file
  (archive or server to disk, or a followed link) leaves its content world-readable in the destination folder for the
  whole transfer, and permanently if the transfer fails with partial files kept. Race: in a shared-writable destination,
  swapping the just-closed temp for a symlink makes the chmod/utimes land on another file of the user.
- **Proposed fix:** open(..., 0o600), then fchmod/futimens on the descriptor before closing it; add O_CLOEXEC.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L009 [finding, medium] append opens with O_WRONLY and no O_NONBLOCK and checks S_IFREG after the open, so a FIFO with no reader hangs the job thread forever

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:370; LocalFileSystem/LocalFileSystem.swift:334-335;
  LocalFileSystem/LocalFileSystem.swift:597
- **Basis:** reproduced (append confirmed; read inferred from POSIX FIFO semantics, not cleanly isolated; copyMetadata
  observed once)
- **Detail:** Category: freeze. On a FIFO with no reader the open blocks forever and cannot be cancelled. read() has the
  same problem through FileHandle(forReadingFrom:). Trigger: Resume/Append onto a destination name that is a FIFO or a
  link to one, or view/stream-copy a FIFO where the caller's isSpecial check raced. Related: copyMetadata(from: plain,
  to: fifo) also blocked in the experiment (copyfile opening the destination, line 597); indicative only because the
  FIFO still had a reader thread blocked on it from earlier cases in the same run.
- **Proposed fix:** Open with O_NONBLOCK | O_CLOEXEC, fstat, reject non-regular files, then clear O_NONBLOCK with fcntl.
  In copyMetadata, refuse when the destination's lstat says it is neither regular, directory nor link.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L010 [finding, medium] lockedCopies keeps every locked copy forever, so remove()/move() silently unlock and delete user-locked files; the 4,096-entry wipe also drops in-flight temp entries

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:472-498,565,617; FileOperations/FileJob.swift:738;
  LocalFileSystem/LocalFileSystem.swift:478
- **Basis:** reproduced (bypass confirmed; wipe race plausible)
- **Detail:** Category: correctness (lock bypass). lockedCopies also records copies that keep their final name: every
  locked destination of copy() and every locked item touched by copyMetadata, folders included. Nothing ever forgets
  them. For the rest of the session remove() and move() silently unlock and delete or rename those user-locked files
  with no 'this item is locked' step. Confirmed: copy of a uchg file followed by remove(dst) succeeded; copyMetadata
  onto a folder followed by move succeeded. Second problem: at 4,096 entries the table is wiped (removeAll, line 478),
  which also drops entries for in-flight temporary files of other workers; their rename then fails with EPERM and remove
  fails too. FileJob.discard (FileJob.swift:738) retries after unlocking via setAttributes, so cleanup still works, but
  the item fails.
- **Proposed fix:** Make the allowance explicit and scoped: e.g. copy returns a token, or the caller passes allowLocked
  to the single rename/remove of its own temp; or the entry expires on first use and after a short TTL. Never
  bulk-clear; evict the oldest.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L011 [finding, medium] setAttributes unlocks the link itself but changes mode and date through fm.setAttributes, which follows the link and alters the target

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:572-584
- **Basis:** reproduced
- **Detail:** Category: correctness. Confirmed: calling it on a symlink changed the target's mode to 777 and its mtime.
  Trigger: Change Attributes on a selection containing links, or a job carrying attributes onto a copied link, alters
  files outside the tree being worked on. Also: the unlock is not rolled back if the later step fails.
- **Proposed fix:** Use fchmodat(AT_SYMLINK_NOFOLLOW) and utimensat(AT_SYMLINK_NOFOLLOW), or setattrlist with
  FSOPT_NOFOLLOW. Decide explicitly whether links are skipped.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L012 [finding, medium] B6: places() waits up to 1 s per call while the first background read is stuck on a dead mount

**Outcome:** duplicate of L004 — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/LocalFileSystem.swift:670-675
- **Basis:** read
- **Detail:**
- **Proposed fix:** Seed with fixedPlaces().
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### L013 [finding, medium] LocalFileSystem.places() can wait 1 s on main per call while knownPlaces is nil

**Outcome:** duplicate of L004 — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/LocalFileSystem.swift:670-675;
  Plugins/LocalFileSystem/LocalFileSystem.swift:733-735; AFMShell/Window/ButtonBarView.swift:192;
  AFMShell/Panel/PanelViewController.swift:916
- **Basis:** read (reported as confirmed)
- **Detail:** Blocking call. It waits up to 1 s on the condition while knownPlaces == nil. The comment assumes only the
  first call waits. If the first background readPlaces() (mountedVolumeURLs with resource values) is stuck on a dead
  mount present at launch, knownPlaces stays nil. Callers: DriveBarView.rebuild and PanelViewController.swift:916; each
  call blocks a full second for as long as the read is stuck.
- **Proposed fix:** Wait only once (set a 'waited' flag), or seed knownPlaces with fixedPlaces() in init.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### L014 [verdict, medium] realpath on main for every location change

**Outcome:** duplicate of L001 — see `status/localfs.md`

- **Where:** Sources/AFMShell/Window/PanelCoordinator.swift:171-180;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:840-843;
  Sources/Plugins/LocalFileSystem/DirectoryWatcher.swift:75;
  Sources/Plugins/LocalFileSystem/DirectoryWatcher.swift:112-114
- **Basis:** CONFIRMED (read)
- **Detail:** Worse than stated: every location change passes both panels' directories; if one panel sits on a dead
  mount each navigation in the healthy panel runs realpath on the dead path on main. UI freeze on each navigation until
  the mount times out.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### L015 [verdict, medium] Directory watcher does not coalesce

**Outcome:** duplicate of L005 — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/DirectoryWatcher.swift:97-98;
  Sources/Plugins/LocalFileSystem/DirectoryWatcher.swift:53
- **Basis:** CONFIRMED (ran)
- **Detail:** FSEvents latency 0.5 s did not help: at ~29,000 changes/s, 486-508 callbacks/s reached the main queue, ~50
  per 100 ms, each its own queue.async.
- **Proposed fix:** Coalesce in Watch.report (one pending flag per watcher).
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### L016 [finding, medium] Every local symlink has size 0 so the viewer reads the whole target once just to measure it

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:327
- **Basis:** read
- **Detail:** lstat-based item(at:) reports size 0 for non-regular files; viewer reads the whole target before showing
  anything.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### L017 [verdict, medium] append/read block on FIFOs

**Outcome:** duplicate of L009 — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:370;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:335; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:376;
  Sources/Plugins/FileOperations/FileJob.swift:914
- **Basis:** CONFIRMED (ran)
- **Detail:** Non-regular-file check at 376 comes after the blocking open. Observed: both still blocked after 2 s. At
  job level, Resume onto a destination pipe hung in startsWithPartial and ignored Cancel.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L018 [verdict, medium] lockedCopies allows silent unlock-and-delete (narrower form)

**Outcome:** duplicate of L010 — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:415-427;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:472-498;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:461; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:617;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:478
- **Basis:** CONFIRMED (ran) in narrower form; 4,096-entry wipe read only
- **Detail:** Not affected: user's own locked original is refused; a locked file copied by a job is refused afterwards
  because the entry is dropped on the temp-to-final rename (461). Affected: a locked folder copied by a job stays in the
  table (via copyMetadata, 617); deleting that copy later in the same session removed it with no 'locked' question while
  a control folder did get the question. A direct copy() to a final name behaves the same even after user unlocks and
  re-locks by hand; no in-app caller does that today. Wipe at 4,096 (478): read only, not reproduced; consequence would
  be a spurious 'Operation not permitted' on a pending locked temp, not a deletion.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L019 [verdict, medium] lockedCopies: user's own locked original and job-copied locked file are refused (sub-ruling of claim 10)

**Outcome:** not a defect — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:461;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:415-427
- **Basis:** CONFIRMED (ran)
- **Detail:** Not affected: the user's own locked original is refused, and a locked file copied by a job is refused
  afterwards because the entry is dropped on the temp-to-final rename (461).
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L020 [verdict, medium] setAttributes on a symlink changes its target

**Outcome:** fixed — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:572-584;
  Sources/Plugins/FileProperties/AttributeChange.swift:333; Sources/Plugins/FileOperations/FileJob.swift:745;
  Sources/Plugins/FileOperations/FileJob.swift:1367; Sources/Plugins/DirectorySync/SyncPlan.swift:192;
  Sources/Plugins/DirectorySync/SyncPlan.swift:389; Sources/Plugins/DirectorySync/SyncPlan.swift:392
- **Basis:** CONFIRMED (ran)
- **Detail:** Observed: target went 644 to 600 and took the new date; link unchanged. Change Attributes guards against
  this (AttributeChange.swift:333). Unguarded callers: FileJob:745 and 1367 (see N1) and SyncPlan.swift:192, 389, 392
  (read, not run).
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L021 [verdict, medium] LocalFileSystem.places() blocks 1 s per call on main

**Outcome:** duplicate of L004 — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:673-675;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:700-711;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:733; Sources/AFMShell/Window/ButtonBarView.swift:192;
  Sources/AFMShell/Panel/PanelViewController.swift:916; Sources/Plugins/Navigation/NavigationPlugin.swift:161
- **Basis:** CONFIRMED (read)
- **Detail:** Computes a new 1 s deadline on every call and waits while knownPlaces == nil, which stays nil until first
  readPlaces() returns (calls mountedVolumeURLs with resource values). Main-thread callers listed. User sees with a dead
  network mount at launch 1 s freezes at start-up, on every volume-menu open and on every mount notification.
  mountedVolumeURLs hang not induced.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### L022 [finding, low] If FSEventStreamCreate fails, watched is already set, so a later watch() with the same folders returns early and never retries

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/DirectoryWatcher.swift:77,97-98
- **Basis:** read (confirmed by reading)
- **Detail:** Category: correctness.
- **Proposed fix:** Set watched only after a successful start.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L023 [finding, low] rename/renamex_np, unlink/rmdir, lchflags, setxattr/getxattr, setattrlist, fm.setAttributes, trashItem and createDirectory on job threads have no timeout or cancel

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift
- **Basis:** read
- **Detail:** Blocking-calls table. The report found no main-thread path into blocking storage calls within its scope
  apart from the first two rows (watch and places).
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L024 [finding, low] FileHandle open/read/write/close and open/fstat/ftruncate/lseek in append on job threads have no interrupt() on Reader or Writer; append checks the flag once

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:(append)
- **Basis:** read
- **Detail:** Blocking-calls table.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L025 [finding, low] stat/lstat per link or failed entry on listing and pool threads has no timeout or cancel

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:100,105,249,308,316,908
- **Basis:** read
- **Detail:** Blocking-calls table: none.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L026 [finding, low] String(cString:) repairs invalid UTF-8 names with U+FFFD, so the item's URL names a nonexistent file on NFS/FUSE volumes

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:150,892
- **Basis:** inferred (plausible)
- **Detail:** Category: correctness. On volumes that allow such names (NFS, some FUSE) open/copy/delete fail with
  ENOENT.
- **Proposed fix:** Detect the repair and either keep the raw bytes (percent-encoded URL built from bytes) or mark the
  item unreadable.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L027 [finding, low] Full listing delivers an entry whose bulk attributes and lstat both failed as a zero-byte 1970 non-file, while the lean entries(of:) drops it

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:238-245; LocalFileSystem/LocalFileSystem.swift:99-101
- **Basis:** inferred (plausible)
- **Detail:** Category: correctness. A deleted-meanwhile entry is still delivered by the full listing.
- **Proposed fix:** Drop it in both.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L028 [finding, low] resourceValues(.isPackage) and getattrlist on listing and pool threads have no timeout or cancel; contentsOfDirectory fallback on the listing thread has none either

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:269,301,53
- **Basis:** read
- **Detail:** Blocking-calls table: none for both rows.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L029 [finding, low] createDirectory succeeds silently when the directory exists or is a symlink to a directory

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:353-355
- **Basis:** reproduced
- **Detail:** Category: correctness. Both confirmed. Callers cannot tell 'created' from 'was there', and a tree copy
  writes through a pre-existing link.
- **Proposed fix:** mkdir the leaf yourself and report EEXIST; let the caller decide about merging; lstat the leaf.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L030 [finding, low] move(replacing: true) between two hard links of the same file returns success while the source still exists

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:439
- **Basis:** reproduced
- **Detail:** Category: correctness. rename(2) is a no-op there. A Move job reports success and nothing moved.
- **Proposed fix:** When replacing, compare dev/ino of both names and unlink the source if they match.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L031 [finding, low] copy() hands anything that is not a regular file to fm.copyItem, so a directory is copied with no progress and no cancellation

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:506-511
- **Basis:** reproduced
- **Detail:** Category: correctness/freeze. If a caller passes a directory, the whole tree is copied with no progress
  and no cancellation (confirmed: zero progress calls). The contract says 'one file or link' but nothing enforces it.
- **Proposed fix:** Allow only S_IFLNK (via symlink/copyfile with NOFOLLOW) and throw for directories and special files.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L032 [finding, low] copyfile (539, 597) and fm.copyItem (508) are cancellable only through the progress callback between chunks; none for metadata or copyItem

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:539,597,508
- **Basis:** read
- **Detail:** Blocking-calls table: job threads.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L033 [finding, low] No raw open uses O_CLOEXEC and no syscall retries EINTR

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:68,180,359,370,860
- **Basis:** read (confirmed by reading)
- **Detail:** Category: leak/robustness. Affects open on interruptible NFS, getattrlistbulk, ftruncate.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L034 [finding, low] Listing a dataless iCloud/File Provider directory materialises it and blocks with no timeout; totalSize over iCloud Drive materialises every folder

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:68,180,860
- **Basis:** inferred (plausible)
- **Detail:** Category: freeze. File contents are never downloaded, since nothing opens files.
- **Proposed fix:** Consider setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, ...OFF) for size and tree walks,
  and surface EDEADLK as 'not downloaded'.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L035 [finding, low] open + getattrlistbulk in listing, job and pool threads is cancelled only between buffers, and not at all inside totalSize's loop

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:68/81, 180/197, 860/874
- **Basis:** read
- **Detail:** Blocking-calls table: flag checked between buffers only (not at all inside totalSize's loop).
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L036 [finding, low] readPlaces calls (mountedVolumeURLs, resourceValues, fileExists) have no timeout; a stuck read blocks refresh forever

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:730-735
- **Basis:** read
- **Detail:** Blocking-calls table: reaching thread is a global queue; timeout or cancel: none; stuck forever blocks
  refresh.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L037 [finding, low] fileExists loop, resourceValues and statfs in volume(of:) run on the listing thread, utility queue and jobs with no timeout

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:756-761; AFMKernel/Panels/Listing.swift:81
- **Basis:** read
- **Detail:** Blocking-calls table: reaching thread is the listing thread (Listing.swift:81), utility queue, jobs;
  timeout or cancel: none.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L038 [finding, low] spareSpace is keyed by mount-point path, so a different volume remounted at the same path inherits the old spare figure

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:777,797-811
- **Basis:** inferred (plausible)
- **Detail:** Category: correctness. spareSpace is only dropped when a re-measure fails. After eject and re-mount of a
  different volume at the same path (/Volumes/Untitled), the old spare figure is added to the new volume's free space
  until the next measurement (3 s or more).
- **Proposed fix:** Key by f_fsid, or store it and compare.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L039 [finding, low] measureSpareSpace on the utility queue has no timeout and isMeasuring stays set if it hangs

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:819
- **Basis:** read
- **Detail:** Blocking-calls table: none; isMeasuring stays set.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L040 [finding, low] totalSize checks the cancel flag once per directory, not per buffer, and copy does not pass COPYFILE_DATA_SPARSE

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift:873-914
- **Basis:** read
- **Detail:** Category: performance. A million-entry folder is read to the end after Cancel. Also copy does not pass
  COPYFILE_DATA_SPARSE, so a cross-volume copy of a sparse image is written out in full and can fill the target disk.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L041 [finding, low] FSEvents teardown (plausible, unverified): DirectoryWatcher.stop releases the stream and its Watch context from main with no documented guarantee that a callback on streamQueue has finished

**Outcome:** fixed — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/DirectoryWatcher.swift:104-112
- **Basis:** inferred (unverified)
- **Detail:**
- **Proposed fix:** streamQueue.sync {} after FSEventStreamInvalidate.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### L042 [finding, low] FIFOs and devices can hang threads: local open without O_NONBLOCK or a type check; descript.ion FIFO blocks the comment loader with no cancel; checksum entries with absolute or .. paths (e.g. /dev/zero)

**Outcome:** fixed — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/LocalFileSystem.swift:334-336; Plugins/FileProperties/Descript.swift:215-225;
  Plugins/FileTools/ChecksumFiles.swift:367-370
- **Basis:** inferred (plausible)
- **Detail:** Callers that do not test isSpecial.
- **Proposed fix:** In read, open O_NONBLOCK, fstat, and refuse non-regular files.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### L043 [finding, low] Symlink races on path-based operations in attacker-writable folders: unpack follows existing symlink-to-directory; Writer.close sets mode/time by path; recursive delete/copy re-open children by path; archive modes applied as stored incl. world-writable

**Outcome:** fixed in part — see `status/integration.md`

- **Where:** Plugins/LocalFileSystem/LocalFileSystem.swift:353; Plugins/Archives/Unpacker.swift:291-306;
  Plugins/Archives/Unpacker.swift:364-366; Plugins/LocalFileSystem/LocalFileSystem.swift:405-411;
  Plugins/FileOperations/FileJob.swift:1222-1300; Plugins/LocalFileSystem/LocalFileSystem.swift:68;
  Plugins/LocalFileSystem/LocalFileSystem.swift:180; Plugins/Archives/Tar.swift:93
- **Basis:** inferred (plausible)
- **Detail:** Unpack creates folders with createDirectory(withIntermediateDirectories:) which accepts an existing
  symlink-to-directory. Stage one plants docs -> ~/Library/LaunchAgents (symlink targets unrestricted); a second unpack
  writes through it. Writer.close should use fchmod/futimens. The single-archive symlink-then-file case is verified
  blocked.
- **Proposed fix:** openat/O_NOFOLLOW walking for unpack and delete; refuse symlinked parents inside the unpack root;
  mask modes with ~022.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### L044 [finding, low] LocalFileSystem.places(): if the first readPlaces() hangs on a dead mount, knownPlaces stays nil and every call on main waits its full 1 s; isReadingPlaces stays true so the list never refreshes

**Outcome:** duplicate of L004 — see `status/localfs.md`

- **Where:** Plugins/LocalFileSystem/LocalFileSystem.swift:674-675; Plugins/LocalFileSystem/LocalFileSystem.swift:675
- **Basis:** read
- **Detail:**
- **Proposed fix:** Remember that the grace period has been spent, and read volumes with a timeout.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### L045 [verdict, low] write() creates the file 0644 until close

**Outcome:** duplicate of L008 — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:359;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:405-411
- **Basis:** CONFIRMED (ran)
- **Detail:** Permissions applied only at close. Observed: mode 644 while open, 600 after close. Scope: streamed
  transfers only (from archives or servers, followed links, Append, non-in-place Resume); local copies use copyfile and
  are not affected. Matters only in folders other users can enter.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L046 [verdict, low] lockedCopies wipe at 4,096 entries (sub-ruling of claim 10)

**Outcome:** fixed — see `status/localfs.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:478
- **Basis:** UNPROVEN (read only)
- **Detail:** Read only, not reproduced. Consequence would be a spurious 'Operation not permitted' on a pending locked
  temp, not a deletion.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L047 [finding, info] unlockOwnCopy has a small lstat -> lchflags window under lockedLock

**Outcome:** fixed — see `status/localfs.md`

- **Where:** LocalFileSystem/LocalFileSystem.swift (unlockOwnCopy)
- **Basis:** inferred
- **Detail:** Shared-mutable-state table: lock sufficient; table semantics wrong (finding 8); small lstat->lchflags
  window in unlockOwnCopy. The swap was reasoned about, not reproduced.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

## Checked and found sound

### L048 [sound, info] Places state is lock-protected correctly (wait policy wrong)

- **Basis:** read
- **Detail:** knownPlaces, placesRead, isReadingPlaces, placesChangedMeanwhile under placesCondition: locking correct;
  wait policy wrong (finding 2).
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L049 [sound, info] mountObservers is written in init and read in deinit

- **Basis:** read
- **Detail:** Fine.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L050 [sound, info] packageExtensions under packageLock is sufficient

- **Basis:** read
- **Detail:** packageLock is never held across syscalls; benign duplicate asks.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L051 [sound, info] spareSpace under spareLock is sufficient

- **Basis:** read
- **Detail:** Released around measuring; first-question race only duplicates a 15 ms measure; stale key is finding 22.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L052 [sound, info] DirectoryWatcher.stream/watch/watched are unsynchronised but have a single owner

- **Basis:** read
- **Detail:** Fine while each watcher has one owner.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L053 [sound, info] Watch.stopped under NSLock is sufficient

- **Basis:** read
- **Detail:**
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L054 [sound, info] Watch lifetime is retained by the stream's context

- **Basis:** read
- **Detail:** Sound.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L055 [sound, info] copy's Progress object is used only on the copying thread

- **Basis:** read
- **Detail:** Fine.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L056 [sound, info] Bulk attribute parse is correct

- **Basis:** read
- **Detail:** Attribute order, the error word after the returned set, name offset relative to its reference, unaligned
  loads, and optional fields driven by the returned set are all correct. Lengths are trusted from the kernel.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L057 [sound, info] Parallel item building preserves order

- **Basis:** read
- **Detail:** The entry buffer is read-only, and each piece has its own URL.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L058 [sound, info] Lean totalSize is correct

- **Basis:** read
- **Detail:** Links are not followed, the descriptor is closed before recursing, and a 480-level tree ran on a 512
  KB-stack thread without overflow.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L059 [sound, info] Watcher teardown is clean

- **Basis:** read
- **Detail:** 3,000 start/stop cycles under an event flood gave no crash and zero client calls after stop. All 1,000
  Watch states were freed in an instrumented copy. Clients are called on the requested queue (main for the provider).
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L060 [sound, info] Stream count and root changes are covered

- **Basis:** read
- **Detail:** One stream per provider for both panels' active folders. Unmount and rename of the watched folder are
  covered by WatchRoot -> RootChanged.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L061 [sound, info] copy() semantics are sound

- **Basis:** read
- **Detail:** COPYFILE_CLONE implies NOFOLLOW_SRC and EXCL per the man page; a link source is cloned as a link (tested).
  After a cancelled block copy, copyfile removes the destination itself and the descriptor stays valid until
  copyfile_state_free, so the dev/ino-guarded cleanup never removes a foreign file (tested). EEXIST is returned before
  any cleanup.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L062 [sound, info] move() is sound

- **Basis:** read
- **Detail:** RENAME_EXCL is atomic; a case-only rename with replacing: false works on APFS (tested); the ENOTSUP
  fallback's case-only problem is handled by the caller (FileOperations/FileOperationsPlugin.swift:398-403).
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L063 [sound, info] write() uses O_EXCL

- **Basis:** read
- **Detail:** It never opens an existing file or follows a final link.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L064 [sound, info] append closes the descriptor on every error path

- **Basis:** read
- **Detail:**
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L065 [sound, info] remove() never follows links

- **Basis:** read
- **Detail:**
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L066 [sound, info] Quarantine, creation-date and flag calls all use NOFOLLOW variants

- **Basis:** read
- **Detail:**
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L067 [sound, info] Volume refresh is sound

- **Basis:** read
- **Detail:** No notification loop (a notification makes clients ask, but within 3 s nothing re-measures); a vanished
  volume drops its entry; no retain cycle.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L068 [sound, info] DirectoryWatcher delivery is bounded

- **Basis:** read
- **Detail:** FSEvents latency is 0.5 s, so 5,000 events/s arrive as about two callbacks per second. Sifting happens on
  the stream queue, and there is at most one main.async per callback, carrying at most the watched directories.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### L069 [sound, info] Local-to-local plain copy of a folder with a named pipe does not hang

- **Basis:** reproduced
- **Detail:** It uses copy, not a stream; the pipe was simply not copied.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### L070 [sound, info] Local writes use O_CREAT|O_EXCL then atomic or exclusive rename; copyfile exclusive; set-uid/gid bits stripped from tar

- **Where:** Plugins/LocalFileSystem/LocalFileSystem.swift:359; Plugins/LocalFileSystem/LocalFileSystem.swift:438-445;
  Plugins/LocalFileSystem/LocalFileSystem.swift:537; Plugins/Archives/Tar.swift:93
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

## Not covered / left behind

### L071 [gap, info] Not verified: copyfile behaviour when metadata cannot be stored on the target (FAT/SMB)

- **Basis:** read
- **Detail:** Whether it returns -1, which would make copy() delete an otherwise complete file.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L072 [gap, info] Not reproduced: the 4,096-entry wipe race and the lstat->lchflags swap in unlockOwnCopy

- **Basis:** read
- **Detail:** Reasoned about only.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L073 [gap, info] FSEventStreamInvalidate semantics come from stress testing, not from source

- **Basis:** read
- **Detail:**
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### L074 [gap, info] Not examined: fm.trashItem on volumes without a Trash; ACL inheritance on copies

- **Basis:** read
- **Detail:**
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open
