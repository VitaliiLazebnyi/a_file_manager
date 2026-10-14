# Verify main-thread scaling findings

Fourteen of the 17 claims hold in substance, though for 7, 8 and 11 my measured magnitudes differ from the reviewers'.
Claims 9 and 10 are partly refuted, and claim 16 is confirmed only as usage with no fault shown.

**How I measured.** I copied the project (without `.build`) to the scratch `verify2/scaling`, built a release-mode
benchmark against the real `AFMKernel`, `AFMShell` and plugin sources, and deleted it all afterwards. Nothing in the
project was touched and the app was never launched. The machine was at load average 25–39 on 16 cores, so figures are
**main-thread CPU time** unless marked wall. AppKit parts (menu, type-select, outline) ran headless with no window, so
they are lower bounds.

All paths below are under `/Users/cm0k/Claude/Projects/TotalCommander/Sources/`.

## Verdicts

### 1. `listVersion` bumped by no-op refresh — CONFIRMED

- **Evidence:** `AFMKernel/Panels/PanelModel.swift:410` calls `setListed` → `listChanged()` (`:215`) before
  `areSameEntries` at `:416`. Measured: `update(with:)` on an identical listing returns `false` and the version still
  goes 1→2.
- **Other bumps that change no list:** `setComputedSizes` (`:705`) and `applyFilter` with a prefiltered list (`:549`).
- **Main-thread path:** `Plugins/ViewOptions/ViewOptionsPlugin.swift:200` falls back to `model.setSort(order)`;
  `PanelModel.swift:538-539` falls back to a full filter.
- **Cost of the fallback** (linear in n):

| Fallback             | 100k    | 1M                                                                 |
| -------------------- | ------- | ------------------------------------------------------------------ |
| `setSort`, other key | 5–16 ms | 60–105 ms CPU, 134–175 ms wall (main blocked while the pool sorts) |
| `setFilter`          | 32 ms   | 355 ms                                                             |

- With names that hit the slow sort path (claim 15) the sort fallback is single-threaded: 0.67–0.78 s for 200k names.
- **Fix:** bump `listVersion` only when `listedItems` actually changed — in `update` after the comparison, not in
  `setComputedSizes`, not in `applyFilter`. When stale, re-dispatch the sort or filter to the background instead of
  doing it inline.

### 2. `selectAll` / `invertSelection` / SelectionPlugin on main — CONFIRMED

- **Evidence:** `PanelModel.swift:638-642`; `Plugins/Selection/SelectionPlugin.swift:258, 338-354`. Commands run on main
  through `CommandRegistry.perform`.
- **Measured** (linear):

| Operation                                                    | 100k  | 1M         |
| ------------------------------------------------------------ | ----- | ---------- |
| `selectAll`                                                  | 14 ms | 207 ms     |
| `invertSelection`                                            | 23 ms | 340–442 ms |
| `select(mask:)`                                              | 18 ms | 216 ms     |
| Select all files only (filter + map + `setSelected(names:)`) | 55 ms | 919 ms     |
| Save + restore selection                                     | 22 ms | 358 ms     |
| Status-line `totals` afterwards                              | 12 ms | 212 ms     |

- **Fix:** keep marks as a bitset by row index (or an "all except" form) so all/invert/none are O(n/64). Keep running
  selected totals instead of recounting.

### 3. `update(with:)` / `setListed` with filter or marks — CONFIRMED; the release figure is lower than claimed

- **Evidence:** `PanelModel.swift:392-422`, `:497-501`, `:559-567`.
- **Measured at 1M, identical listing:**

| Case                 | Main CPU             |
| -------------------- | -------------------- |
| No filter, no marks  | 26 ms                |
| Filter active        | 371 ms               |
| All marked           | 413 ms               |
| Filter + 123k marked | 808 ms (1.09 s wall) |

- All are about 10× lower at 100k.
- **Releasing the old array:** 110 ms at 1M, 10 ms at 100k — not ~0.5 s. It does happen on main when `oldItems` goes out
  of scope.
- **Fix:** do the filter and mark-pruning in the background task that already sorts; hand the old arrays to a background
  queue to free.

### 4. `setComputedSizes` with a filter — CONFIRMED, quadratic

- **Evidence:** `PanelModel.swift:715` walks `listedItems` linearly for every name when a filter is set.
- **Main path:** job completions at `Plugins/FileProperties/FilePropertiesPlugin.swift:254, 276`, and
  `AFMShell/Panel/PanelViewController.swift:973`.
- **Measured for 10,000 sizes with a filter active:**

