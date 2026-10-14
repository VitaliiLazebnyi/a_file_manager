# Review 2 — shell

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### S001 [finding, high] S4: applying a listing on main (setListed filtering, update(with:), dropMarksOfItemsNotShown, listVersion bumps forcing sorts/filters onto main)

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** AFMKernel/Panels/PanelModel.swift:497-501; AFMShell/Panel/PanelViewController.swift:646;
  AFMKernel/Panels/PanelModel.swift:392-422; AFMKernel/Panels/PanelModel.swift:559;
  Plugins/ViewOptions/ViewOptionsPlugin.swift:196-200
- **Basis:** measured
- **Detail:** setListed filters on the calling thread: each piece of a 1M folder with a display mask costs 494 ms;
  update(with:) costs 269 ms. update(with:) with 300k marks costs 309 ms, mostly dropMarksOfItemsNotShown; freeing the
  previous list adds about 100 ms. listVersion increases on every update even when nothing changed, so background sorts
  and filters lose their version check and fall back to main: setSort 327-341 ms, filter 380-580 ms (with 300k marks).
  In a 1M-entry folder receiving 5,000 events/s reloads chain back to back; the watcher delivers only about 2 hops/s.
- **Proposed fix:** Have the reader deliver the filtered list and surviving marks; do not bump listVersion when entries
  are unchanged; re-dispatch on a version mismatch instead of sorting on main; release old lists on a background queue;
  add a minimum gap between quiet reloads.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S002 [finding, high] B5: NSWorkspace.icon(forFile:) on main in every cell fill and grid draw

**Outcome:** fixed — see `status/shell.md`

- **Where:** AFMShell/Panel/FileListColumn.swift:118; AFMShell/Panel/PanelViewController+Lists.swift:337
- **Basis:** inferred (plausible)
- **Detail:** From viewFor and FileGridView.draw. Gated on volume.isLocal so network shares are safe, but a disk image
  mounted from a share or a failing external disk report as local and each uncached row then blocks. Rated high to
  critical.
- **Proposed fix:** Fetch icons asynchronously, as ThumbnailStore already does, and show the type icon meanwhile.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S003 [finding, high] S3: drag-over re-checks all sources for each new folder row (721 ms for 300k sources)

**Outcome:** fixed — see `status/shell.md`

- **Where:** AFMShell/Panel/PanelDragAndDrop.swift:50-54; AFMShell/Panel/PanelDragAndDrop.swift:114
- **Basis:** measured
- **Detail:** Called from DropSession.isPointless; locationKey is recomputed four times per source.
- **Proposed fix:** Precompute once per drag the set of source keys and of source parents; each row is then two lookups.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S004 [finding, high] S1: every key equivalent validates the whole main menu (320 of 320 items on an unbound key, 160 on a bound one), running heavy enabled/checked closures; about 0.35 s per shortcut at 1M / 300k marked

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** AFMShell/Window/MainWindowController.swift:236; Plugins/SystemTools/SystemToolsPlugin.swift:54;
  Plugins/SystemTools/SystemToolsPlugin.swift:70; Plugins/ViewOptions/ViewOptionsPlugin.swift:128;
  Plugins/FileProperties/FilePropertiesPlugin.swift:56
- **Basis:** measured
- **Detail:** mainMenu.performKeyEquivalent called validateMenuItem for 320/320 items on an unbound key and 160 on a
  bound one. Heavy closures: Print File Contents builds the operand list 224-256 ms; Only Selected Files rebuilds a
  `Set<String>` of all marks 47-56 ms; Count Directory Contents scans all items 34 ms; Paste queries the pasteboard 29
  ms at 30k URLs, about 55-100 ms at 100k. If any is put on the user-configurable button bar it runs every 100 ms.
- **Proposed fix:** Use hasOperandFile / selectionCount > 0 / a kept folder count; cache the pasteboard verdict by
  changeCount; implement menuHasKeyEquivalent(_:for:target:action:) so a key validates only its own command.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S005 [verdict, high] A stuck job blocks commands and Quit

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/App/Shell.swift:103-107; Sources/AFMShell/Interaction/ProgressJobService.swift:99-106;
  Sources/AFMShell/Interaction/ProgressJobService.swift:79; Sources/AFMKernel/PluginAPI/Kernel.swift:79
- **Basis:** CONFIRMED (read)
- **Detail:** applicationShouldTerminate returns .terminateLater; reply sent only when the queue empties, which happens
  only after work returns; isBusy rejects every command not marked runsDuringJobs. User sees beeps on most commands,
  queued jobs never start, Quit does nothing; force quit. A job counts as stuck if work never returns after cancel, or
  never starts because the global pool is exhausted (claims 10 and 14).
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### S006 [finding, high] Every list change and cursor jump costs 9-110 ms on the main thread in the Full view (cells created rather than reused in the headless setup)

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/FileListColumn.swift:140
- **Basis:** measured
- **Detail:** FileListColumn.makeCell() still appeared in stall stacks seconds into a run. Whether an on-screen window
  reuses cells needs checking in Instruments.
- **Proposed fix:** Draw rows directly, as the grid view does, or use frame-based cells without Auto Layout.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### S007 [finding, high] Pool exhaustion chains into the Quit hang

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift:78; Sources/AFMKernel/PluginAPI/Kernel.swift:79
- **Basis:** read
- **Detail:** Once 80 global-queue threads are blocked, a new job's work never starts, isBusy stays true and Quit hangs.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### S008 [finding, high] Read-ahead loops forever on a remote folder with more than 300,000 entries

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/ReadAhead.swift:133-140; Sources/AFMShell/Panel/ReadAhead.swift:102-112;
  AFMKernel/Panels/ListingCache.swift store (maxEntries = 300_000)
- **Basis:** read
- **Detail:** ListingCache.store refuses a listing above maxEntries and returns false. ended() re-arms the dwell
  whenever resting != nil. dwellEnded() only checks cache.age (nil here) and failures (not a failure), so it starts the
  read again. Scenario: cursor rests on a 1M-entry folder of a share; the whole folder is listed, 1M FileItems allocated
  and sorted on all cores, the result thrown away, and 0.4 s later it starts again for as long as the cursor stays.
  Contradicts the class comment "One listing per rest of the cursor". Category: performance/network.
