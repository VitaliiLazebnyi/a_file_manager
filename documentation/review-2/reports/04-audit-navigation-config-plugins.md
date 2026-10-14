# Audit navigation/config plugins

Task: main-thread responsiveness audit of Places, Navigation, FolderTabs, Selection, ViewOptions, Configuration, SystemTools, MacIntegration (and StandardPlugins, not opened; assumed to be the plugin list only).

Paths are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/`. "Measured" means standalone `swiftc -O` replicas on this machine, with the real `FileItem`, `SelectionMask`, `SelectionFile` sources copied in, at 1M items and 300k marked. Benchmarks are in `/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/mainthread/forkC/` (`main.swift`, `ov/main.swift`). Model-only times exclude the panel redraw that follows `onChange`, which is yours.

## (a) Inventory

**Every `enabled:` / `checked:` closure in scope**

| Plugin | Closure | Evaluates | Cost |
|---|---|---|---|
| Selection | `isComplete`, `hasCursorItem`, `bothComplete`, `hasOperands`, `!select \|\| isComplete()` | model flags | ok, O(1) |
| Selection | checked `shows(.comparison)` | dictionary lookup + title compare | ok |
| Navigation | `parentTarget`, `rootTarget`, `backLocation`, `forwardLocation` | URL text only | ok, µs |
| Navigation | `pasteboard.availableType(from:[.string])` | pasteboard type query, no data fetch | ok (plausible; not measured) |
| FolderTabs | `hasSeveralTabs`, cursor `isDirectory`, `closedTabs[...]`, `activeIndex`, checked `isLocked` | O(1) | ok |
| ViewOptions | checked `viewMode`, `filter == nil`, `kind()`, `sort.key`, `sort.descending`, `showHidden`; enabled `!columns.all.isEmpty` | O(1) | ok |
| ViewOptions | `lastCustomFilter`: `settings.value(String.self…) != nil` | UserDefaults read + JSONDecoder per call | ok, µs |
| ViewOptions | **`onlySelected`: `!model().selection.isEmpty`** | rebuilds `Set<String>` of all marks after every mark change | **47 ms measured (F10)** |
| Configuration | user command `userCommand(named:) != nil`; Start-menu slot `entry() != nil` | cached arrays, linear in user commands | ok |
| SystemTools | `isLocal`, `isListed`, `isLocal && cursorItem != nil` | O(1) | ok |
| SystemTools | **`printFile`: `!localFiles().isEmpty`** | `operands().filter{}` over the whole list | **224 ms measured (F3)** |
| MacIntegration | `cursorFile`, `cursorItem`, `directory.isFileURL`, `hasLocalOperands`; checked `quickLook.isVisible` | O(1) | ok |

**Other entry points**

| Plugin | Entry point | Worst case |
|---|---|---|
| Selection | group by mask, all/invert/restore, similar, compare, mark-newer, load selection | O(n) on main, 0.17–2 s (F2, F6) |
| Selection | Save selection to file | `operands()` + encode on main ≈ 210 ms; I/O in a job |
| Selection | `PanelEvents` subscription | `.locationChanged` only, O(1) |
| Places | `PanelEvents` → `noteLocation` | ≤200-entry history, write debounced 1 s; `places()` on the cache queue — ok |
| Places | Hotlist / history pick lists | ≤2000 / ≤200 entries, text only — ok (modal form) |
| Places | Tree window: `linkWaiting`, `adopt`, `finishShowing`, quick search, close | F1, F9, F11 |
| Places | Tree outline data source / `viewFor` | O(1) per row — ok |
| Places | `stop()` | synchronous history save + `treeCache.flush()` (≤2 MB per file) at quit — low |
| Navigation | all `show(...)` handlers, Go to Folder | text only, background reads — ok |
| Navigation | next/previous volume | `places()` on main; local provider may wait ≤1 s on its very first answer (LocalFileSystem scope) |
| Navigation | Go to Path from Clipboard | `pasteboard.string` copies the whole text on main (F6) |
| FolderTabs | new/duplicate/close/move/activate | O(1) here; `duplicate()` shares arrays, no copy |
| FolderTabs | exchange tabs, load tab file | one `tabs.onChange` per tab (F12) |
| ViewOptions | filter commands | synchronous `setFilter` over 1M (F8) |
| ViewOptions | sort commands | background at ≥20k, with a main-thread fallback (F7) |
| Configuration | `CommandRunner.run` | both panels snapshotted on main ≈ 195 ms each (F8) |
| Configuration | Command browser / Keyboard page filter | O(commands) per keystroke — ok |
| Configuration | export / import / save position | file I/O off main; `UserDefaults.synchronize()` on main — low |
| SystemTools | run line, terminal, system info, volumes, open-with | all in jobs or background — ok |
| SystemTools | print list | `operands()` or whole list on main once; formatting in the job |
| MacIntegration | Quick Look subscription, Share, Reveal, Open With, tags, Copy as Pathname | F4, F5, F8 |

## (b) Findings, most severe first

**F1 — high, scaling/flooding (measured in replica; plausible in app). Tree scan stalls the window with one `reloadItem` per scanned folder.**
- Where: `Places/DirectoryTreeWindowController.swift:343-357`.
- Path: scanner batch → `DispatchQueue.main.async` (:274) → `linkWaiting()` → `outline.reloadItem(node, reloadChildren: true)` for every finished level whose node has a row.
- Why unbounded: `linkBudget` (2000) counts linked nodes, with a minimum of 1 per level, so one turn can make up to 2000 `reloadItem` calls.
- Measured: 2000 × `reloadItem(child, reloadChildren: true)` = 1.6–1.8 s, independent of row count (headless `NSOutlineView`).
- Trigger: first scan or F2 rescan while an expanded folder shows thousands of subfolders, e.g. `reveal` expanded a `node_modules`. With 1M visible subfolders this is about 500 consecutive 1.6 s turns.
- Fix: budget the reloads (≤8 per turn or a time budget), skip the reload when a level adds no children to a collapsed row, or coalesce into one `reloadItem(parent)` per turn.

**F2 — high, scaling (measured). Compare Directories and Mark Newer run entirely on main.**
- Where: `Selection/SelectionPlugin.swift:484-514`, `Selection/SelectionFile.swift:91-165`.
- Measured: `DirectoryComparison.compare` at 1M × 1M = 1.7–1.9 s.
- Mark Newer adds two synchronous `setFilter` passes whose closure allocates `Array($0.name.utf8)` per row (est. 2.5–3 s in total).
- `foldsCase` (:493-496) calls `URL.resourceValues(.volumeSupportsCaseSensitiveNamesKey)` on main for both panel folders. This is a blocking call; on a stalled mount it is an unbounded hang, and Shift+F2 reaches it in ordinary use, so it rates critical under that condition.
- Fix: run compare and `foldsCase` in a job (listVersion-guarded), apply with `setFilter(_:prefiltered:listVersion:)`, and use `ExactName` instead of `[UInt8]` keys.

**F3 — high if on the button bar, medium otherwise; scaling (measured). `printFile` enablement builds the operand list.**
- Where: `SystemTools/SystemToolsPlugin.swift:54,70`.
- Path: File menu open or Ctrl+F9 lookup → `isEnabled` → `model().operands().filter{}`.
- Measured: 224 ms per evaluation.
- The button bar is user-configurable (`ToolbarEditor`). With this command on it, the 100 ms tick costs 224 ms each time, so the main thread stays saturated whenever validation is scheduled.
- Fix: `isLocal() && model().hasOperandFile`.

**F4 — high, blocking call (call path confirmed; blocking plausible). LaunchServices and sharing lookups on main.**
- `MacIntegration/MacIntegrationPlugin.swift:150-152` → `installedApplications` (:62-70) calls `urlsForApplications(toOpen:)` and `urlForApplication(toOpen:)` on main. Both must type the file, so they touch it; on a stalled mount this hangs. `SystemTools.openWith` (`SystemToolsPlugin.swift:529`) already does the same lookup in a job — reuse that pattern.
- Same file, :177-183: `NSSharingServicePicker(items: 300k URLs).show` on main, unbounded with item count and touching each file.
- Same file, :160-163: `activateFileViewerSelecting(300k URLs)`.
- Fix: cap or summarise the item list for Share and Reveal, and resolve off main.

**F5 — medium, scaling per event (measured). Open Quick Look panel rebuilds the operand URL list on every panel event.**
- Where: `MacIntegration/MacIntegrationPlugin.swift:172-175` → `localOperands()` (:108).
- Measured: 396 ms per event, plus up to 25 ms for the array compare.
- Trigger: Quick Look open and many items marked; each arrow-key repeat costs about 0.4 s.
- Fix: follow only the cursor item when it changed, recompute marks only on `.selectionChanged`, debounce, and cap the list.

**F6 — high to medium, scaling (measured). Mask selection and selection loading on main.**
- Select/Unselect Group by mask (`Selection/SelectionPlugin.swift:258`, `SelectionType.swift:123-141`, `SelectionMask.swift:101-109`): 1.1 s for `*.txt` (a `[Character]` array per name), 0.34 s for a regex, plus 67 ms row index and 113 ms `setSelected`.
- "Select all in same folder" (:370): 1.0 s (URL work per row).
- Load Selection from Clipboard (:469-478): `pasteboard.string` on main, then `Set(items.map(name))` 329 ms, then `listed` at 173 ms per 10 MB — about 1.7 s for 100 MB. Lazily provided clipboard data can also block on the owning app.
- Load Selection from File: the job's completion parses up to 32 MB on main, est. 0.9 s.
- Fix: do matching and parsing on a background queue from a `listedItems` snapshot and apply with one `setSelection`; use `FileMask`'s byte matcher for plain masks.

**F7 — medium to high, scaling (confirmed by reading; duration not measured). Background sort falls back to a main-thread sort.**
- Where: `ViewOptions/ViewOptionsPlugin.swift:196-200`.
- `PanelModel.setListed` increments `listVersion` on every `update(with:)`, even when nothing changed. A quiet reload landing during the background sort therefore sends the completion to `model.setSort(order)`, which sorts 1M on main.
- In a busy watched folder this is the normal outcome.
- Fix: re-dispatch the sort on a version mismatch, or stop bumping `listVersion` when the entries are unchanged.

**F8 — medium, scaling (measured unless noted).**
- Display filters applied synchronously (`ViewOptions/ViewOptionsPlugin.swift:181-189`); "Only Selected" (:128-133) costs 47 + 147 ms plus mark dropping. `PanelModel.filtered` and `setFilter(prefiltered:)` exist but are not used here.
- Select All 171 ms, Invert 290 ms, Restore 260 ms (`PanelModel.shownKeys`; model-only).
- `CommandRunner.snapshot` (`Configuration/CommandRunner.swift:74-90`) filters both panels on every button, user-command or Start-menu run, even with no `%S`/`%L` code: 195 ms per panel. Fix: build the selection lazily.
- `remember("quicklook|share|tags " + 300k paths)` (`MacIntegration/MacIntegrationPlugin.swift:168,179,271`): 86 ms each. The log keeps up to 512 such lines of roughly 30 MB (estimated), a low-memory hazard. Fix: log a count.
- Tags completion `Set(urls.map{deletingLastPathComponent})` (:272): 242 ms.
- Copy as Pathname: about 0.5 s (396 ms operands + join + pasteboard, partly estimated).

**F9 — medium, scaling (measured in replica). Tree quick search walks the whole tree per keystroke.**
- Where: `Places/DirectoryTree.swift:291-304`, called from `controlTextDidChange` and `handleKey`.
- Measured at 2.4M nodes: 125–175 ms for a prefix, 570 ms for a wildcard. Scales linearly (10M nodes ≈ 0.5–2.4 s).
- The failed-search memo is defeated during a scan because `revision` keeps changing.
- Fix: search off main with cancellation, or in time slices.

**F10 — low to medium, scaling (measured). `onlySelected` enablement rebuilds the mark set.**
- Where: `ViewOptions/ViewOptionsPlugin.swift:128`. 47 ms after each mark change, on Show-menu open, or per tick if placed on the bar.
- Fix: `model().selectionCount > 0`.

**F11 — low to medium, scaling (measured in replica).**
- `tree = nil` on main (`DirectoryTreeWindowController.swift:298`, and replacement in `adopt` :244) frees the whole tree: 136 ms per 2.4M nodes. Fix: release on a background queue.
- `reloadData` + `expandItem` with an expanded folder of 1M subfolders: 0.74 + 0.84 s (84 + 71 ms at 100k).
- First `child(named:)` in a 1M-subfolder folder builds its index on main: 53 ms.

**F12 — low to medium, flooding (plausible; depends on the shell's `tabs.onChange` cost).**
- Where: `FolderTabs/FolderTabsPlugin.swift:238-262`.
- Exchange Directories and Tabs, and Load Tabs, fire one `tabs.onChange` per inserted and per closed tab: about 200 callbacks for 50 + 50 tabs.
- A 1 MB tab file can hold thousands of tabs, making this quadratic.
- Fix: a batch-replace API on `PanelTabs` with a single notification, and a tab-count cap.

**Modal run loops.** None of these is raised from a timer or event flood; each is user-triggered.
- `ui.form` loops: `showHotlist`, `showHistory`.
- `NSApp.runModal`: `HotlistEditorWindowController.swift:40`, `CommandBrowser.swift:92`.
- `NSOpenPanel`/`NSSavePanel.runModal`: `ConfigurationPlugin.swift:143`, `MacIntegrationPlugin.swift:230`.
- `NSPrintOperation.runModal`: `SystemToolsPlugin.swift:500`.
- `storedDataProblem` and `ConfigurationStore.onProblem` alerts are raised at most once per key.

## (c) Verified sound

- **Places:** history is bounded at 200, written after a 1 s debounce, and touches no file system. Cache file reads, tree building, `places()` and `root(of:)` all run on background queues with generation checks. Linking nodes is bounded per turn (only the reloads are not). On-demand expand reads in the background. The hotlist is capped at 2000 and `MacFavorites` is path-only.
- **Navigation:** no stat, `fileExists` or `realpath` on main anywhere.
- **FolderTabs:** tab-file I/O runs in jobs with a 1 MB limit; duplicating a tab does not copy the list.
- **Configuration:** process launch and wait, list-file writes and deletes, and export/import I/O are off main; `cm_wait` uses a timer; user-command recursion is guarded.
- **SystemTools:** application lookup, volume facts, eject, rename, system information and `urlsForApplications` all run in jobs or on a global queue.
- **MacIntegration:** F4 editor lookup is on a background queue; tag reads and writes are in jobs; `hasLocalOperands` is O(1).
- **Selection:** file I/O is in jobs; each command makes one model notification.

## (d) Not covered

- The panel redraw cost after `onChange(.selection/.contents)` and the cost of `tabs.onChange` (AFMShell).
- Real blocking times of LaunchServices, sharing and pasteboard calls on a stalled mount; these are inferred, not reproduced.
- `PagePrintView` drawing and pagination for a 1M-row list; `ListCollector`; `KeyBindingEditor` and `LiveMenus` internals; `HotlistEditorWindowController` beyond its entry points (bounded by 2000 rows).
- Job-progress throttling for `ProcessRunner` output reports (`SystemToolsPlugin.swift:181`), which is in `ProgressJobService`.
- F1 was measured on a headless `NSOutlineView` replica, not in the running app.
