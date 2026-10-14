# Review AppKit shell second round

# Second-round review of `Sources/AFMShell` (read-only)

I read every file in `Sources/AFMShell` in full, plus the kernel and plugin code the shell calls into. Nothing in the project was modified; three small experiments live in the scratchpad under `review2/shell/`. "Confirmed" means proven by code reading or by one of those experiments; "plausible" means the logic is clear but not run end to end.

All shell paths below are under `/Users/cm0k/Claude/Projects/TotalCommander/Sources/AFMShell/`.

## Findings, most severe first

### 1. HIGH · freeze · `provider.watch()` runs on the main thread and calls `realpath()`
- **Where:** `Window/PanelCoordinator.swift:171-180`, called from `:53` (init), `:191` (`panelDidChangeLocation`) and via `Panel/PanelViewController.swift:409` (tab switch).
- **What:** `updateWatchers()` calls `provider.watch(directories)` synchronously. `LocalFileSystem.watch` (`Plugins/LocalFileSystem/LocalFileSystem.swift:840`) goes to `DirectoryWatcher.watch` → `resolve` → `realpath()` for every directory. `watch` is not on the provider contract's list of main-thread-safe calls (`FileSystemProvider.swift:158-160`).
- **Scenarios:**
  - The last session ended on `/Volumes/share/x` and the share is now dead. `PanelCoordinator.init` calls `updateWatchers()` before anything is read, so launch blocks in `realpath` with no window.
  - The right panel sits on a share that stalls later. Any navigation in the left, local panel changes the location set and re-resolves both directories, so the app freezes.
  - Switching to a restored tab on a dead share posts `panelDidChangeLocation` at once (line 409), before its read.
- **Note:** the comment at `PanelViewController.swift:735-737` shows the hazard is known; only one path was deferred.
- **Fix:** create and replace watchers off the main thread on a serial queue, with a generation check when installing. Watch only directories whose listing just succeeded. Do not re-resolve a panel's directory that did not change.
- **Confidence:** confirmed by reading.

### 2. HIGH · performance/network · read-ahead loops forever on a remote folder with more than 300,000 entries
- **Where:** `Panel/ReadAhead.swift:133-140` (`ended`) and `:102-112` (`dwellEnded`); `AFMKernel/Panels/ListingCache.swift` `store` (`maxEntries = 300_000`).
- **What:** `ListingCache.store` refuses a listing above `maxEntries` and returns false. `ended()` re-arms the dwell whenever `resting != nil`. `dwellEnded()` only checks `cache.age` (nil here) and `failures` (not a failure), so it starts the read again.
- **Scenario:** the cursor rests on a 1M-entry folder of a share. The whole folder is listed, 1M `FileItem`s are allocated and sorted on all cores, the result is thrown away, and 0.4 s later it starts again, for as long as the cursor stays. This contradicts the class comment "One listing per rest of the cursor".
- **Fix:** record per location in `ReadAhead` when it was last read ahead, whatever the cache did, and honour `freshEnough` against that. Or do not re-dwell in `ended()` for the target just read. Ideally stop the read once it exceeds `maxEntries`.
- **Confidence:** confirmed by reading.

### 3. MEDIUM-HIGH · freeze · `NSWorkspace.icon(forFile:)` runs on the main thread for every newly drawn row
- **Where:** `Panel/FileListColumn.swift:114-122`; callers `Panel/PanelViewController+Lists.swift:343`, `Panel/FileGridView.swift:309/344/370`.
- **What:** the call touches the file. It is gated only by `model.volume?.isLocal`, which describes the directory, not the items.
- **Scenarios:**
  - `VirtualFileSystem.volume` returns `isLocal: entries.allSatisfy(\.isFileURL)` (`Plugins/VirtualFolders/VirtualFileSystem.swift:432`). A search result holding files on `/Volumes/<share>` gets one server round trip per row in `viewFor`/`draw`; a stalled share hangs the main thread while scrolling.
  - The same applies to symlinks in a local folder that point to a share, a spun-down external disk, File Provider/iCloud items, and disk images hosted on a share.
  - `ArchiveFileSystem` builds `VolumeInfo(name:)` with the default `isLocal: true`.