- **Proposed fix:** Record per location in ReadAhead when it was last read ahead whatever the cache did, and honour
  freshEnough against that. Or do not re-dwell in ended() for the target just read. Ideally stop the read once it
  exceeds maxEntries.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S009 [finding, high] A busy watched folder saturates the main thread: at 5,000 changes/s the panel applies 227-246 list updates in 20 s, each about 80 ms of main CPU

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/PanelViewController.swift:865; Sources/AFMShell/PanelViewController+Lists.swift:81
- **Basis:** measured
- **Detail:** Main thread spent 18.1-18.3 of 20 s inside stalls. Same for a 2,000-file folder, so the cost is per update
  not per item. rereadIfDirty starts the next read as soon as one ends, and every update calls tableView.reloadData().
  Scenario 8: 225/27/0 and 244/19/0 stalls, max 278 ms and 222 ms.
- **Proposed fix:** Enforce a minimum interval between quiet reloads, growing with the cost of the last one; update only
  changed rows.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### S010 [finding, high] provider.watch() runs on the main thread and calls realpath(), so a dead share freezes launch or navigation

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Window/PanelCoordinator.swift:171-180; Sources/AFMShell/Window/PanelCoordinator.swift:53;
  Sources/AFMShell/Window/PanelCoordinator.swift:191; Sources/AFMShell/Panel/PanelViewController.swift:409;
  Plugins/LocalFileSystem/LocalFileSystem.swift:840; FileSystemProvider.swift:158-160
- **Basis:** read
- **Detail:** updateWatchers() calls provider.watch(directories) synchronously. LocalFileSystem.watch goes to
  DirectoryWatcher.watch -> resolve -> realpath() for every directory. watch is not on the provider contract list of
  main-thread-safe calls. Scenarios: last session ended on /Volumes/share/x and the share is dead, PanelCoordinator.init
  calls updateWatchers() before anything is read so launch blocks in realpath with no window; right panel on a share
  that stalls later, any navigation in the left local panel re-resolves both directories and the app freezes; switching
  to a restored tab on a dead share posts panelDidChangeLocation at once (line 409) before its read. The comment at
  PanelViewController.swift:735-737 shows the hazard is known; only one path was deferred.
- **Proposed fix:** Create and replace watchers off the main thread on a serial queue with a generation check when
  installing. Watch only directories whose listing just succeeded. Do not re-resolve a panel directory that did not
  change.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S011 [finding, medium] S5: hasOperandFile is on the validation tick through F3 View; its third call after each list change builds a 1M-entry row index (125 ms); if every marked item is a folder it walks all marks every tick (est. 45 ms)

**Outcome:** not a defect (here) — see `status/shell-p2.md`

- **Where:** AFMKernel/Panels/PanelModel.swift:684-687
- **Basis:** measured (125 ms), estimated (45 ms)
- **Detail:**
- **Proposed fix:** Keep a count of marked non-directories.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S012 [finding, medium] S8: type-to-find with an unmatched key costs 275 ms in Full view and 163 ms in grid/Brief at 1M rows

**Outcome:** fixed — see `status/shell.md`

- **Where:** AFMShell/Panel/PanelViewController+Lists.swift:333; AFMShell/Panel/PanelViewController.swift:257;
  AFMShell/Panel/FileGridView.swift:126; AFMShell/Panel/PanelViewController+Lists.swift:149
- **Basis:** measured
- **Detail:** 999,999 typeSelectStringFor calls measured on a bare 1M-row table.
- **Proposed fix:** Implement tableView(_:nextTypeSelectMatchInRow:toRow:for:) with a binary search when sorted by name,
  or a time-boxed byte scan.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S013 [finding, medium] Main-thread blocks (summary): watch -> realpath on main, Viewer close/delete on main, Network disconnect on main, synchronous archive flush at quit

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** AFMShell/Window/PanelCoordinator.swift:178; Plugins/LocalFileSystem/DirectoryWatcher.swift:74;
  Plugins/LocalFileSystem/DirectoryWatcher.swift:117; Plugins/Viewer/UI/ViewerPane.swift:324;
  Plugins/Archives/ArchivesPlugin.swift:96; Plugins/VirtualFolders/VirtualFileSystem.swift:463-469
- **Basis:** read
- **Detail:** Rows of section (c): updateWatchers -> provider.watch -> realpath (one network timeout per folder; up to
  512 folders via VirtualFileSystem.watch); ViewerPane.stopWork reader close/removeItem (one round trip per idle reader
  on every quick-view cursor move); NetworkPlugin.stop and NetworkCommands connect-failure completion (QUIT write 2 s
  per idle FTP connection, SFTP close 0.5 s per session; reviewer); ArchivesPlugin.stop flushAll (L5; minutes, forever
  in finding 1); ArchiveFileSystem.capabilities(for:) -> L4 (about 1 s on a huge ZIP; reviewer); PlacesPlugin.stop ->
  TreeCache.flush and OperationLog.flush (ms); AttributeDraft.fields getpwuid_r (seconds with network accounts;
  reviewer).
- **Proposed fix:** Do the realpath resolution on the watcher's queue, hand sources and doomed folders to a background
  queue, and do the quit work in the .terminateLater phase.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### S014 [finding, medium] B7: quit flushes archives, the operation log and FTP sessions synchronously on main (seconds to unbounded)

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Plugins/Archives/ArchivesPlugin.swift:95-96; Plugins/FileOperations/OperationLog.swift:101-106
- **Basis:** read
- **Detail:**
- **Proposed fix:** Use .terminateLater with a background flush.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S015 [finding, medium] Status line totals recounts all items after any multi-item selection change

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:744-756; Sources/AFMShell/Panel/PanelViewController.swift:487-493
- **Basis:** measured
- **Detail:** 212 ms at 1M.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S016 [finding, medium] A job that never returns blocks all commands forever and Quit hangs

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/App/Shell.swift:103-107; Sources/AFMShell/Interaction/ProgressJobService.swift:111-118;
  Sources/AFMShell/Interaction/ProgressJobService.swift:69-94
- **Basis:** read
- **Detail:** applicationShouldTerminate returns .terminateLater and replies only when the queue is empty. isBusy (and
  so commands.isBlocked) stays true until work returns; no timeout and no abandon. Scenario: a copy to a stalled NFS/SMB
  mount sits in a kernel write; Cancel shows "Stopping..." indefinitely and every file or panel command stays rejected;
  Cmd+Q puts the app in the terminate-later modal loop with no way back, user must force-quit. Depends on a provider
  that cannot abort. Category: freeze.