| Folder                              | With filter                      | Without filter |
| ----------------------------------- | -------------------------------- | -------------- |
| 1M entries, 10k folders at the head | 0.38 s                           | 51 ms          |
| 10k folders                         | 0.26 s                           | 1.5 ms         |
| 100k folders                        | 2.97 s                           | 9 ms           |
| 1M folders (1,000 sizes measured)   | 7.96 s, so about 80 s for 10,000 | 100 ms         |

- **Fix:** look names up through one dictionary over `listedItems`, built once per call.

### 5. `Snapshot` omits filter and sort — CONFIRMED

- **Evidence:** `PanelModel.swift:247-278`. `AFMShell/Panel/PanelViewController.swift:601-603` takes the snapshot, then
  `dropQuickFilter` resets the filter, then `open`; restore happens at `:657` and `:783`.
- **Reproduced on the model:** after restore, 93 items shown of 1000 listed with `filter == nil`; `sort` says
  size-descending while the items are in name order.
- Not a performance issue. It persists until the next refresh.
- **Fix:** store `filter` and `sort` in `Snapshot` and restore them; the controller must restore its `quickFilters`
  entry too.

### 6. Every key validates the whole menu, with O(n) closures — CONFIRMED headless

- **AppKit behaviour measured:** on a 240-item menu, `mainMenu.performKeyEquivalent` called `validateMenuItem` 240 times
  for an unbound Cmd key, a plain letter and Down-arrow. `NSApp.sendEvent` of a plain unbound key did the same.
- **Caveat:** this was with no key window. I did not prove the same ordering for a list that has focus.
- **Validation path:** `AFMShell/Window/MainWindowController.swift:236-239` runs `isChecked` and `isEnabled` per item.
- **Expensive closures:**