- **Cache behaviour:** the cache is cleared whole at 4000 entries (line 119). This is not a steady-state thrash, but every 4000 new rows the visible rows of both panels miss again on the main thread.
- **Fix:** never ask for a file's own icon on the main thread. Return the type icon at once, fetch own icons on a small background queue keyed by path+date, cancel on scroll, and redraw the row on arrival (the `ThumbnailStore` pattern). Use LRU instead of clear-all. Decide per item (item volume or mount point), not per directory.
- **Confidence:** confirmed that the call is on main and that the virtual-folder path reaches it; the stall itself is plausible.

### 4. MEDIUM · freeze · a job that never returns blocks commands forever, and Quit hangs
- **Where:** `App/Shell.swift:103-107`; `Interaction/ProgressJobService.swift:111-118` and `:69-94`.
- **What:** `applicationShouldTerminate` returns `.terminateLater` and replies only when the queue is empty. `isBusy` (and so `commands.isBlocked`) stays true until `work` returns. There is no timeout and no "abandon".
- **Scenario:** a copy to a stalled NFS/SMB mount sits in a kernel `write`. Cancel shows "Stopping…" indefinitely and every file or panel command stays rejected. Cmd+Q then puts the app into the terminate-later modal loop with no way back, so the user must force-quit.
- **Fix:** after N seconds of "Stopping…" offer "Quit anyway" or "Abandon job". On quit use `cancelAll` with a deadline, then `reply(true)`.
- **Confidence:** confirmed by reading; depends on a provider that cannot abort.

### 5. MEDIUM · correctness · every successful reload of the active tab posts `.locationChanged`
- **Where:** `Panel/PanelViewController.swift:857`.
- **What:** `if tab === self.model { host?.panelDidChangeLocation(self) }` runs after quiet reloads too (app activation, watcher events, the refresh after each job). `QuickViewPanel` dismisses itself on `.locationChanged` of the covered panel (`Plugins/Viewer/UI/QuickViewPanel.swift:45-49`).
- **Scenario:** Quick View is open. Switching to another app and back, or any other program touching the covered folder, closes it.
- **Side effects:** the prompt update, the Places tracker and bar validation also run on every watcher tick.
- **Fix:** keep the last location announced per panel and post only when it differs. That also fixes finding 11.
- **Confidence:** confirmed by reading.