- **Proposed fix:** After N seconds of "Stopping..." offer "Quit anyway" or "Abandon job". On quit use cancelAll with a
  deadline, then reply(true).
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S017 [finding, medium] NSWorkspace.icon(forFile:) runs on the main thread for every newly drawn row and can stall on slow or remote files

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/FileListColumn.swift:114-122;
  Sources/AFMShell/Panel/PanelViewController+Lists.swift:343; Sources/AFMShell/Panel/FileGridView.swift:309/344/370;
  Plugins/VirtualFolders/VirtualFileSystem.swift:432
- **Basis:** read
- **Detail:** Reported as MEDIUM-HIGH, freeze. The call touches the file and is gated only by model.volume?.isLocal,
  which describes the directory, not the items. VirtualFileSystem.volume returns isLocal:
  entries.allSatisfy(\.isFileURL), so a search result holding files on `/Volumes/<share>` gets one server round trip per
  row in viewFor/draw; a stalled share hangs the main thread while scrolling. Same for symlinks in a local folder
  pointing to a share, a spun-down external disk, File Provider/iCloud items, disk images hosted on a share.
  ArchiveFileSystem builds VolumeInfo(name:) with default isLocal: true. The cache is cleared whole at 4000 entries
  (line 119): not steady-state thrash, but every 4000 new rows the visible rows of both panels miss again on main.
  Confirmed that the call is on main and the virtual-folder path reaches it; the stall itself is plausible.
- **Proposed fix:** Never ask for a file own icon on the main thread. Return the type icon at once, fetch own icons on a
  small background queue keyed by path+date, cancel on scroll, redraw the row on arrival (ThumbnailStore pattern). Use
  LRU instead of clear-all. Decide per item (item volume or mount point), not per directory.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S018 [finding, medium] A stale background quick-filter result falls back to filtering the whole list on the main thread

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController+Interaction.swift:79-99
- **Basis:** read
- **Detail:** tab.setFilter(filter, prefiltered:listVersion:) with a stale version makes the model filter listedItems
  itself on main. listVersion moves with every arriving piece, every computed folder size and every reload. Scenario:
  typing a quick filter in a 1M folder still arriving makes every result stale, O(n) matches pass on main per key burst.
  Also the kernel setListed re-filters the full list on main for every piece while a filter is set. Also: narrowing is
  ignored on the background path. Category: performance/freeze.
- **Proposed fix:** On a version mismatch re-run the job in the background against the new list, never on main. Filter
  incoming pieces in the loader thread.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S019 [verdict, medium] Type-to-find is O(n) per key

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController+Lists.swift:321;
  Sources/AFMShell/Panel/FileGridView.swift:126-134
- **Basis:** CONFIRMED (ran headless)
- **Detail:** Table: headless NSTableView asked the delegate for 999,999 rows on one non-matching key: 350 ms at 1M, 34
  ms at 100k. Grid TypeSelect.row: 225 ms at 1M, 18 ms at 100k per no-match key. Linear in distance from cursor to
  match.
- **Proposed fix:** Turn off the table's own type select and binary-search the prefix when sorted by name; otherwise
  search in the background.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S020 [finding, medium] In-place rename is cancelled by any redraw and the panel loses keyboard focus

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:427-429;
  Sources/AFMShell/Panel/PanelViewController.swift:1114-1127; FileOperationsPlugin.swift:67-68
- **Basis:** reproduced
- **Detail:** redraw() calls cancelRename(): every .contents change of the active tab cancels the edit and discards
  typed text. Sources: setVolume after volumeInfoDidChange (any listing on the same volume, e.g. the other panel watcher
  reload), a piece arriving, fresh listing replacing a remembered one, settings changes. Rename is enabled while the tab
  is still loading or refreshing, so "enter a remembered share folder, start renaming, fresh listing lands a second
  later" is routine. cancelRename removes the field without makeFirstResponder(listView); experiment fr.swift shows the
  window itself becomes first responder, so keys beep until the user clicks. Category: correctness.
- **Proposed fix:** Do not cancel for changes that keep the row (volume, flags); re-anchor the editor by item name after
  a reload. When cancelling programmatically restore the first responder if the field had it. (Responder part confirmed
  by experiment, rest by reading.)
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S021 [verdict, medium] Inline rename cancelled by redraw

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:427-429;
  Sources/AFMShell/Panel/PanelViewController.swift:814; Sources/AFMKernel/Panels/PanelHandle.swift:71-77
- **Basis:** CONFIRMED (ran)
- **Detail:** redraw() cancels unconditionally. Quiet reloads are held back and the rename survived one. It was
  cancelled by kernel.panels.refresh (non-quiet reload) and by a sort change; a selection change did not cancel it.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### S022 [finding, medium] A location change is never announced when a load of the same location overtakes one that already opened it

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:572, 670, 720, 759
- **Basis:** read
- **Detail:** Reported MEDIUM-LOW. previousDirectory is tab.directory at load start, which is already B once the 0.1 s
  timer has opened B. Scenario: click a drive button for a slow share; after "Reading..." click it again or press
  Ctrl+R. The second load ends with B == B so no panelDidChangeLocation is posted. Watchers stay on A, the command-line
  prompt shows A, Places is not told. Category: correctness.
- **Proposed fix:** As in finding 5 (keep last announced location per panel and post only when it differs).
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S023 [finding, medium] Modal dialogs are started from inside main-queue blocks, where a nested run loop does not drain the main queue

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:682-684;
  Sources/AFMShell/Panel/PanelViewController+Interaction.swift:323;
  Sources/AFMShell/Interaction/ProgressJobService.swift:78-86; Sources/AFMShell/Interaction/ProgressJobService.swift:223
- **Basis:** reproduced
- **Detail:** Experiment nested.swift shows a nested run loop inside DispatchQueue.main.async does not run other
  main-queue blocks, while one started from a run-loop callback does. Affected: "The folder cannot be read!" alert
  (PanelViewController 682-684); PanelViewController+Interaction 323 -> carryOut (confirmation, then plugin copy
  dialogs); every job completion (ProgressJobService 78-86); ask via main.sync (223); every Load.complete (plugin
  completions of show/reload). Consequences: while such an alert is up nothing dispatched to main runs (other panel
  pieces, watcher events, progress renders, every asyncAfter timer, ask from a background-mode job); startNext() waits
  for the dialog so the next queued job does not start; anything a plugin opens from these callbacks relying on
  main-queue delivery while modal hangs, e.g. NSApp.runModal(for:) windows with asynchronously filled content
  (CommandBrowser, HotlistEditor) or NSApp.terminate -> .terminateLater whose reply arrives via main.async; same command
  behaves differently from menu/key than from a drop or completion. Mechanism confirmed; plugin-side hang plausible.
