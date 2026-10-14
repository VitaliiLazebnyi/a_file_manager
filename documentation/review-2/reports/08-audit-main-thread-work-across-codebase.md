# Audit main-thread work across codebase

## Main-thread responsiveness audit — A File Manager

The app does not meet the "never freeze" requirement yet: there are five ways to hang the main thread for the length of
a mount or server timeout, and a set of 0.2–15 s stalls at 1M entries / 300k marked. Nothing in the project was
modified.

**How this was produced.** I read AFMKernel and AFMShell myself; three forked sub-agents read the 21 plugins, and I
re-read the code behind their critical and high findings except P3, P4, P7 and P9 and the fork-reported parts of S7 and
S9, which are as reported. "Measured" means `swiftc -O` micro-benchmarks on this Mac (macOS 27.0.1); my core one
compiles the real AFMKernel sources (1M items, 300k marked). Everything else is an estimate from reading; nothing was
profiled in the running app or against a real stalled mount.

Paths are relative to `S = /Users/cm0k/Claude/Projects/TotalCommander/Sources`, and `P = S/Plugins`. Benchmarks are
under
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/mainthread/`
in `core/`, `appkit/`, `menu/`, `forkA/`, `forkB/`, `forkC/`.

### (a) Inventory of main-thread entry points

Finding IDs refer to section (b): B = blocking, S = scaling, P = plugin window.

| Module                                              | Entry point                                                                              | Worst case                                                                                                                                            |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shell                                               | 100 ms validation tick (`MainWindowController.scheduleValidation` :163 → `validateBars`) | O(1) per default button; F3 View costs 125 ms once per list change (S5); unbounded cost if a heavy command is put on the bar (S1)                     |
| Shell                                               | Main-menu validation (`validateMenuItem` :236)                                           | Every `enabled:`/`checked:` closure of every menu command, on every key equivalent and menu open (S1)                                                 |
| Shell                                               | Context menu (`contextMenu(forRow:)` :1031)                                              | ok — its commands are O(1), apart from S5 and B2                                                                                                      |
| Shell                                               | Cell fill (`viewFor` Lists:337), grid `draw`                                             | O(visible); `icon(forFile:)` on main (B5)                                                                                                             |
| Shell                                               | Arrow keys, Insert, Shift+arrow                                                          | Model O(1); `redrawSelection` reloads all visible cells (about 3 ms per 50 rows, measured on a bare table); 0.4 s per event with Quick Look open (S6) |
| Shell                                               | Typing letters in the list                                                               | 275 ms (Full) / 163 ms (Brief, Thumbnails) per key without a match at 1M (S8)                                                                         |
| Shell                                               | Quick filter typing                                                                      | Debounced 0.1 s, filtered in background at ≥20k; apply is 20–40 ms, +100–300 ms with marks                                                            |
| Shell                                               | Drag start, drag-over                                                                    | 12–17 s and 0.7 s per folder row (S2, S3)                                                                                                             |
| Shell                                               | Listing pieces (`take` :615–649)                                                         | About 30–40 ms per piece at 1M; about 500 ms with a display filter (S4)                                                                               |
| Shell                                               | Quiet reload apply (`update(with:)` :771, :854)                                          | 10 ms, +100 ms freeing the old list, +300 ms with 300k marks (S4)                                                                                     |
| Shell                                               | Tab switch, panel switch, app activation                                                 | ok — O(tabs) + O(visible); only the two active tabs re-read, in the background                                                                        |
| Shell                                               | `updateWatchers` (PanelCoordinator :171)                                                 | `realpath` on main (B1)                                                                                                                               |
| Shell                                               | Volume menu, drive bar → `places()`                                                      | Up to 1 s per call while the first read is stuck (B6)                                                                                                 |
| Shell                                               | Progress sheet                                                                           | ok — at most 20 Hz, under 1 ms per hop                                                                                                                |
| Shell                                               | Path bar, tab bar, status line                                                           | ok — text only; totals are O(n) once per list or mark change (about 250 ms after a bulk mark change)                                                  |
| Kernel                                              | `PanelModel` selectAll / invert / select(mask) / operands / `selection`                  | 209 / 565 / 302 / 256 / 56 ms measured (S7)                                                                                                           |
| Kernel                                              | `Parallel.map` from main (`areSameEntries`)                                              | ok — the caller works its own pieces                                                                                                                  |
| Kernel                                              | `ListingCache` lock                                                                      | Low — a big listing can be freed under the lock (≤300k entries, tens of ms)                                                                           |
| FileOperations, Archives, FileTools, FileProperties | `enabled:` closures                                                                      | O(1), except `isWritable` inside an archive (B2) and `countDirectoryContents` (34 ms)                                                                 |
| FileOperations etc.                                 | Command start and completion at 300k                                                     | `operands()` 256 ms; completions about 0.5 s (S9)                                                                                                     |
| Clipboard                                           | Cut/Copy, Paste                                                                          | 9.6 s / 1.1 s (S2)                                                                                                                                    |
| LocalFileSystem                                     | `watch`, `places`                                                                        | B1, B6                                                                                                                                                |
| VirtualFolders                                      | `register`, `watch`                                                                      | 2–5 s with a 2M list (S10)                                                                                                                            |
| Network                                             | Keychain in the connection editor                                                        | Normally 5–50 ms; unbounded during a system prompt (plausible)                                                                                        |
| Selection                                           | Mask select, compare directories, load selection                                         | 0.3–3 s (S7, B4)                                                                                                                                      |
| ViewOptions                                         | Filter and sort commands                                                                 | Filter synchronous; sort falls back to main (S4)                                                                                                      |
| Places                                              | Tree window scan, quick search                                                           | 1.6 s turns (P1), 0.1–0.6 s per key (P6)                                                                                                              |
| MacIntegration                                      | Quick Look follow, Open With, Share, Reveal                                              | S6, B4                                                                                                                                                |
| Viewer                                              | Draw, scroll, resize, select                                                             | ok — O(visible); closing readers blocks (B3)                                                                                                          |
| FindFiles                                           | Result batches                                                                           | ok — 10 Hz, about 1 ms per 10k hits; finish, copy, Spotlight (P3, P5, P8)                                                                             |
| MultiRename                                         | Typing                                                                                   | Clipboard read + O(rows) per key (P2)                                                                                                                 |
| DirectorySync                                       | Show toggles, synchronize                                                                | 0.2–1 s at 1M rows (P7)                                                                                                                               |
| CompareContent                                      | Option changes, cells                                                                    | Diff on main below 20k lines; whole-line layout (P9)                                                                                                  |
| Navigation, FolderTabs, Configuration, SystemTools  | Commands                                                                                 | ok, except `CommandRunner.snapshot` (195 ms per panel) and one `tabs.onChange` per tab on bulk tab loads                                              |

### (b) Findings, most severe first

#### Critical — hang for the length of a mount or server timeout

**B1. `realpath()` on main for every watched panel folder.** Blocking call, confirmed.

- Where: `P/LocalFileSystem/DirectoryWatcher.swift:76,117`; `FSEventStreamCreate` with `WatchRoot` at :100 is also on
  main and may touch the path itself.
- Path: `PanelCoordinator.panelDidChangeLocation` → `updateWatchers()`
  (`S/AFMShell/Window/PanelCoordinator.swift:171–179`) → `LocalFileSystem.watch`
  (`P/LocalFileSystem/LocalFileSystem.swift:840`) → `DirectoryWatcher.watch` → `resolve`.
- Trigger: either panel sits on a stalled SMB/NFS mount and either panel navigates. Both directories are re-resolved, so
  navigating the healthy panel hangs too.
- Duration: 30–600 s.
- A virtual list forwards up to 512 folders through the same route (`P/VirtualFolders/VirtualFileSystem.swift:441–470`).
- Fix: build and replace the stream on the watcher's own queue and return the handle at once; skip watching where
  `volume?.isLocal == false`.

**B2. `OpenArchive.capabilities` takes a lock that background threads hold across I/O.** Blocking lock, confirmed.

- Where: `P/Archives/OpenArchive.swift:695–696`.
- Path: validation tick or menu → any `isWritable` closure (`P/FileOperations/FileOperationsPlugin.swift:43–45`) →
  `FileSystemRegistry.capabilities(for:)` → `P/Archives/ArchiveFileSystem.swift:458–463`.
- The lock is held during a `stat` (:476–483), a rename, a central-directory reload (:1313) and a sort of all entries
  (:1105).
- Trigger: a panel inside a ZIP on a stalled mount (30–600 s on the next tick), or a 1M-entry ZIP being flushed or
  re-read (estimated 0.5 s to several seconds).
- Fix: publish capabilities as a lock-free snapshot; move the stat, rename and reload out of the lock.

**B3. The viewer closes pooled remote readers on main.** Blocking call, confirmed.

- Where: `P/Viewer/UI/ViewerPane.swift:311–325` (`stopWork` → `loaded?.source.close()`) →
  `P/Viewer/Model/ByteSource.swift:182–190` → `P/Network/SFTPSession.swift:486–495` → `closeHandle` :186, which waits
  the full session timeout. FTP waits about 10 s.
- Trigger: view a file on a server that stops answering, then press Esc, close the window, or move the cursor with quick
  view on.
- Duration: one timeout per idle reader, up to one reader per core.
- `ProviderByteSource.deinit` does the same on whichever thread drops the last reference.
- Fix: detach the reader list on main and close it on a background queue (`closeHandleLater` already exists).

**B4. File-touching calls in command handlers.** Blocking call; critical on a stalled mount.

- `ArchiveFileSystem.location(from:)` calls `stat()` (`P/Archives/ArchiveFileSystem.swift:534–535`). It is reached from
  `FileSystemRegistry.location(from:relativeTo:)` (`S/AFMKernel/FileSystem/FileSystemProvider.swift:470`) for any typed
  path with a component that looks like an archive. Confirmed for Pack (`P/Archives/ArchiveCommands.swift:265`: the
  proposed target always ends in `.zip`), Unpack (:343), `P/Clipboard/ClipboardPlugin.swift:249` and
  `P/FileTools/FileToolsPlugin.swift:109,280`. Fix: decide by text; verify in the job.
- Compare Directories (Shift+F2) calls `resourceValues(.volumeSupportsCaseSensitiveNamesKey)` on main for both panels
  (`P/Selection/SelectionPlugin.swift:493–496`). Confirmed call; blocking plausible.
- Open With calls `urlsForApplications(toOpen:)` and `urlForApplication(toOpen:)` on main
  (`P/MacIntegration/MacIntegrationPlugin.swift:62–70,150–152`). Plausible; SystemTools already does this lookup in a
  job.

**B5. `NSWorkspace.icon(forFile:)` on main in every cell fill and grid draw.** Blocking call, plausible; high to
critical.

- Where: `S/AFMShell/Panel/FileListColumn.swift:118`, from `viewFor`
  (`S/AFMShell/Panel/PanelViewController+Lists.swift:337`) and `FileGridView.draw`.
- It is gated on `volume.isLocal`, so network shares are safe.
- Still exposed: a disk image mounted from a share, or a failing external disk. Both report as local, and each uncached
  row then blocks.
- Fix: fetch icons asynchronously, as `ThumbnailStore` already does, and show the type icon meanwhile.

#### High — longer than 1 s

**S1. Every key equivalent validates the whole main menu.** Scaling, measured.

- On this OS, `mainMenu.performKeyEquivalent` called `validateMenuItem` for 320 of 320 items on an unbound key and 160
  on a bound one (`menu/` benchmark). So each Cmd shortcut and each menu-bar open runs every `enabled:` and `checked:`
  closure (`S/AFMShell/Window/MainWindowController.swift:236`).
- Heavy closures at 1M / 300k marked:
  - Print File Contents builds the operand list: 224–256 ms (`P/SystemTools/SystemToolsPlugin.swift:54,70`).
  - Only Selected Files rebuilds a `Set<String>` of all marks after each mark change: 47–56 ms
    (`P/ViewOptions/ViewOptionsPlugin.swift:128`).
  - Count Directory Contents scans all items: 34 ms (`P/FileProperties/FilePropertiesPlugin.swift:56`).
  - Paste queries the pasteboard: 29 ms measured at 30k URLs, about 55–100 ms at 100k.
- Total about 0.35 s of latency per shortcut. If any of these is put on the user-configurable button bar, it runs every
  100 ms.
- Fix: use `hasOperandFile` / `selectionCount > 0` / a kept folder count; cache the pasteboard verdict by `changeCount`;
  implement `menuHasKeyEquivalent(_:for:target:action:)` so a key validates only its own command.

**S2. Putting 300k items on a pasteboard.** Scaling, measured.

- `writeObjects` costs 40–57 µs per item: 1.2 s for 30k, so 12–17 s for 300k.
- Drag start in the Full view: `S/AFMShell/Panel/PanelViewController+Interaction.swift:348–356`, after `operands()` at
  :265–268. The grid adds 300k `NSDraggingItem`s (`S/AFMShell/Panel/FileGridView.swift:443`).
- Cmd+C / Cmd+X: `P/Clipboard/ClipboardPlugin.swift:122–126` (9.6 s for 300k, measured at 100k). Paste of 100k URLs: 1.1
  s.
- Drag-enter reads every item back: 5 µs per item, about 1.5 s for 300k (`S/AFMShell/Panel/PanelDragAndDrop.swift:24`).
- Fix: one pasteboard item carrying a list (or lazy data via `NSPasteboardItemDataProvider`); keep in-app drags in
  memory keyed by drag sequence number.

**S3. Drag-over re-checks all sources for each new folder row.** Scaling, measured.

- 721 ms for 300k sources (`S/AFMShell/Panel/PanelDragAndDrop.swift:50–54`, called from `DropSession.isPointless` :114).
  `locationKey` is recomputed four times per source.
- Fix: precompute once per drag the set of source keys and of source parents; each row is then two lookups.

**S4. Applying a listing on main.** Scaling, measured.

- `setListed` (`S/AFMKernel/Panels/PanelModel.swift:497–501`) filters on the calling thread. Each piece of a 1M folder
  with a display mask on costs 494 ms (`S/AFMShell/Panel/PanelViewController.swift:646`); `update(with:)` costs 269 ms.
- `update(with:)` (:392–422) with 300k marks costs 309 ms, mostly `dropMarksOfItemsNotShown` :559. Freeing the previous
  list adds about 100 ms.
- `listVersion` increases on every update, even when nothing changed. Background sorts and filters therefore lose their
  version check and fall back to main: `setSort` 327–341 ms (`P/ViewOptions/ViewOptionsPlugin.swift:196–200`), filter
  380–580 ms (measured with 300k marks).
- In a 1M-entry folder receiving 5,000 events/s, reloads chain back to back, so these stalls recur for as long as the
  events last. The watcher itself delivers only about 2 hops/s.
- Fix: have the reader deliver the filtered list and the surviving marks; do not bump `listVersion` when entries are
  unchanged; re-dispatch on a version mismatch instead of sorting on main; release old lists on a background queue; add
  a minimum gap between quiet reloads.

**P1. Directory-tree scan.** Scaling and flooding; measured on a headless replica.

- Up to 2000 `outline.reloadItem(_, reloadChildren: true)` calls in one main-queue turn, 1.6–1.8 s
  (`P/Places/DirectoryTreeWindowController.swift:343–357`).
- Fix: budget the reloads per turn, or coalesce to one per parent.

**P2. Multi-Rename reads the clipboard on every keystroke.** Blocking and scaling, confirmed.

- `P/MultiRename/MultiRenameSession.swift:77` via `P/MultiRename/MultiRenamePlugin.swift:55`. Slow with 100 MB of text;
  unbounded if another app provides the data lazily.
- The same keystroke does O(rows) work with no debounce: 50–150 ms at 500k rows.
- Fix: read the clipboard only when the mask uses it, off main; debounce.

**P3. Multi-Rename completions.** Scaling, measured. 0.7 s after a rename and 1.5–2 s after an undo, from per-item URL
sets (`P/MultiRename/MultiRenameSession.swift:413–434,466–483`). Fix: compute them in the job.

**P4. Compare Directories and mask selection.** Scaling, measured. Compare at 1M × 1M runs 1.7–1.9 s on main
(`P/Selection/SelectionPlugin.swift:484–514`); select by `*.txt` 1.1 s (:258); Load Selection from Clipboard about 1.7 s
for 100 MB (:469–478).

**P5. Spotlight results extracted on main.** Scaling, plausible. An estimated 10–40 s for 2M results
(`P/FindFiles/SpotlightSearch.swift:124–131`). Fix: give the query an operation queue and page the results.

**S10. Virtual lists do O(n) URL work on main.** Scaling, estimated from a measured 0.64 µs per `locationKey`.

- Registering 2M results: 2–4 s (`P/VirtualFolders/VirtualFileSystem.swift:122–138`).
- `watch()` on every navigation while a list is shown: 3–5 s (:456–459).
- Also a correctness bug: `Coalescer.settle()` (:510–518) calls `onChange` on a global queue, so
  `PanelCoordinator.reloadChangedPanels` runs off main.

#### Medium — 100 ms to 1 s

- **S5. `hasOperandFile`** (`S/AFMKernel/Panels/PanelModel.swift:684–687`) is on the tick through F3 View. Its third
  call after each list change builds a 1M-entry row index: 125 ms measured. If every marked item is a folder, it walks
  all marks every tick (estimated 45 ms). Fix: keep a count of marked non-directories.
- **S6. Quick Look panel open:** every panel event rebuilds the operand URL list, about 0.3–0.4 s per cursor move with
  300k marked (`P/MacIntegration/MacIntegrationPlugin.swift:108,172–175`; 396 ms measured by the fork, 256 ms for
  `operands()` alone in my run). Fix: follow the cursor item; recompute marks only on `.selectionChanged`.
- **S7. Bulk marking on main:** Select All 209 ms plus a 251 ms status recount; Invert 565 ms; `select(mask:)` 302 ms
  (`PanelModel.swift:638–652,744`). The plugin's Select All is 171 ms model-only per the fork. Fix: a bit set by row
  instead of a name set, or do it in the background and apply once.
- **S8. Type-to-find:** an unmatched key costs 275 ms in the Full view, measured on a bare 1M-row table (999,999
  `typeSelectStringFor` calls; `PanelViewController+Lists.swift:333`, enabled at `PanelViewController.swift:257`). In
  the grid it costs 163 ms (`FileGridView.swift:126`, from Lists:149). Fix: implement
  `tableView(_:nextTypeSelectMatchInRow:toRow:for:)` with a binary search when sorted by name, or a time-boxed byte
  scan.
- **S9. Operation start and completion at 300k:** `operands()` 256 ms at every start; completions about 0.5 s
  (`P/FileOperations/FileOperationsPlugin.swift:202–208,270`); Verify Checksums 1.3–1.5 s before its alert, because it
  builds a mask and compiles a regex per item (`P/FileTools/FileToolsPlugin.swift:291–303`,
  `P/FileTools/ChecksumFiles.swift:429–433`).
- **B6. `places()`** waits up to 1 s per call while the first background read is stuck on a dead mount
  (`P/LocalFileSystem/LocalFileSystem.swift:670–675`). Fix: seed with `fixedPlaces()`.
- **B7. Quit:** `stop()` flushes archives, the operation log and FTP sessions synchronously on main
  (`P/Archives/ArchivesPlugin.swift:95–96`, `P/FileOperations/OperationLog.swift:101–106`). Seconds to unbounded. Fix:
  `.terminateLater` with a background flush.
- **P6. Tree quick search** walks every node per key: 125–570 ms at 2.4M nodes (`P/Places/DirectoryTree.swift:291–304`).
- **P7. Sync window at 1M rows:** `rebuild()` on each Show toggle 0.2–0.5 s; `plan()` 0.3–1 s
  (`P/DirectorySync/SyncSession.swift:209–238,354`).
- **P8. Find Files at 2M results:** finish about 0.3 s; Cmd+C about 1 s
  (`P/FindFiles/FindFilesWindowController.swift:361–398,504–524`). A single folder with 1M hits arrives as one batch.
- **P9. Compare:** the diff runs on main below 20,000 lines on each option change, estimated 0.3–1 s
  (`P/CompareContent/CompareSession.swift:175–177`). Cells lay out whole multi-megabyte lines
  (`P/CompareContent/CompareWindowController.swift:497–527`).
- **Unbounded alert text:** Create Link joins every failure into one alert
  (`P/FileProperties/FilePropertiesPlugin.swift:371`).

#### Low — 8 to 100 ms

- `setComputedSize` copies the whole list when a background closure holds it: 50 ms measured
  (`PanelModel.swift:710–719`). With a filter on, it does one linear search per name.
- Each listing piece at 1M costs about 30–40 ms (cursor lookup 17 ms, status recount, release of the previous array).
- `settings.flag` runs a JSON decode per call inside `checked:` closures.
- Marking with Insert reloads every visible cell per key (`PanelViewController+Lists.swift:87`).

#### Modal loops

All `runModal` uses are user-triggered and none is raised from a flood. One wrinkle: folder-read errors are shown from
`main.async` (`PanelViewController.swift:682–684`), so two failing panels stack two alerts.

### (c) Verified as sound

- **Listing:** read, sort and merge happen in the background; `reloadData` at 1M rows is 0.6–3 ms and select-and-scroll
  0.3 ms (measured).
- **Flooding:** progress is throttled to 20 Hz on the service side and 25 Hz in `FileJob`; FSEvents arrive at about 2
  hops/s; Find Files batches at 10 Hz; pieces arrive at geometrically growing intervals; thumbnails and custom-column
  values are asynchronous and cancelled on scroll.
- **Quick filter:** debounced and filtered in the background at ≥20k items.
- **Tabs and activation:** `duplicate()` and `snapshot()` share storage (0 ms); switching is O(tabs); background tabs
  are not re-read on activation.
- **Brief view:** the width pass is 1.5 ms at 1M.
- **Viewer text path:** O(visible), with rows capped at 16,384 columns, so a 10 GB line is bounded.
- **No file calls on main** in the shell, Navigation, Places history and hotlist, the Network commands, or
  `FileOperations.transfer` setup. Dialog texts are O(1).
- **Pasteboard type queries** never fetch data (0.1 ms with 100 MB of text on the board).

### (d) Not covered

- No run of the real app; B1–B6 durations on a stalled mount are inferred, not reproduced.
- The lazy-pasteboard hang was not reproduced.
- Low memory and disk full were not exercised.
- Bodies of job-thread code (`FileJob`, packers, codecs, network streams) beyond their hops to main.
- `FormDialog` and pick-list rendering with very large inputs; `PagePrintView`; `SearchForm`; hex and media viewers; the
  hotlist editor.
- Other main-thread callers of `fileSystems.location(from:)` (Navigation cd, command line) share B4's root cause but
  were not traced one by one.
- Keychain prompt behaviour (`P/Network/SavedConnections.swift:26–42`) is plausible only.
- `ProgressSheet.lastReport` is written from several job threads without a lock; that is for the lock reviewer.