### 6. MEDIUM · correctness · in-place rename is killed by any redraw, and the panel loses the keyboard
- **Where:** `Panel/PanelViewController.swift:427-429` (`redraw()` → `cancelRename()`), `:1114-1127`.
- **What:** every `.contents` change of the active tab cancels the edit and discards the typed text. Sources include `setVolume` after `volumeInfoDidChange` (triggered by any listing on the same volume, such as the other panel's watcher reload), a piece arriving, the fresh listing replacing a remembered one, and settings changes.
- **Reachability:** Rename is enabled while the tab is still loading or refreshing (`FileOperationsPlugin.swift:67-68`), so "enter a remembered share folder, start renaming, fresh listing lands a second later" is routine.
- **Focus loss:** `cancelRename` removes the field without `makeFirstResponder(listView)`. The experiment `fr.swift` shows the window itself becomes first responder, so keys beep until the user clicks.
- **Fix:** do not cancel for changes that keep the row (volume, flags); re-anchor the editor by item name after a reload. When cancelling programmatically, restore the first responder if the field had it.
- **Confidence:** confirmed (the responder part by experiment).

### 7. MEDIUM · threading/"stuck loading" · a joined read-ahead cannot be cancelled, and a retry re-joins the same stalled read
- **Where:** `Panel/ReadAhead.swift:147-156`; `Panel/PanelViewController.swift:568, 574-588, 714, 791-792`.
- **What:** the panel's `Load.flag` is not connected to `reading.cancellation`. After `join` the reading "runs to its end even if the panel moves on".
- **Scenario:** read-ahead of folder F starts and the server stalls. Enter joins it and shows "Reading F…". The user navigates away and comes back; `join` matches the same uncancelled read again. A normal load's cancel would have let the provider close the hung connection and reconnect.
- **Side effect:** `reading != nil` also disables all further read-ahead for the session.
- **Fix:** when the last waiter is superseded, cancel the reading (chain via `flag.onCancel`). Do not join a reading older than a few seconds.
- **Confidence:** plausible.

### 8. MEDIUM · threading · modal dialogs are started from inside main-queue blocks, where a nested run loop does not drain the main queue
- **Evidence:** `nested.swift` shows a nested run loop inside `DispatchQueue.main.async` does not run other main-queue blocks, while one started from a run-loop callback does.
- **Where:**
  - `Panel/PanelViewController.swift:682-684` ("The folder cannot be read!" alert).
  - `Panel/PanelViewController+Interaction.swift:323` → `carryOut` (confirmation, then the plugin's copy dialogs).
  - `Interaction/ProgressJobService.swift:78-86` (every job `completion`).
  - `Interaction/ProgressJobService.swift:223` (`ask`, via `main.sync`).
  - Every `Load.complete` (plugin completions of `show`/`reload`).
- **Consequences:**
  - While such an alert is up, nothing dispatched to main runs: the other panel's pieces, watcher events, progress renders, every `asyncAfter` timer, and `ask` from a background-mode job.
  - `startNext()` waits for the dialog, so the next queued job does not start.
  - Anything a plugin opens from these callbacks that relies on main-queue delivery while modal hangs. Examples: `NSApp.runModal(for:)` windows with asynchronously filled content (`CommandBrowser`, `HotlistEditor`), or `NSApp.terminate` → `.terminateLater`, whose reply arrives via `main.async`.
  - The same command behaves differently from a menu or key (event context, queue drained) than from a drop or completion.
- **Fix:** leave the main queue before going modal, for example `RunLoop.main.perform(inModes: [.common])` or `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`, for `report`, `carryOut`, job completions and `Load.complete`. Or use sheets and non-modal alerts.
- **Confidence:** the mechanism is confirmed; the plugin-side hang is plausible.

### 9. MEDIUM · performance/freeze · a stale background quick-filter result falls back to filtering the whole list on the main thread
- **Where:** `Panel/PanelViewController+Interaction.swift:79-99`.
- **What:** `tab.setFilter(filter, prefiltered:listVersion:)` with a stale version makes the model filter `listedItems` itself, on main. `listVersion` moves with every arriving piece, every computed folder size and every reload.
- **Scenario:** typing a quick filter in a 1M folder that is still arriving makes every result stale, giving an O(n) `matches` pass on main per key burst. On top of that, the kernel's `setListed` re-filters the full list on main for every piece while a filter is set.
- **Also:** `narrowing` is ignored on the background path.
- **Fix:** on a version mismatch re-run the job in the background against the new list, never on main. Filter incoming pieces in the loader thread.
- **Confidence:** confirmed by reading.

### 10. MEDIUM · performance · no back-off between quiet re-reads
- **Where:** `Panel/PanelViewController.swift:814-818, 865-870`; `Window/PanelCoordinator.swift:136-152`.
- **What:** FSEvents deliver about 2 events/s per stream. A read longer than that marks the tab dirty and `rereadIfDirty` starts the next read immediately.
- **Scenario:** another program writes continuously into a 1M-entry folder that is shown. The app reads and sorts it on all cores back to back indefinitely, each round ending in an O(n) `tab.update` and a full `redraw()` on main.
- **Related:** after each job the plugin's `refresh` (not quiet) is followed by `jobsEnded` (quiet → dirty → second full read).
- **Fix:** enforce a minimum gap, e.g. `max(1 s, 2 × last read time)`, with one trailing coalesced reread. Skip the `jobsEnded` reread for directories just refreshed.
- **Confidence:** confirmed by reading.

### 11. MEDIUM-LOW · correctness · a location change is never announced when a load of the same location overtakes one that already opened it
- **Where:** `Panel/PanelViewController.swift:572, 670` (and `:720, 759`).
- **What:** `previousDirectory` is `tab.directory` at load start, which is already B once the 0.1 s timer has "opened" B.
- **Scenario:** click a drive button for a slow share; after "Reading…" click it again, or press Ctrl+R. The second load ends with B == B, so no `panelDidChangeLocation` is posted. The watchers stay on A, the command-line prompt shows A, and Places is not told.
- **Fix:** as in finding 5.
- **Confidence:** confirmed by reading.

### 12. MEDIUM-LOW · performance · drag and drop is O(s) on the main thread with heavy constants
- **Drag start** (`Panel/PanelViewController+Interaction.swift:265-272, 348-356`; `Panel/FileGridView.swift:452`): `operands()` is O(n), then one `NSPasteboardItem` (and in the grid one `NSDraggingItem`) per marked item. Measured in `bench.swift`: 0.30 s for creating 100k pasteboard items alone, before `writeObjects`. With 1M marked this is several seconds and gigabytes.
- **Hover** (`Panel/PanelDragAndDrop.swift:50-54, 114-120`): `isPointless` is cached per destination, but each newly hovered folder row costs O(s) `locationKey` constructions (two or three per source), roughly 0.5–1 s for 100k sources.
- **Drop side:** `pasteboardItems` is O(s) again per panel entered.
- **Fix:** use a single pasteboard item with a lazy provider, or cap the items and carry the rest in-process. Precompute once per drag the set of source parent keys and source keys; the check then becomes O(depth) per destination.
- **Confidence:** measured for creation; the rest by reading.

### 13. LOW-MEDIUM · performance · type-to-select is O(n) per keystroke on the main thread
- **Where:** `Panel/FileGridView.swift:126-134` via `Panel/PanelViewController+Lists.swift:149-155`; in the Full view NSTableView's own type-select calls `typeSelectStringFor` (`+Lists.swift:333`) for every row.
- **Measured:** 221 ms per key for 1M names when nothing matches.
- **Fix:** names are sorted, so binary search when sorted by name. Otherwise search in the background with a generation, or cap the work per key.
- **Confidence:** measured.

### 14. LOW-MEDIUM · threading/"stuck" · `ColumnValueStore` stops for good after one stalled value
- **Where:** `Panel/ColumnValueStore.swift:82-101`.
- **What:** there is one batch at a time. A `column.value` call blocked on a dead share leaves `isWorking` true; `reset()` does not clear it and there is no cancellation.
- **Effect:** plugin columns stay empty in every folder of that panel for the rest of the session.
- **Fix:** tie `isWorking` to the generation so a reset frees it, bound abandoned batches, and give `ContentColumn.value` a cancellation flag.
- **Confidence:** confirmed by reading.

### 15. LOW-MEDIUM · threading · blocking file-system work runs on `DispatchQueue.global`
- **Where:** `PanelViewController.swift:202, 627, 692, 744, 794, 825, 954`; `PanelLoading.swift:108`; `ColumnValueStore.swift:89`; `ProgressJobService.swift:76`.
- **What:** every retry on a stalled share parks another pool thread. Each Space on a folder (`:954`) does too, and `ParallelPool` adds more.
- **Effect:** once the constrained pool is exhausted, every panel read in every tab stops, and a newly started job's `work` never begins while `isBusy` stays true. The exact pool limit was not measured.
- **Fix:** use dedicated bounded queues or threads per provider or volume for blocking I/O.
- **Confidence:** plausible.

### 16. LOW · security
- **Drop type accepted from any application:** `Panel/PanelDragAndDrop.swift:24-28` accepts `afm.panel-item` from any app and turns it into URLs of any scheme. The drop kind (move vs copy) is derived from it. A foreign drag can therefore name `sftp://…`, archive or arbitrary local sources that the plugins will then open or move. Accept this type only when `info.draggingSource` is one of our own views, and verify that the scheme has a provider.
- **Untrusted names shown raw:** the path bar (`Panel/PathBarView.swift:95-103`), list cells, tab titles, tooltips, alerts and progress lines do not neutralise newlines or bidi controls (U+202E etc.). A name can display with a spoofed extension, or hide its second line in the 20 pt row. Map control and bidi-override characters to visible placeholders for display.
- **Not a defect:** file promises are not accepted.
- **Confidence:** confirmed by reading.

### 17. LOW · threading · progress and pause
- **`ProgressSheet.lastReport`** (`Interaction/ProgressJobService.swift:193, 209-213`) is unsynchronised. It is safe today only because the callers serialise their reports (`FileJob` under its `counters` lock; the Unpacker and Sync callers report from the job thread). A plugin reporting from parallel workers would race. Use a lock or an atomic.
- **Out-of-order reports** can make `latest` step backwards.
- **`ask` deadlocks or traps if called on the main thread** (`:222-230`): it uses `DispatchQueue.main.sync` without the `Thread.isMainThread` guard that `Kernel.askUser` has.
- **Pause holds the caller's locks:** `PauseGate` blocks inside `report()`, so a paused worker keeps whatever lock its caller holds. `FileJob` calls `report` under `counters`, so its sibling workers queue on that lock. If any main-thread code (for example an `ask` question closure) took that lock while paused, the UI would deadlock with Resume unreachable. Pause at a point where the caller holds nothing, or document the constraint.
- **`QueuedJob.start`** (`:72`) is never cleared after it ran, so a plugin that keeps the `JobHandle` keeps the `work` and `completion` captures alive.
- **Confidence:** plausible.

### 18. LOW · read-ahead details (`Panel/ReadAhead.swift`)
- A read cancelled because the cursor moved on, where the provider throws on cancellation, is recorded as a failure (`:125-126, 135`). Coming back to that folder gets no read-ahead for 60 s.
- `failures` is never pruned.
- **Confidence:** plausible.

### 19. LOW · performance · the 100 ms validation tick runs arbitrary plugin `enabled:`/`checked:` closures
- **Where:** `Window/MainWindowController.swift:98, 163-176`; `Window/ButtonBarView.swift:125-133`.
- **What:** the tick is triggered by `NSWindow.didUpdateNotification`, i.e. after every event. The default bar is O(1).
- **Costly closures, once the user puts them on the bar or holds the modifier that shows them on the F-key bar:**
  - Print: `!localFiles().isEmpty` → `operands().filter` is O(n) with marks (`SystemToolsPlugin.swift:54, 70`).
  - Paste: `pasteboard.canReadObject(...)` is IPC and may wait on a lazy provider (`ClipboardPlugin.swift:62, 129`).
  - Paste Path: `availableType` (`NavigationPlugin.swift:132`).
- **Fix:** require `enabled` to be O(1) and free of I/O, or memoise per panel-event generation.
- **Confidence:** confirmed by reading.

### 20. LOW · correctness · load state machine edges (`Panel/PanelViewController.swift`)
- **A non-quiet reload cancels a pending navigation** (`:819-822`): `refresh` or Ctrl+R within the first 100 ms of a navigation supersedes it and re-reads the old folder.
- **A failed non-quiet reload is silent** (`:828, 840-845`): `try?` swallows the error, and a partial list is marked complete by `finishLoading()`.
- **Completions never called:** for loads of a closed tab (`:374-375`) and after `cancelLoading()`.
- **Completion called too early:** a quiet reload that is turned away calls `completion` at once (`:816`), before any read.
- **Phantom history:** a folder that was "opened" at 0.1 s and then superseded stays in the history (`:603` with `.record`), so Back leads to a place that was never shown.
- **Empty flash:** the 0.1 s timer and the loader's first piece (also about 0.1 s) race. A folder taking just over 100 ms flashes empty with "Reading…" before its first piece; the same happens while a first/last piece is held for a background re-sort.
- **Rare main-thread sort:** if the order changes a second time during the background re-sort in `sorted()` (`:689-698`) or after `cache.entry(sortedBy:)` (`:744-749`), the model sorts the full list on main.
- **Confidence:** confirmed by reading.

### 21. LOW · freeze (bounded) · `places()` can wait up to 1 s on the main thread at launch
- **Where:** `Window/ButtonBarView.swift:191-192` (`DriveBarView.rebuild`, from the window's init) and `Panel/PanelViewController.swift:916`.
- **What:** the first call can hit `LocalFileSystem.places()`'s `placesCondition.wait(until: +1 s)` when the first volume scan is slow.
- **Confidence:** confirmed by reading.

### 22. LOW · leaks and unbounded state
- `dropSession` is not cleared when a drag leaves the table (only the grid clears it), so the source array is retained until the next drag.
- `FileListColumn.typeIcons` is unbounded by distinct extensions.
- `missedChanges` accumulates duplicates for the length of a job (`Window/PanelCoordinator.swift:139-141`).
- Closures of in-flight loads capture the `PanelViewController` and `PanelModel` strongly on background threads. The last release could happen off the main thread, but only at teardown.

## Main-thread cost per event
n = entries, v = visible rows, s = marked, t = tabs.

| Event | Cost | Notes |
|---|---|---|
| Key repeat, cursor | O(1) + panel-event subscribers | One `asyncAfter` per move for the read-ahead dwell |
| Insert / single toggle | O(v) redraw, O(1) totals | |
| Select all / invert | O(n) once | |
| Shift+click range | O(range) | |
| Mouse move | O(path depth) in the path bar | Also arms the validation tick |
| Scroll, table | O(v × columns) | One `icon(forFile:)` per new row (finding 3) |
| Scroll, Thumbnails | O(v) | Key strings rebuilt per event |
| Live resize | O(v) | Brief width is cached; divider math O(1) |
| Arriving piece or any `.contents` change | `redraw()`: O(v) `reloadData` + O(depth) path bar + O(t) tab bar + O(n) totals recount | Plus, in the kernel, an O(n) cursor lookup and, with a filter, O(n) filtering |
| Quiet reload result | O(n) | `update(with:)` diff (parallel, but blocks main) plus `redraw` if anything differs. Free space almost always differs. |
| Watcher event | O(1), then a full background read | Finding 10 |
| Progress report | O(1) | Throttled to 20/s |
| Validation tick | O(buttons × closure) | Finding 19 |
| Drag update | O(1) per known destination, O(s) per new one | Finding 12 |
| Drag start | O(n + s) | Finding 12 |
| Type-select | O(n) worst case | Finding 13 |
| Quick-filter keystroke | Debounced 0.1 s | Under 20k entries: O(n) on main. Larger: background with a generation, except finding 9. |

## Shared state touched off the main thread, and how it is protected
- **`Load.flag`, `Reading.cancellation`, size-calculation flags:** `CancellationFlag` (NSLock).
- **`PanelLoading.OrderBox`:** NSLock.
- **`ListingCache`:** one NSLock, not held while sorting.
- **`PanelLoading.start` locals:** owned by the one background closure; pieces are immutable values.
- **`ReadAhead`:** all state on main; the background side touches only the flag and the cache.
- **`ColumnValueStore`, `ThumbnailStore`:** main only. Batches copy what they need; QuickLook completions hop to main and are checked by token.
- **Load closure state** (`behind`, `isHolding`, `nothingArrivedYet`, `isShown`, `hasEnded`): main only.
- **`PauseGate`:** NSCondition.
- **`ProgressSheet.latest` and `rate`:** main only.
- **`ProgressSheet.lastReport`:** unprotected (finding 17).
- **`FileListColumn` icon caches:** main only (draw and `viewFor`).
- **`getmntinfo`'s static buffer:** used only from main, and nowhere else in `Sources`.

## Checked and found sound
- **Superseding:** every piece, end and timer callback is guarded by `loads[id] === load`. Completions fire at most once (`Load.complete`). A superseded load's `completion(false)` arrives after its successor is installed.
- **Piece ordering:** pieces and the end are FIFO on main. The `inOrder`/`isHolding` hold is correct, including a second order change during the re-sort.
- **Retries:** the one-shot automatic retry cannot loop, because it always takes the listed-reload path. `loadRestored` and `loadInitially` terminate at the root.
- **Tab bookkeeping:** `openedFrom` snapshots, the dirty set and all other per-tab dictionaries are pruned in `tabsChanged`. Identifier reuse is harmless (weak tabs, generation counters).
- **Stream contract:** `PanelLoader.stream` always delivers at least one batch unless cancelled, so `.success(nil)` cannot strand a current load.
- **Table safety:** row count and `viewFor` cannot disagree in a crashing way. Model changes reload synchronously on main, and `item(atRow:)` is bounds-checked.
- **Job queue:** FIFO order holds, completions that chain a new job work, `cancelAll` does not wait synchronously, and the main thread never blocks on a job. There is no `ask`-versus-quit deadlock on the normal quit paths (menu, button, AppleEvent). `jobsEnded` replays missed watcher events correctly.
- **Observers:** each is added once. The volume observer is removed in `deinit`. `volumeInfoDidChange` cannot sustain itself, because the provider measures at most once per age window. The validation tick has no feedback loop.
- **Tab drag loop:** it exits safely if the strip is rebuilt under it.
- **Quick filter:** debounce, generation and binding to the tab are correct.
- **`Parallel.map` on main:** the caller waits only for pieces of its own, CPU-only job, so stalled workers elsewhere in the pool cannot block it.

## Not reviewed
- Nothing was run against the real app, a real stalled mount or with TSan; the stall findings rest on documented syscall behaviour plus code reading.
- Plugin internals were read only where the shell calls into them. I did not check `FileJob`'s `ask` closures for lock use, or plugin completions for modal windows that depend on main-queue delivery.
- I did not measure whether `NSPasteboard.canReadObject` blocks on lazy data, or the exact GCD pool limit on this OS version.
- `Tests/` was not read.