- **Proposed fix:** Leave the main queue before going modal, e.g. RunLoop.main.perform(inModes: [.common]) or
  CFRunLoopPerformBlock + CFRunLoopWakeUp, for report, carryOut, job completions and Load.complete. Or use sheets and
  non-modal alerts.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S024 [verdict, medium] Modal alerts inside main-queue blocks stall later main-queue work

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:683;
  Sources/AFMShell/Panel/PanelViewController+Interaction.swift:323;
  Sources/AFMShell/Panel/PanelViewController+Interaction.swift:333;
  Sources/AFMShell/Interaction/ProgressJobService.swift:78-84;
  Sources/AFMShell/Interaction/ProgressJobService.swift:223; Sources/Plugins/Configuration/CommandRunner.swift:234
- **Basis:** CONFIRMED (ran)
- **Detail:** A nested run loop started inside a DispatchQueue.main.async block does not run later main-queue blocks
  (timers still fire); started from a timer it does. While such an alert is up every directory piece, sort result and
  progress update stalls.
- **Proposed fix:** Start alerts from a run-loop source (RunLoop.main.perform or CFRunLoopPerformBlock in common modes),
  or use sheets.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S025 [finding, medium] No back-off between quiet re-reads: continuous writes in a large folder cause back-to-back full reads and sorts

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:814-818, 865-870;
  Sources/AFMShell/Window/PanelCoordinator.swift:136-152
- **Basis:** read
- **Detail:** FSEvents deliver about 2 events/s per stream. A read longer than that marks the tab dirty and
  rereadIfDirty starts the next read immediately. Scenario: another program writes continuously into a shown 1M-entry
  folder; the app reads and sorts it on all cores back to back indefinitely, each round ending in an O(n) tab.update and
  full redraw() on main. Related: after each job the plugin refresh (not quiet) is followed by jobsEnded (quiet -> dirty
  -> second full read). Category: performance.
- **Proposed fix:** Enforce a minimum gap e.g. max(1 s, 2 x last read time) with one trailing coalesced reread. Skip the
  jobsEnded reread for directories just refreshed.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S026 [finding, medium] Every successful reload of the active tab posts .locationChanged, which closes Quick View and does extra work on every watcher tick

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:857; Plugins/Viewer/UI/QuickViewPanel.swift:45-49
- **Basis:** read
- **Detail:** if tab === self.model { host?.panelDidChangeLocation(self) } runs after quiet reloads too (app activation,
  watcher events, the refresh after each job). QuickViewPanel dismisses itself on .locationChanged of the covered panel.
  Scenario: Quick View open; switching to another app and back, or any other program touching the covered folder, closes
  it. Side effects: prompt update, Places tracker and bar validation also run on every watcher tick. Category:
  correctness.
- **Proposed fix:** Keep the last location announced per panel and post only when it differs. That also fixes
  finding 11.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S027 [verdict, medium] Reload posts .locationChanged (Quick View dismissed on app activation)

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:857;
  Sources/AFMShell/Window/PanelCoordinator.swift:190-193; Sources/Plugins/Viewer/UI/QuickViewPanel.swift:46-48;
  Sources/AFMShell/Window/MainWindowController.swift:224-227
- **Basis:** CONFIRMED (ran events); Quick View dismissal from reading
- **Detail:** A quiet reload of an unchanged folder and reloadChangedPanels each posted locationChanged. Quick View
  dismisses on that event for the covered panel; MainWindowController reloads all panels whenever the app becomes
  active, so switching away and back closes it (from reading).
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### S028 [verdict, medium] Main thread ~90% busy under a watcher flood

**Outcome:** duplicate of S009 — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:865-870
- **Basis:** UNPROVEN (PLAUSIBLE)
- **Detail:** Model work per cycle 26 ms at 1M (up to 0.8 s with filter and marks) against a background read of ~0.75 s
  CPU for 300k entries. Redraw share needs the running app.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S029 [verdict, medium] No minimum interval or back-off on panel re-read

**Outcome:** duplicate of S025 — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:865-870;
  Sources/AFMShell/Panel/PanelViewController.swift:673; Sources/AFMShell/Panel/PanelViewController.swift:762;
  Sources/AFMShell/Panel/PanelViewController.swift:838
- **Basis:** CONFIRMED (read)
- **Detail:** Called at the end of every read.
- **Proposed fix:** Re-read no sooner than about max(0.5 s, 2x the last read time) after the previous one.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S030 [verdict, medium] Read-ahead loop re-lists folders the cache refuses

**Outcome:** duplicate of S008 — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/ReadAhead.swift:133-140; Sources/AFMShell/Panel/ReadAhead.swift:105;
  Sources/AFMKernel/Panels/ListingCache.swift:142-145; Sources/AFMKernel/Panels/ListingCache.swift:31
- **Basis:** CONFIRMED (ran at small scale)
- **Detail:** Dwell restarts after every reading; skip only when cache has the folder; cache refuses folders over
  maxEntries (300,000). With limit set to 30, a 20-entry remote folder listed once in 4 s; a 50-entry one listed 9 times
  and never remembered. A remote folder over 300,000 entries is listed in full again and again while the cursor rests on
  it.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### S031 [finding, medium] A joined read-ahead cannot be cancelled and a retry re-joins the same stalled read

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/ReadAhead.swift:147-156; Sources/AFMShell/Panel/PanelViewController.swift:568,
  574-588, 714, 791-792
- **Basis:** inferred
- **Detail:** The panel Load.flag is not connected to reading.cancellation. After join the reading runs to its end even
  if the panel moves on. Scenario: read-ahead of folder F starts and the server stalls; Enter joins it and shows
  "Reading F..."; user navigates away and back; join matches the same uncancelled read again. A normal load cancel would
  have let the provider close the hung connection and reconnect. Side effect: reading != nil also disables all further
  read-ahead for the session. Category: threading/stuck loading.
- **Proposed fix:** When the last waiter is superseded cancel the reading (chain via flag.onCancel). Do not join a
  reading older than a few seconds. (Confidence: plausible.)
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S032 [finding, medium] watch is called on the main thread (PanelCoordinator.updateWatchers -> DirectoryWatcher.resolve -> realpath), which would block the window on a silent network mount

**Outcome:** duplicate of S010 — see `status/shell.md`