| Closure                                                                                         | Cost                                                                   |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Plugins/SystemTools/SystemToolsPlugin.swift:54, 70` (`operands().filter`)                      | 26 ms at 100k marked, 390 ms at 1M                                     |
| `Plugins/ViewOptions/ViewOptionsPlugin.swift:128` (`!selection.isEmpty` builds a `Set<String>`) | 164 ms at 1M on first call after each marks change, then cached        |
| `Plugins/Clipboard/ClipboardPlugin.swift:62` (`hasFiles()`)                                     | grows with what is on the clipboard: 19 ms at 30k files, 57 ms at 100k |
| `Plugins/Navigation/NavigationPlugin.swift:132`                                                 | one pasteboard round trip (not timed)                                  |

- The Viewer and MacIntegration closures already use cheap tests.
- **Fix:** `enabled: { model().directory.isFileURL && model().hasOperandFile }` for Print; `selectionCount > 0` for Only
  Selected; cache the pasteboard answer by `changeCount`. Implement `menuHasKeyEquivalent(_:for:target:action:)` on the
  menus' delegate so keys do not validate everything.

### 7. Pasteboard write at drag start and Cmd+C/X — CONFIRMED, worse than claimed here

- **Evidence:** `ClipboardPlugin.swift:138-139`;
  `AFMShell/Panel/PanelViewController+Interaction.swift:266-271, 340-348`.
- **Measured** on a private pasteboard with real files; linear at about 0.1 ms per item:

| Items | `writeObjects(NSURL)` | Drag `NSPasteboardItem`s |
| ----- | --------------------- | ------------------------ |
| 3k    | 0.43 s                | 0.43 s                   |
| 10k   | 1.28 s                | 1.45 s                   |
| 30k   | 3.7 s                 | 3.6 s                    |
| 100k  | 9.8 s                 | 10.1 s                   |

- 300k extrapolates to about 30 s, plus `operands()` (0.3 s at 1M). My process was sandboxed, which may inflate the
  per-URL cost.
- **Fix:** write one pasteboard item whose data is provided lazily (`NSPasteboardItemDataProvider`, or a single
  custom-type item holding the list). Cap or lazily supply `public.file-url` entries.

### 8. Type-to-find — CONFIRMED

- **Table:** `tableView.allowsTypeSelect` with `typeSelectStringFor`
  (`AFMShell/Panel/PanelViewController+Lists.swift:321`). A headless `NSTableView` asked the delegate for 999,999 rows
  on one non-matching key: 350 ms at 1M, 34 ms at 100k.
- **Grid:** `TypeSelect.row` (`AFMShell/Panel/FileGridView.swift:126-134`): 225 ms at 1M, 18 ms at 100k per key with no
  match.
- Cost is linear in the distance from the cursor to the match.
- **Fix:** turn off the table's own type select and binary-search the prefix when the list is sorted by name; otherwise
  search in the background.

### 9. Icons, cells, `reloadData` — PARTLY REFUTED

- **`icon(forFile:)` on main per name cell:** true (`AFMShell/Panel/FileListColumn.swift:119`), but cached by path and
  date (4,000 entries), and only for visible rows. Measured 40 µs per plain file, about 0.2 ms per application. This is
  O(visible), not O(n).
- **`makeCell()` creating cells instead of reusing:** REFUTED. `PanelViewController+Lists.swift:329, 336` call
  `makeView(withIdentifier:)` first; `makeCell` is the fallback. What is not reused is the row view (`:296-299` makes a
  new `CursorRowView` every time).
- **`reloadData()` on every contents change:** true (`PanelViewController+Lists.swift:74-85`). Headless it does not grow
  with n (0.0 ms at 1M). Whether it causes visible lag is unproven.

### 10. No back-off on re-read; watcher flood — PARTLY CONFIRMED

- **No minimum interval or back-off:** CONFIRMED. `AFMShell/Panel/PanelViewController.swift:865-870` is called at the
  end of every read (`:673, 762, 838`).
- **Watcher does not coalesce:** CONFIRMED by measurement. The FSEvents latency of 0.5 s
  (`Plugins/LocalFileSystem/DirectoryWatcher.swift:97-98`) did not help: at about 29,000 changes/s, 486–508 callbacks/s
  reached the main queue, spread evenly at about 50 per 100 ms. Each is its own `queue.async` (`:53`).
- **"Main thread ~90% busy":** PLAUSIBLE-unproven. Model work per cycle is 26 ms at 1M (up to 0.8 s with filter and
  marks) against a background read of about 0.75 s CPU for 300k entries. The redraw share needs the running app.
- **Fix:** coalesce in `Watch.report` (one pending flag per watcher) and re-read no sooner than about max(0.5 s, 2× the
  last read time) after the previous one.

### 11. Directory tree turns — CONFIRMED in kind, smaller than claimed

- **Evidence:** `Plugins/Places/DirectoryTreeWindowController.swift:342-357`. The 2,000-node budget counts nodes, not
  time.
- **Measured headless**, one turn of 2,000 small levels:

| Outline rows | Turn        |
| ------------ | ----------- |
| 10k          | 0.27 s      |
| 100k         | 0.30 s      |
| 1M           | 0.74–0.81 s |

- `outline.row(forItem:)` is O(rows): 0.13 ms per call at 1M. Turns re-queue immediately (`:369-372`).
- The claimed 1.6–1.8 s was not reproduced without a window.
- **Fix:** budget by elapsed time (about 8 ms), and call `reloadItem` only for expanded nodes, once per turn per node.

### 12. Multi-Rename clipboard per keystroke; Spotlight on main — CONFIRMED by reading, not timed

- **Multi-Rename:** `controlTextDidChange` (`Plugins/MultiRename/MultiRenameWindowController.swift:285`) → `refresh()` →
  `makeContext` → `clipboard()` (`Plugins/MultiRename/MultiRenameSession.swift:77`; closure at
  `Plugins/MultiRename/MultiRenamePlugin.swift:55`). The same keystroke also runs `rows.map(\.entry)` on main (`:89`),
  and `apply` runs on main (`:109-116`) — both O(rows).
- **Spotlight:** `Plugins/FindFiles/SpotlightSearch.swift:124-128` reads every result on main.
- **Fix:** read the clipboard once when the window activates or `changeCount` changes; set
  `metadataQuery.operationQueue` and read the results there.

### 13. VirtualFileSystem O(n) on main — CONFIRMED

- **Evidence:** `Plugins/VirtualFolders/VirtualFileSystem.swift:119-138` and `:441-463`. Callers are on main:
  `Plugins/VirtualFolders/VirtualFoldersPlugin.swift:95, 120` and `AFMShell/Window/PanelCoordinator.swift:186-196`.
- **Measured** (linear):

| Call                                    | 100k   | 1M     |
| --------------------------------------- | ------ | ------ |
| `register(files:)`                      | 83 ms  | 0.97 s |
| `watch` on a list                       | 127 ms | 1.25 s |
| `registerPicked(operands().map(\.url))` | 144 ms | 1.77 s |

- **Fix:** register on the caller's background thread; in `watch`, stop collecting parents once `watchLimit` distinct
  ones are found.

### 14. FindFiles batching and `finish` — CONFIRMED

- **Evidence:** `Plugins/FindFiles/FileSearch.swift:365-375` waits for `node.pending == 0`, so a folder's hits arrive
  only when the whole folder is tested. `Plugins/FindFiles/FindFilesWindowController.swift:287-300` flushes only at
  folder boundaries, so one folder is one unbounded batch.
- **Measured on main at 1M** (model passes only, no table): `append` 187 ms; the three passes in `finish` (`:361-374`)
  349 ms. At 100k: 10 ms and 15 ms.
- **Fix:** flush by time and size inside `onMatch`; in `finish`, keep the rows already there and update only the summary
  row.

### 15. Sorting comparator and ASCII gate — CONFIRMED with this machine's ICU

- **Not a strict weak order.** `Sorter.compareNames` (`AFMKernel/Panels/Sorting.swift:53-56`) rests on
  `localizedCaseInsensitiveCompare`, which is asymmetric: `"й"` vs `"ий"` returns descending in both directions.
  - Russian letters и й е ё И Е я а, names up to 3 letters: 2,268 asymmetric pairs and 48,631 intransitive triples.
  - Also asymmetric for ž in Croatian, ñ in Spanish and å in Danish/Norwegian.
- **Slow fallback.** 200k such names take 0.67–0.78 s on the calling thread against 14 ms for ASCII; the result still
  has thousands of adjacent pairs against the definition. Danish with å/ø: 0.57 s. Hungarian ASCII (gate off): 0.43 s vs
  0.05 s.
- **Gate unsound.** `keysOrderPlainNames` (`Sorting.swift:695-709`) tests only 2-character names and returned true under
  da, nb, cy and es@collation=traditional. Pure-ASCII names then sort fast and unchecked, against the definition:

| Collation      | Adjacent inversions in 1M names |
| -------------- | ------------------------------- |
| da / nb        | 2,868                           |
| cy             | 5,960                           |
| es traditional | 1,620                           |

Example under Welsh: `"ddd"` is placed before `"ddf"`, which the definition orders the other way.

- **Croatian ASCII digraphs** (lj, nj): not reproduced. Hungarian correctly has the gate off.
- **Fix:** define the order by the ICU collator itself (sort-key bytes, then name bytes as tie-break). That is a strict
  weak order by construction and removes the gate, the check pass and the fallback.

### 16. Static `NumberFormatter` across threads — usage CONFIRMED, harm unproven

- **Evidence:** `AFMContracts/Format.swift:6-12`. Called off main at, for example,
  `Plugins/SystemTools/SystemToolsPlugin.swift:182` and `Plugins/DirectorySync/SyncSession.swift:176`.
- **Stress test:** 8 threads × 300,000 calls gave no wrong output and no crash.
- **Fix if wanted:** a hand-written digit grouper, which is also much faster than the roughly 10 µs per call the stress
  test averaged.

### 17. Modal alerts inside main-queue blocks — CONFIRMED

- **Mechanism measured:** a nested run loop started inside a `DispatchQueue.main.async` block does not run later
  main-queue blocks (timers still fire). Started from a timer instead, it does.
- **Sites:**
  - `AFMShell/Panel/PanelViewController.swift:683`
  - `AFMShell/Panel/PanelViewController+Interaction.swift:323` (→ `:333`)
  - `AFMShell/Interaction/ProgressJobService.swift:78-84` (job completions)
  - `AFMShell/Interaction/ProgressJobService.swift:223` (`main.sync` for job questions)
  - `Plugins/Configuration/CommandRunner.swift:234`
- While such an alert is up, every directory piece, sort result and progress update stalls.
- **Fix:** start alerts from a run-loop source (`RunLoop.main.perform` or `CFRunLoopPerformBlock` in common modes), or
  use sheets.

## Other O(n)-on-main work found

- **Sort or filter with a filter active, even on the good path.** `setSort(_:presorted:)` and `update` go through
  `setListed`, which re-filters on main (`PanelModel.swift:499`): 378 ms at 1M, 32 ms at 100k.
- **Status line.** `totals` recounts all items after any multi-item selection change (`PanelModel.swift:744-756`, via
  `PanelViewController.swift:487-493`): 212 ms at 1M.
- **Button and function-key bars.** They revalidate 0.1 s after every window update
  (`AFMShell/Window/MainWindowController.swift:98, 163-176`). With Control held, the function-key bar shows Ctrl+F9
  Print and runs the 390 ms `operands()` closure each time.
- **Quick Look follow.** `Plugins/MacIntegration/MacIntegrationPlugin.swift:172-175` calls `localOperands()` on every
  panel event, including each cursor move, while the panel is visible: 0.3 s at 1M marked.
- **Paste validation.** `hasFiles()` grows with the clipboard's contents (see claim 6), so copying a large selection
  makes every later validation slower.
