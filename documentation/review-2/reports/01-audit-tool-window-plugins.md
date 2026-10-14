# Audit tool-window plugins

Slice audited: main-thread responsiveness of the Viewer, CompareContent, FindFiles, MultiRename and DirectorySync
plugins (read-only; one micro-benchmark, at
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/mainthread/forkA/b.swift`).

Paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/`. "Measured" means that
benchmark (`swiftc -O`, on a stand-in struct shaped like `FileItem`); everything else is an estimate from reading the
code.

## (a) Inventory of main-thread entry points

| Plugin         | Entry point                                                                | Worst case                                                              |
| -------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| FindFiles      | `enabled:` closure (`cursorItem?.isDirectory`)                             | ok — O(1)                                                               |
| FindFiles      | `show`/`prepare`, `windowDidBecomeKey`, `startSearch` → `selectedItems`    | O(panel items), F8                                                      |
| FindFiles      | batch hop `append` (10 Hz at most, flushed only between folders)           | O(batch); about 1 ms per 10k hits (measured 176 ms for 2M in total)     |
| FindFiles      | `finish`                                                                   | O(results), F7                                                          |
| FindFiles      | Spotlight `finished`                                                       | O(results) attribute fetches, F5                                        |
| FindFiles      | Cmd+C `copyText`, `feedToListbox`, `goToFile`                              | O(results), F6/F7                                                       |
| FindFiles      | table `viewFor`, selection change, `updateButtons`                         | ok — O(visible); `rows.contains` exits at row 1                         |
| DirectorySync  | command `open` → `adopt`                                                   | O(items) plus a sort of the marked names, F8                            |
| DirectorySync  | Show buttons, header click, `finish`, `clear` → `rebuild` → `refresh`      | O(rows), F9                                                             |
| DirectorySync  | Space / Ctrl+D/M/L/R/W, row menu → `selectedRows`, `change`, `refreshRows` | O(selection); `selectedRows` is rebuilt on every key press in the table |
| DirectorySync  | `synchronize` → `plan()`                                                   | O(rows), F9                                                             |
| DirectorySync  | progress hop (10 Hz) → `refresh`                                           | ok — the list is empty while comparing                                  |
| DirectorySync  | `viewFor`, `groupIndicator`                                                | ok — O(visible) / O(log n)                                              |
| MultiRename    | `enabled:` (`hasOperands && isWritable`)                                   | ok — O(1)                                                               |
| MultiRename    | `open` → `operands()`, `rows` map                                          | O(items), once                                                          |
| MultiRename    | typing and checkboxes → `fieldsChanged` → `refresh()` + `update()`         | O(rows) plus a clipboard read per keystroke, F3/F10                     |
| MultiRename    | preview hop `apply` → `update`                                             | O(rows)                                                                 |
| MultiRename    | first `update()` → `canUndo` → undo-history decode                         | F11                                                                     |
| MultiRename    | job completions `finish` / undo                                            | O(renamed) URL work, F4                                                 |
| MultiRename    | Shift+Up/Down, drag, remove, sort, `nextStep`, Edit names                  | O(rows) each; the sort itself runs in the background                    |
| CompareContent | command → `CompareOperands.choose`                                         | O(items), F8                                                            |
| CompareContent | option boxes, cell edit, copy, undo, resync → `recompute`                  | Myers on main below 20,000 lines, F12                                   |
| CompareContent | `edit`                                                                     | copies the whole lines array, F15                                       |
| CompareContent | `viewFor` / `highlights`                                                   | O(line length), F13                                                     |
| CompareContent | next/previous difference                                                   | O(blocks) linear scan, a few ms                                         |
| CompareContent | find, load, large recompute                                                | ok — background                                                         |
| Viewer         | `enabled:` (`hasOperandFile`, cursor file)                                 | plugin side ok; the cost is inside `PanelModel` (your scope)            |
| Viewer         | F3 with 300k marked                                                        | O(marked) `operands` + `displayPath`, about 0.3 s, once                 |
| Viewer         | `ViewerPane.load` / `clear` / `stopWork`                                   | closes readers on main, F1                                              |
| Viewer         | pager draw, scroll wheel, scroller, keys, mouse                            | ok — O(visible rows); rows are capped at `unwrapWidth` (at most 16,384) |
| Viewer         | index progress hop                                                         | ok — coalesced to one pending block                                     |
| Viewer         | resize                                                                     | ok — debounced 0.25 s, re-index in the background                       |
| Viewer         | search, copy, print completions                                            | F14                                                                     |
| Viewer         | rich presenters (HTML, RTF, PDF, image)                                    | F14                                                                     |
| Viewer         | `CursorFollower`                                                           | ok — debounced 0.12 s, but each firing runs `load` and so F1            |

## (b) Findings, most severe first

**F1 — critical, blocking call, confirmed.** Closing the viewer's pooled readers on main waits for the server.

- Path: `ViewerPane.stopWork` (`Viewer/UI/ViewerPane.swift:311-325`) → `loaded?.source.close()` →
  `CachedByteSource.close` (`Viewer/Model/ByteSource.swift:499`) → `ProviderByteSource.close` (`:182-188`) closes every
  idle reader.
- SFTP: `SFTPFileReader.close` (`Network/SFTPSession.swift:490-495`) → `closeHandle` (`:186`) sends a close request and
  waits for the full session timeout.
- FTP: `FTPReader.close` → `stop()` → `abortTransfer` (`Network/FTPConnection.swift:538-550`) waits up to
  min(timeout, 10) s, then up to 2 s per further reply.
- `stopWork` runs on main from `load` (every quick-view cursor move, N/P, F2, a followed link), `clear`,
  `QuickViewPanel.remove` and `windowWillClose`.
- Trigger: view a file on a server, the server stops answering, then press Esc, close the window or move the cursor.
- Duration: the session timeout (SFTP) or about 10 s (FTP), multiplied by up to one idle reader per core.
- Fix: detach the reader list on main and close it on a background queue (the `closeHandleLater` pattern), or call
  `interrupt()` first; treat `ProviderByteSource.deinit` (`:190`) the same way.

**F2 — high, blocking call, confirmed.** `ProviderByteSource.deinit` closes the same readers on whichever thread drops
the last reference, which is often main. Same fix.

**F3 — high, blocking call + scaling, confirmed.** Multi-Rename reads the clipboard on every keystroke.

- Path: `controlTextDidChange` (`MultiRename/MultiRenameWindowController.swift:285`) → `session.settings` didSet →
  `refresh()` → `makeContext` (`MultiRename/MultiRenameSession.swift:77`) → `NSPasteboard.general.string(forType:)`
  (`MultiRename/MultiRenamePlugin.swift:55`).
- Trigger: 100 MB of text on the clipboard costs tens to hundreds of ms per key; lazily provided data from a hung
  application blocks without limit.
- The same call also builds `ProcessInfo.environment` and `store.titleRule` each time.
- Fix: read the clipboard once at open, or only when the mask contains the clipboard placeholder, off main and capped in
  size.

**F4 — high, scaling, confirmed (measured).** Multi-Rename job completions do per-item URL work on main.

- `finish` (`MultiRenameSession.swift:413-434`): `Set` of 500k `locationKey` (measured 273 ms) plus `removeAll` by
  `locationKey` (317 ms), then `appendUndo`, `panels.refresh` and `listChanged`. About 0.7 s in total.
- Undo completion (`:466-483`): two such sets, two filters, and `Set(last.flatMap { deletingLastPathComponent ×2 })`
  (measured 816 ms). About 1.5–2 s in total.
- Fix: compute `gone`, `folders`, `attempted` and `left` in the job's work closure and hand over finished values.

**F5 — high, scaling, plausible.** Spotlight results are extracted on main.

- Path: `SpotlightSearch.finished` (`FindFiles/SpotlightSearch.swift:124-131`) loops `result(at:)` and
  `value(forAttribute:)` over every result.
- Trigger: a query matching 2M files (an empty mask asks for `kMDItemFSName == "*"`). Roughly 5–20 µs per result gives
  10–40 s; gathering itself also runs on the main run loop.
- Fix: give the `NSMetadataQuery` an `operationQueue`, extract paths there, and cap or page the results.

**F6 — high/medium, scaling, confirmed (measured).** Cmd+C in the Find Files results.

- Path: `handleResultKey` → `copyText` (`FindFiles/FindFilesWindowController.swift:504-524`) calls `displayPath` per row
  and joins.
- Duration: 536 ms measured for `url.path` plus join at 2M; with the provider lookup and `setString` of about 150 MB,
  roughly 1 s.
- Fix: build the text in the background, or use lazy pasteboard data.

**F7 — medium, scaling, confirmed (measured).** Find Files end-of-search and result actions.

- `finish` (`FindFilesWindowController.swift:361-398`): `resultItems` (66 ms), rebuilding `rows` (167 ms), a directory
  count (8 ms), then freeing the old array and `reloadData`. About 0.3 s at 2M.
- `goToFile` (`:472`) rebuilds `resultItems` on every Enter or double-click (about 66 ms); `feedToListbox` (`:483`) is
  O(n) before handing 2M URLs to the list service; `startSearch` with "search in found" (`:255`) likewise.
- A single folder with 1M matches arrives as one batch, because `flush` only runs from `onDirectory` (`:296-298`).
- Fix: keep counts incrementally, keep the rows at the end instead of rebuilding them, read the single item directly,
  and cap the batch size.

**F8 — medium, scaling, confirmed.** O(panel items) passes with a set lookup per item when 300k are marked; roughly
100–200 ms at 1M.

- Find Files `selectedItems` (`FindFilesWindowController.swift:143-146`) runs on every `windowDidBecomeKey` (`:560`), on
  `prepare` and on `startSearch`, only to test emptiness. Fix: `selectionCount > 0`.
- `SyncSession.adopt` (`DirectorySync/SyncSession.swift:102`) also sorts the 300k names.
- `CompareOperands.choose` (`CompareContent/CompareContentPlugin.swift:86-98`) adds a linear name search in the target
  panel.

**F9 — medium, scaling, confirmed.** Sync window with 1M rows.

- `rebuild()` (`SyncSession.swift:209-238`) runs on every Show toggle, header click and finish: a dictionary grouped by
  directory string, an optional sort, `positions`, and `SyncSummary(rows)`. Estimated 0.2–0.5 s, followed by
  `reloadData`.
- `synchronize()` → `plan()` (`:354`, `DirectorySync/SyncPlan.swift:32-52`) copies all visible rows and builds the plan
  with a small array allocation per row; estimated 0.3–1 s before the dialog appears.
- `selectedRows` (`DirectorySync/SyncWindowController.swift:345`) is rebuilt on every key press in the table.
- Fix: cache per-directory groups and summary counts, build the plan in the background, compute `selectedRows` only in
  the branches that use it.

**F10 — medium, scaling, confirmed.** Multi-Rename per-keystroke O(rows) on main at 500k rows.

- `refresh()` maps `rows` to entries (`MultiRenameSession.swift:90`; 18 ms measured for a comparable copy).
- `update()` (`MultiRenameWindowController.swift:307-341`) runs `counts` over all rows and `reloadData`, once at the
  keystroke and again when the preview lands, after `apply` (`MultiRenameSession.swift:111-119`) has written 500k names.
- Roughly 50–150 ms per key. The preview itself is correctly in the background and cancellable, but there is no
  debounce.
- Shift+Up/Down (`:201-207`), `nextStep`, Edit names (`:285-291`, a 500k-line modal text view) and
  `loadNames(fromText:)` (up to 32 MB split on main) are O(rows) too.
- Fix: debounce about 100 ms, keep an entries array alongside the rows, and have the preview return its counts.

**F11 — medium/high, scaling, plausible.** Undo history decoded on main.

- Path: `update()` → `canUndo` → `RenameStore.undoHistory` (`MultiRename/RenameStore.swift:134-138`) JSON-decodes
  `[[RenamedItem]]` at the first window open.
- `persistedRuns` (`:166-175`) always keeps the newest run, whatever its size, so a 500k-item run is stored and decoded
  next session; estimated 1–3 s.
- The write hop (`:185-189`) hands a multi-megabyte `Data` to the settings store on main.
- Fix: decode lazily in the background and store only a count for `canUndo`.

**F12 — medium, scaling, confirmed path, estimated time.** Compare recomputes on main for small line counts.

- Path: `CompareSession.recompute` (`CompareContent/CompareSession.swift:175-177`) runs `CompareLoader.text` inline when
  both files total under 20,000 lines; the diff is then exact (`Myers.exactBelow` = 20,000), and it calls `Parallel.map`
  from main (`CompareContent/CompareLoader.swift:98`).
- Trigger: two unrelated 10k-line files, on every option checkbox, cell edit, copy, undo or resync. Estimated 0.3–1 s;
  more with long lines, since up to 128 MB is normalised.
- Fix: always go to the background, or gate on bytes and elapsed time.

**F13 — medium/high, scaling, plausible.** Compare cells lay out whole lines.

- `viewFor` (`CompareContent/CompareWindowController.swift:497-527`) builds an attributed string of the entire line, and
  `TextDiff.inline` (`CompareContent/TextDiff.swift:203`) copies both whole lines to UTF-16 before truncating to 4,096.
- Trigger: a file of up to 128 MB with multi-megabyte lines (minified JSON); layout of one such cell takes seconds.
- Fix: truncate the displayed text to a few thousand characters and take a prefix before `Array(utf16)`.

**F14 — medium, scaling, plausible.** Viewer completions that do large work on main.

- `printContent` (`Viewer/UI/ViewerPane+Actions.swift:650-654`): `sizeToFit` lays out up to 2 MB of text; estimated
  0.5–3 s.
- `copySelection` (`:466-467`): `setString` of up to 64 MB, or about 192 MB as hex; 0.1–0.5 s.
- `show(html:)` (`Viewer/UI/ViewerPane.swift:584`): `loadHTMLString` with up to 1 GB (`wholeFileLimit`).
- RTF view (`Viewer/UI/RichViews.swift:299`): `setAttributedString` with up to 1 GB.
- First image draw (`Viewer/UI/ImageCanvasView.swift:173,187`): a frame of up to 8192² drawn with high interpolation
  until the scaled bitmap is ready; estimated 0.1–0.4 s.
- Fix: lower the limits for HTML and RTF, load HTML from a temporary file, and draw at low quality until the bitmap
  exists.

**F15 — low/medium, scaling, confirmed.** `CompareSession.edit` (`CompareSession.swift:432-446`) copies the whole lines
array on each edit because the undo snapshot shares it. With millions of lines that is about 0.1–0.3 s per edit, and 20
undo levels each keep a full copy. Fix: store deltas.

**Modal loops, low.** `NSOpenPanel` / `NSSavePanel` / `NSPageLayout` `runModal` (`ViewerPane+Actions.swift:537,547,602`)
and `kernel.ui.form` / `inform` / `pick` from completions (sync finish, compare finish, rename finish). Each is raised
once per operation; none can be raised repeatedly from a flood.

## (c) Verified sound

- **Viewer text path.** Every read, index build, row fetch, reveal, search, copy read, HTML strip and decode runs on
  `workQueue`, `fetchQueue` or a global queue, with generation checks. Rows are always cut at the column limit, so a 10
  GB single line becomes bounded rows. The `TextRowIndex`, `CachedByteSource` and `DiskBlockCache` locks are never held
  across provider I/O (only a local `pread`/`pwrite` of at most 256 KB). Scrolling is O(1) plus an asynchronous fetch.
- **CTLine cost.** Measured 60 CTLines of 16,384 characters at about 5 ms, so drawing a page is cheap even at the widest
  setting.
- **Flooding.** Find Files batches, duplicate status, sync progress, viewer search progress and rename job progress are
  all time-throttled (10–20 Hz), and stale generations are dropped.
- **Compare.** Load, large recompute and find are in the background; `block(containing:)` bisects; the inline cache is
  capped.
- **Multi-Rename.** Preview and long sorts are in the background and cancellable; large undo writes are encoded off
  main.
- **Find Files.** `insertRows` rather than `reloadData` per batch; `updateButtons` exits early.
- **Blocking calls.** No `FileManager`, `stat` or provider `item`/`list`/`volume` call was found on main in these five
  plugins. The only ones on main are text-only (`displayPath`, `location(from:)`, `capabilities(for:)`).

## (d) Not covered

- `FindFiles/SearchForm.swift` field handling, saved searches and history sizes (only grepped).
- `ViewerSearch`, `HTMLText`, the hex/binary row builders, `MediaView`, and the viewer's `handleKey` / `menuEntries`
  cost per key.
- Sync and rename executors and `SyncComparison` (background; only their main-thread hops were checked).
- Inside the kernel and other plugins: `PanelModel.hasOperandFile` / `operands`, `PanelSet.refresh` with very many
  changed folders (called from sync, rename and compare completions), the settings store's `set` cost, and
  `FileListService.show` with 2M URLs.
- Nothing was profiled in the running app; apart from the benchmark, all durations are estimates.