- **Where:** Sources/AFMShell/PanelCoordinator.swift:171
- **Basis:** inferred
- **Detail:** Not tested on a real mount. Also seen: watch called twice and capabilities(for:) 379 times from
  ButtonBarView.validate through a FileOperations enabled-closure on the main thread while the provider was silent.
- **Proposed fix:** Set up watching off the main thread.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### S033 [verdict, medium] Every key validates the whole menu with O(n) closures

**Outcome:** duplicate of S004 — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Window/MainWindowController.swift:236-239;
  Sources/Plugins/SystemTools/SystemToolsPlugin.swift:54; Sources/Plugins/SystemTools/SystemToolsPlugin.swift:70;
  Sources/Plugins/ViewOptions/ViewOptionsPlugin.swift:128; Sources/Plugins/Clipboard/ClipboardPlugin.swift:62;
  Sources/Plugins/Navigation/NavigationPlugin.swift:132
- **Basis:** CONFIRMED (ran headless)
- **Detail:** On a 240-item menu mainMenu.performKeyEquivalent called validateMenuItem 240 times for an unbound Cmd key,
  a plain letter and Down-arrow; NSApp.sendEvent of a plain unbound key did the same (no key window; focused-list
  ordering not proven). Closures: SystemToolsPlugin 54/70 (operands().filter) 26 ms at 100k marked, 390 ms at 1M;
  ViewOptionsPlugin:128 (!selection.isEmpty builds a `Set<String>`) 164 ms at 1M on first call after each marks change
  then cached; ClipboardPlugin:62 hasFiles() 19 ms at 30k files, 57 ms at 100k; NavigationPlugin:132 one pasteboard
  round trip (not timed). Viewer and MacIntegration closures already cheap.
- **Proposed fix:** enabled: { model().directory.isFileURL && model().hasOperandFile } for Print; selectionCount > 0 for
  Only Selected; cache the pasteboard answer by changeCount; implement menuHasKeyEquivalent(_:for:target:action:) on the
  menus' delegate.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S034 [finding, medium] Button and function-key bars revalidate 0.1 s after every window update

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Window/MainWindowController.swift:98;
  Sources/AFMShell/Window/MainWindowController.swift:163-176
- **Basis:** measured
- **Detail:** With Control held, the function-key bar shows Ctrl+F9 Print and runs the 390 ms operands() closure each
  time.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S035 [finding, low] redrawSelection reloads all visible cells (about 3 ms per 50 rows, measured on a bare table); 0.4 s per event with Quick Look open

**Outcome:** fixed — see `status/shell.md`

- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S036 [finding, low] ProgressSheet.lastReport is written from several job threads without a lock (left for the lock reviewer)

**Outcome:** fixed — see `status/shell.md`

- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S037 [finding, low] Job service re-entrancy (plausible): running = nil is set before completion(result); a completion that shows a modal alert leaves isBusy == false with onBusyChanged not yet sent, so blocked commands can run under the alert

**Outcome:** fixed — see `status/shell.md`

- **Where:** AFMShell/Interaction/ProgressJobService.swift:81-85
- **Basis:** inferred (plausible)
- **Detail:**
- **Proposed fix:** Run completions after startNext(), or keep a 'completing' state.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### S038 [finding, low] Marking with Insert reloads every visible cell per key

**Outcome:** duplicate of S035 — see `status/shell.md`

- **Where:** AFMShell/Panel/PanelViewController+Lists.swift:87
- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S039 [finding, low] Each listing piece at 1M costs about 30-40 ms (cursor lookup 17 ms, status recount, release of previous array)

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** AFMShell/Panel/PanelViewController.swift:615-649
- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S040 [finding, low] Folder-read errors are shown from main.async, so two failing panels stack two alerts

**Outcome:** fixed — see `status/shell.md`

- **Where:** AFMShell/Panel/PanelViewController.swift:682-684
- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S041 [finding, low] No NSAppleEventsUsageDescription although osascript drives Finder

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Plugins/FileProperties/FilePropertiesPlugin.swift:95-103; Resources/Info.plist
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### S042 [finding, low] Build hardening: ad-hoc signature, no --options runtime, no entitlements, no sandbox, so DYLD_INSERT_LIBRARIES/DYLD_LIBRARY_PATH are honoured (also affects the ICU dlopen)

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Scripts/build-app.sh
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### S043 [finding, low] Pause holds the caller locks: PauseGate blocks inside report(), so a paused worker keeps its caller locks and could deadlock the UI

**Outcome:** not a defect — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift
- **Basis:** inferred
- **Detail:** PauseGate blocks inside report(), so a paused worker keeps whatever lock its caller holds. FileJob calls
  report under counters, so sibling workers queue on that lock. If any main-thread code (e.g. an ask question closure)
  took that lock while paused, the UI would deadlock with Resume unreachable. Plausible; FileJob ask closures were not
  checked.
- **Proposed fix:** Pause at a point where the caller holds nothing, or document the constraint.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S044 [finding, low] ProgressSheet.lastReport is unsynchronised and could race if a plugin reports from parallel workers

**Outcome:** duplicate of S036 — see `status/shell.md`

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift:193, 209-213
- **Basis:** inferred
- **Detail:** Safe today only because callers serialise their reports (FileJob under its counters lock; Unpacker and
  Sync callers report from the job thread). A plugin reporting from parallel workers would race. Plausible.
- **Proposed fix:** Use a lock or an atomic.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S045 [finding, low] Out-of-order progress reports can make latest step backwards

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift:193, 209-213
- **Basis:** inferred
- **Detail:** Out-of-order reports can make ProgressSheet latest step backwards.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S046 [finding, low] ask deadlocks or traps if called on the main thread

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift:222-230
- **Basis:** read
- **Detail:** ask uses DispatchQueue.main.sync without the Thread.isMainThread guard that Kernel.askUser has.
- **Proposed fix:** Add the Thread.isMainThread guard as Kernel.askUser has.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S047 [finding, low] QueuedJob.start is never cleared after it ran, so a plugin keeping the JobHandle keeps work and completion captures alive

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift:72
- **Basis:** inferred
- **Detail:** QueuedJob.start never cleared after running.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S048 [finding, low] ColumnValueStore stops for good after one stalled value

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Panel/ColumnValueStore.swift:82-101
- **Basis:** read
- **Detail:** Reported LOW-MEDIUM, threading/stuck. One batch at a time. A column.value call blocked on a dead share
  leaves isWorking true; reset() does not clear it and there is no cancellation. Effect: plugin columns stay empty in
  every folder of that panel for the rest of the session.
