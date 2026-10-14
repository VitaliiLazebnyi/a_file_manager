# Audit threading model across codebase

# Threading-model audit of A File Manager: whole-program view

Nothing was built or run; every finding comes from reading the code. I found no lock-order cycle among the program's locks; the one deadlock is a lock-plus-main-thread cycle at quit. There are also one main-thread violation, one data-loss race and several smaller races and UI-freeze paths.

**How the work was split.** I read AFMKernel, AFMShell, LocalFileSystem, VirtualFolders, FileOperations, FindFiles and Places myself. Three delegated reviewers read Network, Archives, and Viewer/FileTools/FileProperties in full; I checked their results against the kernel contracts but did not re-read their files. Findings resting on a reviewer's reading are marked "(reviewer)". Two further reviewers failed to launch, so the remaining plugins got a targeted grep-and-read from me rather than a full reading (see section f).

All paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/`.

## (a) Locks, queues and threads

| Primitive (file:line) | Guards | Notes |
|---|---|---|
| `ParallelPool.condition` `AFMKernel/Support/Parallel.swift:82` | open jobs, per-job counters, thread table | Leaf; never held across a body. "AFM.Parallel" threads, at most 4 × (cores − 1), exit after 2 s idle. |
| per-job `sleeper` semaphore `Parallel.swift:134` | caller's wait | Initial value 0, only over-signalled, so safe at dealloc. |
| `CancellationFlag.lock` `Support/CancellationFlag.swift:6` | flag and handlers | Leaf; handlers run after unlock on the cancelling thread (often main). |
| `ListingCache.lock` `Panels/ListingCache.swift:74` | slots, clock | Leaf; sorting is done outside it. |
| `NameCollator.lock` (static) `Panels/Sorting.swift:647` | collator cache | Held across the first collator build (CPU only, once per locale). |
| `OrderBox.lock` `AFMShell/Panel/PanelLoading.swift:38` | wanted sort order | Leaf. |
| `PauseGate.condition` `AFMShell/Interaction/ProgressJobService.swift:153` | paused flag | Job threads wait in it, polling every 0.1 s. |
| `afm.read-ahead` serial queue `AFMShell/Panel/ReadAhead.swift:61` | one read-ahead at a time | Blocks in provider calls. |
| `FileJob.decisions` `Plugins/FileOperations/FileJob.swift:188` | "for all" answers; one question at a time | Held across `monitor.ask` (`main.sync`) and across `stop.cancel()` at :1409. Main never takes it. |
| `FileJob.counters` `:193` | progress counters, failures, created folders | Held across `emit` → `monitor.report` → `PauseGate`, so it is held for a whole pause. Main never takes it. |
| `FileJob.remembered` `:212`, `pendingRemovals` `:225`, `Batch.lock` `:309`, `Tally.lock` `:1300` | caches and lists | Leaves. |
| `Pool.slots` semaphore and concurrent queue `:289-295`; `Batch.group` | at most 8 copy / 4 delete workers | Balanced on every path I traced. |
| `OperationLog.queue` `FileOperations/OperationLog.swift:57` | log state | `flush()` does `queue.sync` from main at quit. |
| `StorageMedium.lock` (static) `FileOperations/StorageMedium.swift:7` | device → rotational | Held across one IORegistry lookup per device; job thread only. |
| `Walk.condition` `FindFiles/FileSearch.swift:326`, `visitedLock` `:329`, `JobStack.condition` `:455` | search tree, visited set, job stack | Each search starts max(4, cores) unnamed threads. |
| `DirectoryWatcher.streamQueue` `LocalFileSystem/DirectoryWatcher.swift:59`, `Watch.lock` `:20` | FSEvents callbacks, stopped flag | Callback hops to main. |
| `LocalFileSystem.packageLock` `:289`, `lockedLock` `:470`, `spareLock` `:773` | small caches | Leaves; no I/O under them. |
| `LocalFileSystem.placesCondition` `:684` | places list | Main waits on it, bounded to 1 s. |
| `VirtualFileSystem.lock` `VirtualFolders/VirtualFileSystem.swift:47`, `Coalescer.lock` `:490` | registered lists, options | Leaves; taken on main for µs. |
| `TreeCache.lock` `Places/TreeCache.swift:54`, `updates` queue `:57` | cached trees | Not held across disk I/O. |
| `afm.places.tree` concurrent queue `Places/DirectoryTreeWindowController.swift:66` | tree scans | Blocks in provider calls. |
| `RenameStore.memoriesLock` `MultiRename/RenameStore.swift:45`; `multirename.preview` and `multirename.store` queues | per-settings memory | Leaf. |
| `SyncComparison.lock` `DirectorySync/SyncComparison.swift:40` | counters, errors | Progress callback runs under it (async hop only). |
| Network (reviewer): `FTPSession.condition`, `loginLock`, `SFTPSession.lock`, `connectLock`, `SFTPChannel.lock`, `writeLock`, `ConnectionCenter.lock`, `FTPReader.stateLock`, `NetStream.condition`, keep-alive timer, SFTP reader thread, `afm.network.cleanup` concurrent queue | pools, logins, channel | `loginLock` and `connectLock` are held across `askUser`. |
| Archives (reviewer): `Slot.lock` (L3), `OpenArchive.lock` (L4), `flushLock` (L5), `ArchiveStore.lock`, `InterruptSlot.lock`, `StreamInterrupt.lock`, `ProcessStream.lock`; flush-timer chain on `global(.utility)` | opening, tree, one flush at a time | L3 and L5 are held for unbounded I/O; L5 also across outer-provider calls that may ask the user. |
| Viewer / FileTools / FileProperties (reviewer): `CharacterBoundaries.computing`, `TextRowIndex.lock`, `CachedByteSource.lock`, `DiskBlockCache.lock`, `CodeTable.lock`, `TemporaryCopies.lock`, `ToolRun.reportLock`, `ProgressMeter.lock`, `CommentStore.condition`; queues `viewer.work` (concurrent), `viewer.rows` (serial) | caches, indexes | Only `reportLock` and `ProgressMeter.lock` are held across a pause. |

There are no actors, `@MainActor` annotations or atomics. The only async/await is `Viewer/UI/RichViews.swift:208`, and the only `@unchecked Sendable` is `FileTools/Hashes.swift:459` (reviewer: justified, disjoint output slots). All static mutable state is locked or main-only.

## (b) Lock-order graph

"MAIN" is a pseudo-lock: an edge X → MAIN means a thread holds X while it waits in `main.sync` (`Kernel.askUser` at `AFMKernel/PluginAPI/Kernel.swift:102`, `ProgressSheet.ask` at `ProgressJobService.swift:223`).

- `FileJob.decisions` → MAIN; `decisions` → handlers of `stop` → reader/writer interrupt locks.
- `FileJob.counters` → `PauseGate.condition`.
- `FTPSession.loginLock` → `FTPSession.condition` → `NetworkOptions.lock`; `loginLock` → MAIN.
- `SFTPSession.connectLock` → `writeLock` → `SFTPChannel.lock`; `connectLock` → MAIN.
- `ConnectionCenter.lock` → `FTPSession.condition` or `SFTPSession.lock`.
- Archives: L3 → L4 → {`ArchiveStore.lock`, scratch lock, outer `capabilities`}; L5 → L4; L5(inner) → L3/L4/L5(outer); L3 → MAIN (password for an outer archive); L5 → MAIN (upload through a network provider).
- MAIN → L5 at quit (`ArchivesPlugin.stop`), MAIN → L4 (`capabilities(for:)`), MAIN → `placesCondition`, MAIN → `DiskBlockCache.lock`.
- MAIN → Parallel job completion: bodies are pure at every main-thread call site I found (`AFMKernel/Panels/PanelModel.swift:435` and the Sorter).

**One cycle: L5 → MAIN → L5.** This is finding 1.

No cycle exists through Parallel. A caller waits only for pieces already taken, pool threads never hold a lock while taking a piece, and no caller holds a lock across `Parallel.map` (checked in my modules; reviewers confirmed theirs).

`loginLock`, `connectLock` and L3 → MAIN are safe only because main never calls a connecting or opening provider method. I checked every provider call site in AFMShell and in the Navigation, Places, Clipboard, FolderTabs, Selection, SystemTools and FileOperations plugins: all are inside jobs or background closures. This invariant holds by convention only; one main-thread `item(at:)` would turn it into a deadlock.

## (c) Where the main thread blocks

| Site | Waits for | Worst case |
|---|---|---|
| `ArchivesPlugin.stop` → `flushAll` (`Archives/ArchivesPlugin.swift:96`) | L5; whole-archive rewrite or upload, not cancellable | Minutes; forever in finding 1 |
| `PanelCoordinator.updateWatchers` → `provider.watch` (`AFMShell/Window/PanelCoordinator.swift:178`) → `DirectoryWatcher.resolve` → `realpath` (`DirectoryWatcher.swift:74,117`) | file system of the watched folder | One network timeout per folder; up to 512 folders through `VirtualFileSystem.watch` (`VirtualFileSystem.swift:463-469`) |
| `ViewerPane.stopWork` → reader `close()`, `removeItem` (`Viewer/UI/ViewerPane.swift:324`; reviewer) | provider close, disk | One round trip per idle reader, on every quick-view cursor move |
| `NetworkPlugin.stop`, `NetworkCommands` connect-failure completion (reviewer) | QUIT write, SFTP close | 2 s per idle FTP connection, 0.5 s per SFTP session |
| `LocalFileSystem.places()` (`:675`), from the volume menu, button bar and Navigation | first places read | 1 s per call, repeated for as long as the first read hangs (finding 13) |
| `ArchiveFileSystem.capabilities(for:)` → L4 (reviewer) | `rebase`, `takeSnapshot` | About 1 s on a huge ZIP |
| `PlacesPlugin.stop` → `TreeCache.flush` (`Places/PlacesPlugin.swift:129`); `OperationLog.flush` | local disk writes | ms |
| `PanelModel.update` → `Parallel.map` (`PanelModel.swift:435`); `Sorter.sort` when a piece arrives in the wrong order | pool pieces, pure CPU | ms; gets no pool help while an older I/O job is open (finding 14) |
| `CancellationFlag.cancel()` on main (Cancel buttons, `beginLoad`, window close) | `interrupt()` handlers | µs; all implementers were checked non-blocking by the reviewers |
| `AttributeDraft.fields` → `getpwuid_r` (`FileProperties/FilePropertiesPlugin.swift:466`; reviewer) | directory services | Seconds with network accounts |
| `CodeTable` build on main (`ViewerPane.swift:468`; reviewer) | CPU | Tens of ms, estimated |

The main thread never waits on a semaphore, group or `queue.sync` for background work, apart from `OperationLog.flush` at quit.

## (d) Findings, most severe first

**1. HIGH — deadlock at quit: archive flush timer against `ArchivesPlugin.stop()`.**
- Timer path (reviewer): `OpenArchive.timerFired` (`Archives/OpenArchive.swift:752`) → `flush` takes `flushLock` (:1045) → `upload` (:1362/1373/1379) → outer provider `write`/`move`/`item`. If the outer provider is FTP or SFTP and needs a new connection, it reaches `askCredentials`/`askToTrust`/`askSecret` (`Network/FTPSession.swift:133,163,169`; `SFTPSession.swift:119`) → `Kernel.askUser` → `DispatchQueue.main.sync`.
- Main path: `applicationWillTerminate` (`AFMShell/App/Shell.swift:109`) → `Kernel.shutdown` → `ArchivesPlugin.stop` (:96) → `flushAll` → `flush` → `flushLock.lock()`.
- Interleaving: the timer holds `flushLock`, main blocks on it, then the connection asks. `applicationShouldTerminate` drains only the job queue; the timer is not a job.
- Fix: never take `flushLock` on main. Flush in `applicationShouldTerminate` (`.terminateLater`) on a background thread with a cancellable flag and a "Saving archives…" sheet, and add a shutdown flag that timer flushes honour.
- Confidence: both halves read (Archives and Network by reviewers, Shell and Kernel by me). The Network reviewer confirmed the ask sites are reached when a new connection is opened; the write path into them was not traced line by line.

**2. HIGH — main-thread violation: `VirtualFileSystem.Coalescer` calls `onChange` on a global queue.**
- `Coalescer.signal` (`VirtualFolders/VirtualFileSystem.swift:497-507`) fires the first report on the caller (main), then schedules `settle()` on `DispatchQueue.global(qos: .userInitiated)`.
- `settle` (:510-518) calls `fire()` on that background thread. `fire` is `onChange([virtual])` (:466), which is `PanelCoordinator.reloadChangedPanels` (`PanelCoordinator.swift:178,136`) → `PanelViewController.reload` (`MainThread.assert` at `AFMShell/Panel/PanelViewController.swift:810`).
- Trigger: two changes within 0.5 s in any watched branch view or file list. Debug builds assert; release builds race on panel and AppKit state.
- The provider contract (`AFMKernel/FileSystem/FileSystemProvider.swift:308`) says `onChange` is called on main.
- A pending `settle` also fires after the watcher was released.
- Fix: schedule `settle` on `DispatchQueue.main`, and give `Coalescer` a cancelled flag set from `Watchers.deinit`.
- Confidence: confirmed, both paths read.

**3. MEDIUM-HIGH — race, possible data loss on Move into an archive (reviewer).**
- Path A: `ArchiveFileSystem.write` (`Archives/ArchiveFileSystem.swift:386`) resolves archive X, with `Slot.lock` already released, then calls `X.write`.
- Path B: `evict` (:158-166) sees `X.isBusy == false` and removes X from the store.
- If B runs between A's resolve and A's `openWriters += 1`, X is detached while holding pending changes. `store.commit(url)` (:197) finds nothing pending and returns success, and `FileJob.flushDeferred` (`FileJob.swift:1144-1177`) then deletes the sources. At quit, `flushAll` misses X and the scratch folder is deleted.
- Fix: retire an archive atomically under its own lock and have mutators re-resolve on a "retired" error, or track busy archives in the store.
- Confidence: confirmed by the reviewer; narrow window.

**4. MEDIUM — race: `FTPReader.close()` can cut a recycled connection (reviewer).**
- `Network/FTPSession.swift:702-710` captures the connection under `stateLock`, unlocks, then calls `connection.interrupt()`.
- Meanwhile the reading thread reaches EOF and releases the connection to the idle pool (:644-646), and a third thread acquires it (:216). That thread gets a spurious `connectionLost`, which is not retried for mkdir, delete, rename or uploads.
- Fix: interrupt while holding `stateLock` after re-reading `active`, as `interrupt()` does at :696-698.

**5. MEDIUM — data race on cancel in `FileSearch.Walk`.**
- Write: `deliver` (`FindFiles/FileSearch.swift:367-370`) sets `node.candidates = []` under `condition` as soon as the search is cancelled, even while `pending > 0`.
- Read: a worker in `checks(for:)` reads `node.candidates.count` (:433) and captures `node.candidates` (:440) without the lock. It is called from `list` at :425, after the unlock at :423.
- Interleaving: cancel arrives while a worker is between :423 and :440. An unsynchronised array read against a write can crash.
- Fix: pass `wanted` into `checks` instead of re-reading the node, or read under the lock.
- Confidence: confirmed.

**6. MEDIUM — main-thread blocks.** These are the rows of section (c): `watch` → `realpath` on main, the Viewer close/delete on main, Network disconnect on main, and the synchronous archive flush at quit.
- Fix: do the `realpath` resolution on the watcher's queue, hand sources and doomed folders to a background queue, and do the quit work in the `.terminateLater` phase.

**7. MEDIUM — cancellation not wired through.**
- Archives (reviewer): `Archives/Packer.swift:272,375`, `Unpacker.swift:370`, `ArchiveCommands.swift:147,177`, `ArchiveFileSystem.read(_:)` :351 and timer/stop uploads (`OpenArchive.swift:1361`, a private flag nobody can set) use neither the flagged variant nor `interrupting`. Cancel hangs on a stalled server.
- Viewer / FileProperties (reviewer): `Viewer/Model/FolderSummary.swift:25`, `FileProperties/SpaceCalculator.swift:95` and `AttributeChange.swift:298` list without the flag. `CommentStore` waiters (`FileProperties/Descript.swift:193`) have no timeout.
- Mine: `SystemTools/DirectoryList.swift:68`, `MultiRename/RenameRun.swift:210,265` and `BranchWalker` when called without a flag use the unflagged `list`.
- Network (reviewer): `FTPSession.loginLock.lock()` (:113) is untimed, and `SFTPSession.connectLock` cannot be cancelled for mkdir, remove, rename and setAttributes.

**8. MEDIUM-LOW — one GCD worker blocked per launched program.**
- `Configuration/CommandRunner.swift:261-264` parks a `global(.utility)` worker in `ended.wait()` for the whole life of every non-waited child; :267 does the same on `.userInitiated` when waiting.
- If enough long-lived children accumulate to exhaust the pool's thread limit (64 is my recollection of that limit, not checked against this OS version), work submitted to that pool stops being served. That includes the archive flush timers (`OpenArchive.swift:571,714`), `ColumnValueStore` (`AFMShell/Panel/ColumnValueStore.swift:89`) and the volume refresh.
- Fix: use `terminationHandler` alone, with no waiting thread.

**9. MEDIUM-LOW — AppKit objects can be deallocated off main.**
- `TextPagerView` (`Viewer/UI/TextPagerView.swift:152`; reviewer): the `self?.` call on an indexing thread can hold the last reference.
- `FindFilesWindowController.askSpotlight` (`FindFiles/FindFilesWindowController.swift:339-347`): the outer global-queue closure captures `self` strongly and may release it last, after the inner main block has run.
- Fix: capture weakly in the outer closure and take the strong reference only inside `main.async`.

**10. MEDIUM-LOW — Pause does not pause parallel checksum jobs (reviewer).** `FileTools/ToolRun.swift:99-105` holds `reportLock` across `monitor.report`; other hashing threads fail `try()` and carry on. Fix: every thread passes the gate, outside `reportLock`.

**11. LOW-MEDIUM — `TreeCache`.**
- Race: `entry(for:)` returns `slot.entry` after unlocking (`Places/TreeCache.swift:89-92`), while `note()` appends to `slot.entry.paths` under the lock on the `updates` queue (:147-149). Fix: copy the entry while locked.
- Stale store: a cancelled, non-rescan scan that returns late stores its partial tree (`DirectoryTreeWindowController.swift:283-284`) over the complete one a newer scan just stored. Fix: carry a per-root store ticket.

**12. LOW-MEDIUM — `CommentStore` keeps a stale read after a write (reviewer).** `FileProperties/Descript.swift:198-212`. Fix: a per-key generation bumped by `forget`.

**13. LOW — `LocalFileSystem.places()`.** If the first `readPlaces()` hangs on a dead mount, `knownPlaces` stays nil and every call on main waits its full 1 s (`LocalFileSystem/LocalFileSystem.swift:674-675`). `isReadingPlaces` also stays true, so the list never refreshes. Fix: remember that the grace period has been spent, and read volumes with a timeout.

**14. LOW — pool scheduling.** Pool threads always take `open.first` (`Parallel.swift:226`). While an older job with slow I/O pieces is open, a later main-thread job gets no helpers, and the extra threads started by `watchLater` take the old job too. Main also waits on a plain semaphore for `.userInitiated` threads, so there is no priority donation. Fix: prefer the job opened by the highest-QoS caller, or by the main thread.

**15. LOW — Network (reviewer).**
- Keep-alive pulls all stale connections at once and pings them serially, up to 5 s each, while they still count against the limit (`FTPSession.swift:359-367`).
- `resolveLinksLater` is unbounded per session and can raise a login dialog from a background task (:423-426).
- `SFTPSession.disconnect()` during a login leaves ssh alive (:127, :162).
- No 421 retry for the second "first" thread (:110, :164).
- `FTPReader.close()` from another thread races `seek()` (:663-679).

**16. LOW — job service re-entrancy (plausible).** In `ProgressJobService.swift:81-85`, `running = nil` is set before `completion(result)`. A completion that shows a modal alert leaves `isBusy == false` with `onBusyChanged` not yet sent, so blocked commands can run under the alert. Fix: run completions after `startNext()`, or keep a "completing" state.

**17. LOW — FSEvents teardown (plausible, unverified).** `DirectoryWatcher.stop` (:104-112) releases the stream, and with it the `Watch` context, from main with no documented guarantee that a callback on `streamQueue` has finished. Fix: `streamQueue.sync {}` after `FSEventStreamInvalidate`.

**18. LOW — Viewer leftovers (reviewer).** `TemporaryCopies` owner key outlives its pane and `removeAll` races an in-flight copy; `Splitter` closes its reader twice on error; `createChecksums` clears the selection with no directory check (`FileTools/FileToolsPlugin.swift:291`).

## (e) Verified as sound

- **`ParallelPool`:** no lost wake-ups (the sleeper is set and signalled under the lock), nested calls cannot deadlock, the closure never outlives the call, and worker exit accounting is correct.
- **`CancellationFlag`:** handlers run outside the lock; registration and deregistration are safe.
- **`ListingCache`:** the ticket/clock scheme rejects out-of-order stores.
- **Panel stale-result guards**, all re-checked on main after the hop:
  - `loads[id] === load` (identity, strongly held).
  - `cancelLoading` and `tabsChanged` purge every `ObjectIdentifier`-keyed table (`PanelViewController.swift:369-388`), so there is no address-reuse hazard.
  - `filterJobs` number plus `listVersion`; `volumeAsks` counter plus weak tab.
  - Size results: flag plus directory.
  - `ColumnValueStore` generation; `ThumbnailStore` token; `ReadAhead` identity; `ViewOptions` sort with `pendingOrders` plus `listVersion`.
- **Other background → main guards:** FindFiles (`search === search`), Sync (`running === comparison`), Compare (`running === cancellation`, find generation), MultiRename (cancellation identity, list generation), directory tree (generation, `showCounter`), Viewer (reviewer: all generation-guarded).
- **`FileJob`:**
  - Semaphore and group are balanced on all paths; the job thread never waits for a slot while holding `decisions`.
  - `monitor.report` is serialised by `counters`, so `ProgressSheet.lastReport` is not raced. The same holds for ToolRun, ProgressMeter and SyncExecutor.
  - `interrupting` tokens are released before `reader.close()`.
- **`interrupt()` implementers** (reviewers): FTP, SFTP, archive member readers, the ZIP writer and viewer pooled readers are safe at any time, repeatedly, after close, and non-blocking, apart from finding 4. Forwarders (VirtualFolders, Archives `.outside`, `CachingWriter`) return or forward the real reader and pass the flag.
- **Condition waits:** all are predicate loops with broadcast: `PauseGate`, `placesCondition`, `Walk`, `JobStack`, `FTPSession`, `NetStream`, `Pending`, `CommentStore`.
- **Semaphores:** all start at 0 and are never destroyed below their initial value; `Pool.slots` is fully restored before release.
- **No main-thread provider I/O** in AFMShell or the plugins listed in section (b); `ProgressSheet.ask` is never reached from main.

## (f) Not covered

- **Not read in full:** DirectorySync (`SyncPlan`, `SyncWindowController`), CompareContent (`TextDiff`, window controller), MultiRename (window controller, `RenameRun` bodies), most of Configuration, Selection, Navigation, FolderTabs and the SystemTools UI, plus `FileJob.swift` 960-1270 and 1490-1640. I grepped these for primitives and provider calls and read around the hits.
- **Not verified:** FSEvents teardown semantics (finding 17); the exact Network write path into the ask sites in finding 1.
- **Reviewer gaps:** parts of `ZipFormat.swift` and `ArchiveLocation.swift`, and of `Hashes.swift`, `Transcoding.swift` and `ViewerEncoding.swift`, were only grepped.
- **Not done:** no ThreadSanitizer or stress run. The races in findings 3, 4, 5 and 11 are proven by reading, not reproduced.
