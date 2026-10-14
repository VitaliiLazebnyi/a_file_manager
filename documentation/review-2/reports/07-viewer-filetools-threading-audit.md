# Viewer/FileTools threading audit

**Threading audit: Viewer, FileTools, FileProperties (read-only, nothing built or run)**

I found no lock-order cycle and no deadlock in scope. Most of the locks you suspected of freezing the UI are never held across provider I/O. I read every concurrency-relevant file completely; of `Hashes.swift`, `SplitCombine.swift`, `Transcoding.swift`, the first 330 lines of `ViewerPane+Actions.swift`, `ViewerEncoding.swift`, `HTMLText.swift`, `ViewerDetection.swift`, `ViewerSettings.swift` and `PropertyDetails.swift` I read only the concurrency-relevant parts and grepped the rest.

Paths are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/`.

## Bugs

Each was confirmed by reading both paths unless marked otherwise.

**1. MEDIUM: blocking close and delete on the main thread**
- Path: `ViewerPane.stopWork` (`Viewer/UI/ViewerPane.swift:324`) calls `loaded?.source.close()`, which runs `CachedByteSource.close` (`Viewer/Model/ByteSource.swift:499-502`), then `ProviderByteSource.close` (`:182-188`), which calls `FileReader.close()` on up to `activeProcessorCount` idle readers, then `spill.discard()` (`:315`).
- `stopWork` is main-only. Its callers are `load` (`:251`), `clear` (`:329`), `ViewerWindowController.windowWillClose` (`:115`) and `QuickViewPanel.remove` (`:93`).
- Same class:
  - `ViewerPane.swift:289` closes the source of a stale load on main.
  - `ProviderByteSource.deinit` (`ByteSource.swift:190`) closes readers on whichever thread drops the last reference, which is main for `loaded = nil` at `ViewerPane.swift:253` and `:331`.
  - `temporaryCopies.release` (`ViewerPane.swift:317`, and `:146` in deinit) runs `evict`, which calls `FileManager.removeItem` on main (`RichViews.swift:117`).
  - `ViewerPlugin.stop` (`ViewerPlugin.swift:112`) runs `removeAll`, which deletes the whole root on main (`RichViews.swift:127`).
- Effect: every cursor move in quick view runs this. A network reader whose `close()` does a round trip stalls the UI.
- Fix: hand the source and the doomed folders to a background queue to close and delete.

**2. MEDIUM-LOW: `TextPagerView` can be deallocated on an indexing thread**
- Access 1: `TextPagerView.swift:152`, `document.buildIndex(parallel:) { self?.indexProgressed() }`. The `self?.` takes a temporary strong reference on a `concurrentPerform` or global worker for the duration of `indexProgressed` (`:157-171`).
- Access 2: main releases the pane and pager (window close, quick view hidden).
- Interleaving: the worker holds the temporary +1, main drops its reference, the worker's release is the last. `NSView` dealloc and `deinit` (`:127-132`, including the `NSScroller` subviews) then run off-main.
- Fix: capture a small non-view coalescer object (the lock and flag) and take the view strongly only inside the `main.async`.

**3. MEDIUM-LOW: Pause does not pause parallel checksum jobs**
- `ToolRun.advance` (`FileTools/ToolRun.swift:99-105`) holds `reportLock` across `monitor.report`. `monitor.report` enters `PauseGate.passWhenOpen` and blocks while paused (`AFMShell/Interaction/ProgressJobService.swift:172-178`, `:207`).
- Every other hashing thread (`ChecksumFiles.swift:216`, on Parallel pool threads) takes the non-forced path, where `reportLock.try()` fails and it returns and keeps hashing.
- Result: one thread pauses and the rest finish the job. The job thread then blocks at the forced `advance` (`FileToolsPlugin.swift:125`).
- `ProgressMeter` (`FileProperties/SpaceCalculator.swift:46-53`) holds its lock across the report, so there every thread stops; the two are inconsistent.
- Fix: call `gate.passWhenOpen` from every thread, outside `reportLock`.

**4. LOW-MEDIUM: `CommentStore` remembers a stale read after a write**
- T1: `comments(in:)` is in `load` (`FileProperties/Descript.swift:198`).
- T2: `setComment` moves the new file into place and calls `forget` (`:265`, `:208-212`).
- T1 then stores the old comments with a fresh timestamp (`:199-201`).
- `save`'s completion reloads the panels at once (`FilePropertiesPlugin.swift:325-326`). The Comment column gets the old text and, per the `ContentColumn` contract, the panel keeps it.
- Fix: a per-key generation bumped by `forget`; remember only if it is unchanged.

**5. LOW-MEDIUM: uncancellable directory listings in parallel walkers**
- `FolderSummary.measure` (`Viewer/Model/FolderSummary.swift:25`), `SpaceCalculator.measure` (`SpaceCalculator.swift:95`) and `AttributeJob.process` (`AttributeChange.swift:298`) call `list(_:showHidden:)` without the `cancellation:` overload that `ChecksumFiles.swift:250` uses.
- After cancel, or when the quick-view cursor moves on, in-flight lists run to completion while holding `viewer.work` threads and Parallel pool pieces.
- `CommentStore.load` (`Descript.swift:217-223`) reads without any flag. Every column thread for that folder then sits in `condition.wait()` (`:193`) with no timeout.
- Fix: use the cancellable overloads.

**6. LOW: `getpwuid_r` / `getgrgid_r` on the main thread**
- `AttributeDraft.fields` (`FilePropertiesPlugin.swift:466-467`) is called from `ask` (`:163`), which runs in a job completion on main.
- This can block with network directory services.
- Fix: resolve the names in the "Reading attributes" job (`:152`).

**7. LOW: `TemporaryCopies` owner key outlives its pane**
- `localURL` on `viewer.work` (`ViewerPane.swift:562`) registers the copy under `ObjectIdentifier(pane)` (`RichViews.swift:81`, `:92`), possibly after the pane's deinit released that owner (`ViewerPane.swift:146`).
- The copy is then never idle and never evicted until `removeAll`. A new pane at the same address would release it, which is harmless.
- Separately, `removeAll` (`RichViews.swift:121-127`) races an in-flight copy: the folder is deleted, then `copies[key]` is registered pointing at a missing file.
- Fix: a per-pane token object with a liveness check, and an epoch check before registering.

**8. LOW: smaller items**
- `Splitter` closes its reader twice on error (`SplitCombine.swift:120`, after `ToolRun.read`'s defer at `ToolRun.swift:130`).
- `createChecksums` clears the selection with no check that the panel still shows the same directory (`FileToolsPlugin.swift:291`); `verify` does check (`:318`).
- After `stopWork`, the pager still shows the old document with cancelled flags. Scrolling during the next load fetches nothing and blanks the view (`TextPagerView.swift:353-366`), contradicting "what is shown stays" (`:234`).
- `afterLoad` actions survive a dropped fetch and later run against a different document (`:384-403`).
- `isFetching` is write-only.

## A. Lock table

None of these locks is held across `Parallel.map` or `concurrentPerform`.

| Lock | Guards | Called while held / nesting | Worst-case hold |
|---|---|---|---|
| `ProviderByteSource.lock` `ByteSource.swift:96` | `idle` | Nothing. Sites 167-169, 175-178, 183-186 (main via `close`). | µs |
| `DiskBlockCache.budget` (static) `:203` | `held` | Leaf. Taken under the instance lock at 290, 296, 307; alone at 324. | µs |
| `DiskBlockCache.lock` `:231` | fd, bitmap | `pread` (277); `open`/`unlink`/`pwrite` (293-303); then `budget`. Sites 245, 251, 259, 271, 286, 315. Main takes it via `discard` (bug 1). | One 256 KB temp-disk I/O |
| `CachedByteSource.lock` `:345` | `blocks`, `order` | Nothing; fetches happen outside. Sites 405-407, 421-432, 477-486, 489-495. | µs to 64 MB slicing at 421-432 |
| `CharacterBoundaries.lock` `CharacterBoundaries.swift:20` | `known` | Leaf. | µs |
| `CharacterBoundaries.computing` `:23` | Single-flight boundary search | Held 91-124 across `source.read` (105, 132), i.e. provider I/O; then `lock`. Reached only from `ViewerSearch.decoded:274` on `viewer.work` and Parallel threads. Never main. | A whole-file backward read in a run of pure two-byte text. Waiters are uncancellable until the holder's read is interrupted. |
| `TextDocument.boundariesLock` `TextDocument.swift:158` | Lazy `boundaries` | Then `CodeTable.lock` (via the `CharacterBoundaries` init, line 28). Main takes it at `ViewerPane+Actions.swift:420`. | One table build |
| `TextDocument.errorLock` `:174` | `fetchFailure` | Then `TextRowIndex.lock` (189). Main takes it at `ViewerPane.swift:728`. | µs |
| `TextRowIndex.lock` `TextRows.swift:250` | All index state | Then the previous index's lock (305-309 into 360; acyclic, `previous` set to nil). No I/O. Main takes it via `rowCount`, `isComplete`, `indexedThrough` (draw `TextPagerView.swift:828`, 174, 438, status text). | µs |
| `Locked.lock` `:367` | Counter | Leaf. | µs |
| `CodeTable.lock` (static) `ViewerEncoding.swift:132` | `tables` | Held across table construction (136-141; a double-byte table is on the order of 24k CFString conversions, CPU only). Taken on every table decode (184). Main takes it at `ViewerPane.swift:468` (binary/hex `TextDocument.init`) and `Actions:420`. | One table build; I estimate tens of ms, unmeasured |
| `LatestNumber.lock` `TextPagerView.swift:7`, `progressLock` `:107` | Counters, flag | Leaf. | µs |
| `TemporaryCopies.lock` `RichViews.swift:29` | `root`, `copies`, `clock` | `newFolder` (132-142) holds it across two `createDirectory` calls. Other sites 73-82, 88-95, 101-103, 109-116, 122-126. Main takes it via `release` and `removeAll`. | ms |
| `ToolRun.lock` `ToolRun.swift:36` | Counters, lines | Leaf. | µs |
| `ToolRun.reportLock` `:38` | Report order | Then `lock` (101), then `monitor.report` (105), which enters the `PauseGate` condition and does `main.async`. | The whole pause |
| `AttributeJob.lock` `AttributeChange.swift:260` | `outcome` | `displayPath` (321). | µs |
| `ProgressMeter.lock` `SpaceCalculator.swift:35` | `done`, `lastReport` | `displayPath` autoclosure, then `monitor.report` (53) and the `PauseGate`. | The whole pause (documented as intended) |
| `CommentStore.condition` `Descript.swift:170` | `remembered`, `beingRead` | Not held during `load`. | µs; the wait is unbounded |
| `LocalInfo.lock` (static) `LocalInfo.swift:30` | Name caches | Leaf; `getpwuid_r` runs outside it. | µs |

Queues, timers and work items:
- `viewer.rows`, serial (`TextPagerView.swift:81`).
- `viewer.work`, concurrent (`ViewerPane.swift:85`).
- Non-repeating `Timer` (`ImageCanvasView.swift:323`).
- `resizeWork` `DispatchWorkItem` (`ViewerPane.swift:640`).
- `asyncAfter` (`ViewerWindowController.swift:150`).
- Scope contains no `Thread`, `DispatchSemaphore` or `DispatchGroup`.

Main-thread freeze candidates:
- The only locks main shares with a holder that is doing I/O are `DiskBlockCache.lock` and `TemporaryCopies.lock`, both local disk, both in the bug 1 paths.
- `computing`, `ProgressMeter.lock`, `reportLock` and the `CommentStore` condition are never taken on main.
- `TextRowIndex.lock`, `CachedByteSource.lock`, `budget` and `LocalInfo.lock` are never held across I/O.

## B. Blocking calls on main
- Bug 1: reader close, fd close, `removeItem`.
- Bug 6: `getpwuid_r` / `getgrgid_r`.
- `CodeTable` build: `ViewerPane.swift:468`, `Actions:420`.
- `cancel()` on main runs `reader.interrupt()` handlers, which the contract allows. Sites:
  - `ViewerPane.swift:143-144`, `312-314`, `319`, `451`, `697`
  - `TextPagerView.swift:128-131`, `145`, `182`, `237-240`, `378`
  - `Actions:200`
  - `ViewerWindowController.swift:42`
- `fileSystems.location(from:relativeTo:)` is called on main at `FileToolsPlugin.swift:109` and `:280`. Whether it does I/O is outside my scope; I did not check.
- I found no `Parallel.map` and no provider `read`, `list` or `item` call on main in scope.

## C. Stale-result guards

Every guard below is checked on main after the hop. No counter is ever reset.

| Hop | Guard | Verdict |
|---|---|---|
| Rows `TextPagerView.swift:362` | `generation == wanted` and `document === document`; pre-check via `LatestNumber` (356) | Sound. The closure holds the document, so no ABA. |
| Reveal `:528`, go-to-line `:585` | `revealGeneration` and document identity | Sound |
| `restoreCaret` `:218` | Document identity and `caretToRestore == offset` | Sound |
| Index progress `:163` | Coalesced; reads live state | Sound |
| Load `ViewerPane.swift:287` | `loadGeneration` and `!cancellation.isCancelled` | Sound; closes the stale source on main (bug 1) |
| Folder summary `:345` | Same | Sound |
| `stripHTML` `:492` | `loadGeneration`, `presentGeneration`, `mode == .html` | Sound |
| Image, PDF, rich, first frame `:545`, `:564` | `isCurrent`: both generations, both flags, `!isTextual` | Sound |
| Scaled bitmap `ImageCanvasView.swift:129` | `generation == token`. The key uses `ObjectIdentifier(frame)`, but every frame swap calls `invalidate` (221, 244). | Sound but fragile |
| Search result `Actions:434`, progress `:428` | `loadGeneration`, source identity, `!cancel`; `activity.cancel === cancel` | Sound |
| Print `:644` | `loadGeneration`, cancel | Sound |
| `copySelection` `:464`, `withSelectedText` `:528` | None; the latter has no cancellation either | By design; low |
| Encoding detection | Part of the `Loaded` value, covered by the load guard | Sound |
| Media title `RichViews.swift:217` | Weak self only | Acceptable; one view per presentation |
| Space and folder sizes `FilePropertiesPlugin.swift:249`, `:275` | `model.directory.isSameLocation` | Location ABA is harmless; results are name-keyed |
| Attributes, comment, link-target completions | None (dialogs, or `panel.show` at `:385`) | Low |
| Checksum completions | `verify` checks the directory (`FileToolsPlugin.swift:318`); `createChecksums` does not (`:291`) | Bug 8 |
| Descriptions | No generation | Bug 4 |

## D. Shared state
- Sound as written:
  - `TextRows.swift:344`: all state goes through `synchronized`; `bounds` is read-only after setup.
  - `Hashes.swift:447`: disjoint output slots; the `@unchecked Sendable` wrapper at `:459` is justified.
  - `AttributeChange.swift:289`: `outcome` is under the lock; owner and group IDs are set before the fan-out; the read at 283-284 comes after the join.
  - `ChecksumFiles.swift:210-217`: hashers are per file; the nested map uses one thread per hasher and is joined before the next block. `ToolRun.create` and `overwritesAll` are never reached from the parallel body.
  - `SpaceCalculator.swift:75-107`: the struct is captured by value.
  - `FolderSummary.swift:35`.
  - `ViewerSearch.swift:163`; `lastReport` at `Actions:422` is touched only on the find caller's thread.
- `viewer.work` blocks share only thread-safe objects: byte sources, `TextDocument`, `CharacterBoundaries`, `TemporaryCopies`, flags.
- Benign: `TextRowIndex.segmentsReused` is written under the lock (350) and read unlocked (288, `TextDocument.swift:145`). It is a test-only accessor.
- Fragile: `var written` at `FileToolsPlugin.swift:285-288` is written on the job thread and read on main in the completion. Only the job-to-completion hop orders them.
- Static mutable state (`DiskBlockCache.held`, `CodeTable.tables`, `LocalInfo` caches) is all locked. There are no raced lazy vars.
- Deinits:
  - `TextPagerView`: bug 2.
  - `ViewerPane`: main only. I checked every `viewer.work` closure for a strong self capture and found none. It does I/O (bug 1).
  - `ByteSource`: any thread.
  - `ToolOutput.deinit` runs `abandon`, which is provider I/O, but every output is finished or abandoned explicitly on the job thread.
  - Hashers: memory only.
  - `MediaView`, `ImageCanvasView`: main.

## E. Condition and timers
- `CommentStore` (`Descript.swift:187-194`) uses a correct predicate loop. The reader broadcasts under the lock (203), and `load` cannot throw. There is no timeout or cancellation (bug 5).
- Waiters are column threads and job threads. No in-scope caller is main.
- The image timer is non-repeating, captures self weakly, and is invalidated in `deinit`, `show` and `replaceFrames`. `resizeWork` and `CursorFollower` capture weakly with a generation. Nothing repeating retains its target.

## F. Cancellation
- A pooled reader cannot be handed to two threads: `checkOut` pops under the lock.
- An interrupt cannot hit a pooled reader. The token is released (`ByteSource.swift:54`) before the `isCancelled` check at `:158`, and `CancellationFlag.cancel` sets the flag and snapshots handlers in one critical section. Either the check sees the cancel and the reader is closed, or the handler was already removed. This also holds through a `LinkedCancellation` chain.
- A late `interrupt()` after `close()` is possible and relies on the contract's "any time".
- A short block could be cached at `ByteSource.swift:487-493` only if a provider returns empty instead of throwing on interrupt. That would be a provider contract violation; speculative.
- `close()` during active reads closes only idle readers. Readers in use are checked back in afterwards and stay open until deinit. For example, the Save As job reads with `monitor.cancellation`, not the pane's flag.
- `windowWillClose` and `ViewerPlugin.stop` wait for no background work; they only do the bug 1 I/O. `stop` iterates a copy of `windows`.
- `LinkedCancellation` tokens are kept alive by the fetch closure and the pager, and are unhooked on release.

## G. `monitor.report` and `monitor.ask`
- `report` at `Actions:560`: single job thread.
- `report` at `ToolRun.swift:105`: reached from Parallel threads but serialized by `reportLock`, so `lastReport` is safe.
- `report` at `SpaceCalculator.swift:53`: reached from Parallel and `concurrentPerform` threads, serialized by the meter lock. Each job has one meter; `PropertySheet` shares its meter with its calculator.
- `ask`: only `ToolRun.swift:60`, via `create` (`:171`), on the job thread, never from the parallel body and never on main. No in-scope lock is held. A reader and its interrupt token are open across the `main.sync` (`SplitCombine.swift:95`, `Transcoding.swift:495`).
- No unserialized concurrent `report` exists in scope.

## H. Fan-out
- One `viewer.work` block per quick-view cursor rest (`load`, `showFolder`), unbounded if a provider ignores cancellation.
- One `global().async` plus `concurrentPerform` per relayout (`TextPagerView.swift:151`). Normally at most two are live: the shown and the pending document.
- One uncancelled `global().async` per distinct zoom size (`ImageCanvasView.swift:127`), up to 160 MB each during a pinch.
- `AttributeJob` nests `concurrentPerform` around blocking provider I/O on GCD workers.
- BLAKE3 runs `concurrentPerform` inside nested `Parallel.map`, which oversubscribes CPU.
- `viewer.rows` is serial. A slow reveal or caret lookup blocks row fetches behind it, and `restoreCaret` is cancellable only by the document flag.
- One `global().async` per Finder Info request.