- **Proposed fix:** Tie isWorking to the generation so a reset frees it, bound abandoned batches, give
  ContentColumn.value a cancellation flag.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S049 [finding, low] Type-to-select is O(n) per keystroke on the main thread

**Outcome:** duplicate of S012 — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/FileGridView.swift:126-134;
  Sources/AFMShell/Panel/PanelViewController+Lists.swift:149-155;
  Sources/AFMShell/Panel/PanelViewController+Lists.swift:333
- **Basis:** measured
- **Detail:** Reported LOW-MEDIUM, performance. In the Full view NSTableView own type-select calls typeSelectStringFor
  for every row. Measured 221 ms per key for 1M names when nothing matches.
- **Proposed fix:** Names are sorted, so binary search when sorted by name. Otherwise search in the background with a
  generation, or cap the work per key.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S050 [finding, low] FileListColumn.typeIcons is unbounded by distinct extensions

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/FileListColumn.swift
- **Basis:** read
- **Detail:** Leaks/unbounded state.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S051 [verdict, low] icon(forFile:) on main per name cell

**Outcome:** duplicate of S017 — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/FileListColumn.swift:119
- **Basis:** PARTLY CONFIRMED (ran)
- **Detail:** True but cached by path and date (4,000 entries) and only for visible rows. 40 us per plain file, ~0.2 ms
  per application. O(visible), not O(n).
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S052 [finding, low] dropSession is not cleared when a drag leaves the table, retaining the source array until the next drag

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelDragAndDrop.swift
- **Basis:** read
- **Detail:** Only the grid clears it.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S053 [finding, low] Drop type afm.panel-item is accepted from any application and turned into URLs of any scheme

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelDragAndDrop.swift:24-28
- **Basis:** read
- **Detail:** Security. Accepts afm.panel-item from any app and turns it into URLs of any scheme; the drop kind (move vs
  copy) is derived from it. A foreign drag can name sftp://..., archive or arbitrary local sources that plugins will
  then open or move.
- **Proposed fix:** Accept this type only when info.draggingSource is one of our own views, and verify that the scheme
  has a provider.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S054 [verdict, low] Panel drop accepts afm.panel-item from any pasteboard with no drag-source check

**Outcome:** duplicate of S053 — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelDragAndDrop.swift:24-28;
  Sources/AFMShell/Panel/PanelViewController+Interaction.swift:307-325
- **Basis:** CONFIRMED (read)
- **Detail:** No draggingSource check in validateDrop/acceptDrop. Precondition: user drags from a hostile app onto a
  panel. Any URL scheme gets in (ftp://, archive://, vfolder://), so a drop can start a connection or transfer;
  confirmation shows only if confirmsDrops is on.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### S055 [finding, low] Drag and drop is O(s) on the main thread with heavy constants (drag start, hover, drop)

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController+Interaction.swift:265-272, 348-356;
  Sources/AFMShell/Panel/FileGridView.swift:452; Sources/AFMShell/Panel/PanelDragAndDrop.swift:50-54, 114-120
- **Basis:** measured
- **Detail:** Reported MEDIUM-LOW, performance. Drag start: operands() is O(n), then one NSPasteboardItem (grid also one
  NSDraggingItem) per marked item. Measured in bench.swift: 0.30 s for creating 100k pasteboard items alone before
  writeObjects; with 1M marked several seconds and gigabytes. Hover: isPointless is cached per destination but each
  newly hovered folder row costs O(s) locationKey constructions (two or three per source), roughly 0.5-1 s for 100k
  sources. Drop side: pasteboardItems is O(s) again per panel entered.
- **Proposed fix:** Use a single pasteboard item with a lazy provider, or cap the items and carry the rest in-process.
  Precompute once per drag the set of source parent keys and source keys; the check becomes O(depth) per destination.
  (Measured for creation; rest by reading.)
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S056 [verdict, low] makeCell() creating cells instead of reusing

**Outcome:** refuted — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController+Lists.swift:329;
  Sources/AFMShell/Panel/PanelViewController+Lists.swift:336;
  Sources/AFMShell/Panel/PanelViewController+Lists.swift:296-299
- **Basis:** REFUTED (read)
- **Detail:** Calls makeView(withIdentifier:) first; makeCell is the fallback. What is not reused is the row view
  (296-299 makes a new CursorRowView every time).
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S057 [verdict, low] reloadData() on every contents change

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController+Lists.swift:74-85
- **Basis:** UNPROVEN (mechanism true)
- **Detail:** True. Headless it does not grow with n (0.0 ms at 1M). Whether it causes visible lag is unproven.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S058 [finding, low] Empty flash: the 0.1 s timer and the loader first piece race, so a folder taking just over 100 ms flashes empty with "Reading..." before its first piece

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift
- **Basis:** read
- **Detail:** Loader first piece also about 0.1 s; the same happens while a first/last piece is held for a background
  re-sort.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S059 [finding, low] Closures of in-flight loads capture PanelViewController and PanelModel strongly on background threads; last release could happen off main

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift
- **Basis:** inferred
- **Detail:** Only at teardown.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S060 [finding, low] Load completions are never called for loads of a closed tab and after cancelLoading()

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:374-375
- **Basis:** read
- **Detail:** Completions never called for loads of a closed tab and after cancelLoading().
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S061 [finding, low] Phantom history: a folder opened at 0.1 s then superseded stays in history, so Back leads to a place never shown

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:603
- **Basis:** read
- **Detail:** Recorded with .record.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S062 [finding, low] Rare main-thread sort: if the order changes a second time during the background re-sort, the model sorts the full list on main

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:689-698;
  Sources/AFMShell/Panel/PanelViewController.swift:744-749
- **Basis:** read
- **Detail:** In sorted() or after cache.entry(sortedBy:).
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S063 [finding, low] A quiet reload that is turned away calls completion at once, before any read

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:816
- **Basis:** read
- **Detail:** Completion called too early.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S064 [finding, low] A non-quiet reload cancels a pending navigation and re-reads the old folder

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:819-822
- **Basis:** read
- **Detail:** refresh or Ctrl+R within the first 100 ms of a navigation supersedes it and re-reads the old folder.
  Category: correctness, load state machine.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S065 [finding, low] A failed non-quiet reload is silent and a partial list is marked complete

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:828, 840-845
- **Basis:** read
- **Detail:** try? swallows the error and a partial list is marked complete by finishLoading().
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S066 [finding, low] Untrusted file names are shown raw (newlines, bidi controls) in path bar, cells, tab titles, tooltips, alerts and progress lines

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/PathBarView.swift:95-103
- **Basis:** read
- **Detail:** Names do not neutralise newlines or bidi controls (U+202E etc.). A name can display with a spoofed
  extension, or hide its second line in the 20 pt row. Security, low.
- **Proposed fix:** Map control and bidi-override characters to visible placeholders for display.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S067 [finding, low] ReadAhead failures dictionary is never pruned

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/ReadAhead.swift
- **Basis:** inferred
- **Detail:** failures is never pruned.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S068 [finding, low] A read cancelled because the cursor moved on is recorded as a failure when the provider throws on cancellation, blocking read-ahead for that folder for 60 s

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Panel/ReadAhead.swift:125-126, 135
- **Basis:** inferred
- **Detail:** Coming back to that folder gets no read-ahead for 60 s. Plausible.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S069 [finding, low] Blocking file-system work runs on DispatchQueue.global, so stalled shares can exhaust the constrained thread pool

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/PanelViewController.swift:202, 627, 692, 744, 794, 825, 954; PanelLoading.swift:108;
  ColumnValueStore.swift:89; ProgressJobService.swift:76
- **Basis:** inferred
- **Detail:** Reported LOW-MEDIUM, threading. Every retry on a stalled share parks another pool thread; each Space on a
  folder (:954) does too, and ParallelPool adds more. Effect: once the constrained pool is exhausted every panel read in
  every tab stops and a newly started job work never begins while isBusy stays true. The exact pool limit was not
  measured. Confidence plausible.
- **Proposed fix:** Use dedicated bounded queues or threads per provider or volume for blocking I/O.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S070 [finding, low] places() can wait up to 1 s on the main thread at launch

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Window/ButtonBarView.swift:191-192; Sources/AFMShell/Panel/PanelViewController.swift:916
- **Basis:** read
- **Detail:** Bounded freeze. DriveBarView.rebuild from the window init: the first call can hit LocalFileSystem.places()
  placesCondition.wait(until: +1 s) when the first volume scan is slow.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S071 [verdict, low] Menu validation for a list with focus

**Outcome:** duplicate of S033 — see `status/shell.md`

- **Where:** Sources/AFMShell/Window/MainWindowController.swift:236-239
- **Basis:** UNPROVEN (narrowing)
- **Detail:** Headless run had no key window; same ordering for a focused list not proven.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### S072 [finding, low] The 100 ms validation tick runs arbitrary plugin enabled:/checked: closures that can be O(n) or do IPC

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMShell/Window/MainWindowController.swift:98, 163-176;
  Sources/AFMShell/Window/ButtonBarView.swift:125-133; SystemToolsPlugin.swift:54, 70; ClipboardPlugin.swift:62, 129;
  NavigationPlugin.swift:132
- **Basis:** read
- **Detail:** Tick is triggered by NSWindow.didUpdateNotification i.e. after every event. Default bar is O(1). Costly
  closures once the user puts them on the bar or holds the modifier showing them on the F-key bar: Print
  `!localFiles().isEmpty` -> operands().filter is O(n) with marks; Paste pasteboard.canReadObject(...) is IPC and may
  wait on a lazy provider; Paste Path availableType. Category: performance.
- **Proposed fix:** Require enabled to be O(1) and free of I/O, or memoise per panel-event generation.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S073 [finding, low] missedChanges accumulates duplicates for the length of a job

**Outcome:** fixed — see `status/shell.md`

- **Where:** Sources/AFMShell/Window/PanelCoordinator.swift:139-141
- **Basis:** read
- **Detail:** Unbounded state.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

## Checked and found sound

### S074 [sound, info] Flooding is throttled: progress 20 Hz on service side and 25 Hz in FileJob; FSEvents about 2 hops/s; Find Files 10 Hz; geometric listing pieces; thumbnails and custom-column values async and cancelled on scroll

- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S075 [sound, info] Quick filter debounced and filtered in background at >=20k items

- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S076 [sound, info] Tabs and activation: duplicate()/snapshot() share storage (0 ms); switching O(tabs); background tabs not re-read

- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S077 [sound, info] Brief view width pass is 1.5 ms at 1M

- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S078 [sound, info] No file calls on main in shell, Navigation, Places history and hotlist, Network commands, or FileOperations.transfer setup; dialog texts O(1)

- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S079 [sound, info] Pasteboard type queries never fetch data (0.1 ms with 100 MB of text on the board)

- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S080 [sound, info] Progress sheet at most 20 Hz, under 1 ms per hop; path bar, tab bar, status line text only; all runModal uses are user-triggered

- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### S081 [sound, info] Scenario 1 (1,000,200-entry directory) timings: first rows 0.13 s (5,000 rows), complete 4.2 s, worst load stall 98 ms

- **Basis:** measured
- **Detail:** Sort (name, ext, size, time, reversed) 0.30-0.32 s each with one stall of 103-110 ms; quick filter
  0.13-0.25 s per key with a 77-109 ms stall; cursor model call 0.1-0.3 ms. Coming back: remembered rows after 0.15 s,
  fresh listing 4.3 s, five stalls of about 117 ms. Total 166 s, 3.2 GB, max stall 1,266 ms (select by mask), 677/119/2
  stalls (4.4 s of one >1 s is the harness).
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### S082 [sound, info] Cursor move main-thread cost per move at 1M entries: Page Down nothing marked 9 ms; Page Down 333k marked 20 ms (52-61 of 1,000 turns over 100 ms); random row 333k marked 12 ms; Insert 8 ms; one row down 3.6 ms

- **Basis:** measured
- **Detail:** About 93 % of main-thread time in the Core Animation flush: NSTableView layout -> updateVisibleRowViews ->
  tableView(_:viewFor:row:), plus layer display. The validateBars tick costs 0.05 ms.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### S083 [sound, info] Scenario 8 watcher flood (5,000 changes/s for 20 s, 20,000 and 2,000 files): 29 s and 27 s, 206 MB, max stall 278 ms / 222 ms, flood phase 225/27/0 and 244/19/0

- **Basis:** measured
- **Detail:** Quiet reload: 200 requests collapsed into 18-19 list updates in 90 s; afterwards the list matched the
  folder.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### S084 [sound, info] Panel stale-result guards re-checked on main: loads[id] === load; cancelLoading/tabsChanged purge ObjectIdentifier-keyed tables (PanelViewController.swift:369-388, no address-reuse hazard); filterJobs number plus listVersion; volumeAsks counter plus weak tab; size results flag plus directory; ColumnValueStore generation; ThumbnailStore token; ReadAhead identity; ViewOptions sort with pendingOrders plus listVersion

- **Where:** AFMShell/Panel/PanelViewController.swift:369-388
- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### S085 [sound, info] Main-thread cost per event table (n entries, v visible rows, s marked, t tabs)

- **Where:** Sources/AFMShell/
- **Basis:** read
- **Detail:** Cursor key repeat O(1) plus subscribers with one asyncAfter per move; insert/toggle O(v) redraw; select
  all/invert O(n) once; shift+click O(range); mouse move O(path depth); scroll table O(v x columns) with one
  icon(forFile:) per new row (finding 3); thumbnails scroll O(v); live resize O(v); arriving piece/any .contents change
  redraw(): O(v) reloadData + O(depth) path bar + O(t) tab bar + O(n) totals recount plus kernel O(n) cursor lookup and
  O(n) filtering with a filter; quiet reload result O(n) update(with:) diff, free space almost always differs; watcher
  event O(1) then full background read (finding 10); progress report O(1) throttled 20/s; validation tick O(buttons x
  closure) (finding 19); drag update O(1) known destination, O(s) new (finding 12); drag start O(n+s); type-select O(n)
  worst case (finding 13); quick-filter keystroke debounced 0.1 s, under 20k entries O(n) on main, larger in background
  except finding 9.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S086 [sound, info] Shared state touched off the main thread is protected

- **Where:** Sources/AFMShell/
- **Basis:** read
- **Detail:** Load.flag, Reading.cancellation, size-calculation flags: CancellationFlag (NSLock). PanelLoading.OrderBox:
  NSLock. ListingCache: one NSLock not held while sorting. PanelLoading.start locals owned by one background closure,
  pieces immutable. ReadAhead: all state on main, background touches only flag and cache. ColumnValueStore,
  ThumbnailStore: main only, batches copy what they need, QuickLook completions hop to main and are token-checked. Load
  closure state main only. PauseGate: NSCondition. ProgressSheet.latest and rate: main only. FileListColumn icon caches
  main only. getmntinfo static buffer used only from main and nowhere else. Exception: ProgressSheet.lastReport
  unprotected (finding 17).
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S087 [sound, info] Observers are added once; volume observer removed in deinit; volumeInfoDidChange cannot sustain itself; the validation tick has no feedback loop

- **Where:** Sources/AFMShell/
- **Basis:** read
- **Detail:** The provider measures at most once per age window.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S088 [sound, info] Tab drag loop exits safely if the strip is rebuilt under it

- **Where:** Sources/AFMShell/
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S089 [sound, info] Parallel.map on main is safe: the caller waits only for pieces of its own CPU-only job, so stalled workers elsewhere in the pool cannot block it

- **Where:** Sources/AFMShell/
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S090 [sound, info] Job queue is sound: FIFO order holds, chained completions work, cancelAll does not wait synchronously, main never blocks on a job, no ask-versus-quit deadlock on normal quit paths (menu, button, AppleEvent), jobsEnded replays missed watcher events correctly

- **Where:** Sources/AFMShell/Interaction/ProgressJobService.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S091 [sound, info] File promises are not accepted on drop (not a defect)

- **Where:** Sources/AFMShell/Panel/PanelDragAndDrop.swift
- **Basis:** read
- **Detail:** Noted in the security finding as not a defect.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S092 [sound, info] Stream contract: PanelLoader.stream always delivers at least one batch unless cancelled, so .success(nil) cannot strand a current load

- **Where:** Sources/AFMShell/Panel/PanelLoading.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S093 [sound, info] Quick filter debounce, generation and binding to the tab are correct

- **Where:** Sources/AFMShell/Panel/PanelViewController+Interaction.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S094 [sound, info] Table safety: row count and viewFor cannot disagree in a crashing way; model changes reload synchronously on main; item(atRow:) is bounds-checked

- **Where:** Sources/AFMShell/Panel/PanelViewController+Lists.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S095 [sound, info] Superseding is correct: every piece, end and timer callback is guarded by loads[id] === load; completions fire at most once

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift
- **Basis:** read
- **Detail:** Load.complete fires at most once. A superseded load completion(false) arrives after its successor is
  installed.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S096 [sound, info] Piece ordering is correct: pieces and end are FIFO on main; the inOrder/isHolding hold is correct including a second order change during the re-sort

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S097 [sound, info] Retries cannot loop: the one-shot automatic retry always takes the listed-reload path; loadRestored and loadInitially terminate at the root

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S098 [sound, info] Tab bookkeeping is sound: openedFrom snapshots, the dirty set and per-tab dictionaries are pruned in tabsChanged; identifier reuse is harmless

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift
- **Basis:** read
- **Detail:** Weak tabs, generation counters.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

## Not covered / left behind

### S099 [gap, info] Not verified: whether the shell's tabsChanged cost is exactly O(n) per call

- **Basis:** read
- **Detail:** Read only in part.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### S100 [gap, info] StandardPlugins was not opened

- **Basis:** read
- **Detail:** Assumed to be the plugin list only.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### S101 [gap, info] Not covered: shell-side ProgressJobService.report/ask, PanelModel.setComputedSizes / setSelected(names:) / deselect redraw cost, SettingsStore implementation, ui.form / pickRow

- **Basis:** read
- **Detail:** Each settings.flag is a JSON decode; about 25 reads per transfer start.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### S102 [gap, info] Not reviewed: shell dialogs and progress window beyond ProgressJobService

- **Basis:**
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### S103 [gap, info] Nothing was run against the real app, a real stalled mount or with TSan

- **Basis:** read
- **Detail:** Stall findings rest on documented syscall behaviour plus code reading.
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S104 [gap, info] Plugin internals read only where the shell calls into them; FileJob ask closures not checked for lock use, nor plugin completions for modal windows depending on main-queue delivery

- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S105 [gap, info] Not measured: whether NSPasteboard.canReadObject blocks on lazy data, nor the exact GCD pool limit on this OS version

- **Basis:** read
- **Detail:**
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open

### S106 [gap, info] Not covered: job-progress throttling for ProcessRunner output reports

- **Where:** SystemTools/SystemToolsPlugin.swift:181
- **Basis:** read
- **Detail:** In ProgressJobService.
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open
