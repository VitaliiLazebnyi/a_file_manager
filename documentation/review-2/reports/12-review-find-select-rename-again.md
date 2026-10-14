# Review find, select, rename again

# Second-round review: FindFiles, Selection, MultiRename

All 23 files in scope were read in full, and nothing in the project was modified. Paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/`. Experiments are in `/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/find/` (`a.swift`, `b.swift`, `tp/`).

"Confirmed" means reproduced by experiment or unambiguous from the code; "plausible" means the mechanism is in the code but the trigger or cost was not measured.

No critical finding. The rename runner never replaces a different local file, so the worst outcomes are permanent hangs and one data-loss path in the duplicate finder on non-local file systems.

## High

**H1. User regexes run with no time limit and no cancellation inside a match** — freeze/threading, confirmed.
- Measured: `^(\w+[ _-]?)+\.jpg$` against `aaaa….png` takes 0.18 s at 22 characters, 0.73 s at 24, 2.8 s at 26 (×4 per 2 characters; a 40-character name is hours).
- **Selection:** `Selection/SelectionMask.swift:103`, called from `Selection/SelectionPlugin.swift:258`, runs on the main thread. A `<regex` mask of that shape hangs the whole app for good.
- **MultiRename preview:** `MultiRename/RenameRules.swift:163,166`. Cancellation is only checked between items (`RenameRun.swift:147`), so the shared `ParallelPool` threads spin and the serial preview queue (`MultiRenameSession.swift:100`) never runs another preview or sort.
- **MultiRename Start:** `MultiRenameSession.swift:357` computes the same preview inside the job. The job cannot be cancelled, and jobs run one after another, so every later copy/move/delete in the app is blocked until restart.
- **FindFiles:** name regex (`FindFiles/SearchCriteria.swift:71`), content regex on chunks of up to about 5 MB (`FindFiles/TextPattern.swift:344`), field-rule regex (`SearchCriteria.swift:231`). After Cancel or closing the window the worker threads keep spinning; each such search leaves up to max(4, cores) threads burning CPU.
- The plain-wildcard Search & Replace has the same shape: `*a*b*c*d*e*` becomes chained `.*?` (`RenameRules.swift:195-204`), which is polynomial per name.
- **Fix:** run every user regex through `enumerateMatches(options: .reportProgress)` and set `stop` when the cancellation flag is set or a per-item deadline passes. Move Selection matching off the main thread.

**H2. Spotlight results are collected on the main thread, one attribute fetch per result** — freeze, plausible (cost not measured).
- `FindFiles/SpotlightSearch.swift:124-128`.
- With no criteria the query is `kMDItemFSName == "*"` (line 60), which returns every indexed file in scope.
- At a million results the per-item `value(forAttribute:)` loop is likely several seconds of main-thread stall, plus all paths held in memory.
- **Fix:** give the `NSMetadataQuery` a background `operationQueue`, read the paths there, and cap the count.

## Medium

**M1. Everything in the Selection plugin runs on the main thread, O(n) or worse** — freeze, confirmed.
- `Selection/SelectionPlugin.swift:258, 342-348, 354, 365-373, 477, 486`.
- Measured core cost at 1M names: `Array(name.lowercased())` 0.12 s, regex `firstMatch` 0.36 s. Add filter, `MaskEntry` building, `name.contains("/")` and `setSelected` on top.
- A path-limited or `A>B` mask adds `pathComponents` per item (`SelectionType.swift:132`), measured about 1.1 µs each, so over 1 s at 1M.
- "Same folder" (`.path`, line 370) and Compare Directories (`SelectionFile.swift:98-164`, several normalise+lowercase passes per name) are similar.
- `foldsCase` (`SelectionPlugin.swift:493-496`) calls `resourceValues` on the main thread; that blocks on a stalled network mount.
- **Fix:** compute name lists on a background queue (with `Parallel.map`), then apply with a `listVersion` guard.

**M2. Data race on `Node.candidates` when a search is cancelled** — threading, confirmed by reading.
- `FindFiles/FileSearch.swift:433, 440` read `node.candidates` without the condition lock; `deliver` writes `node.candidates = []` under the lock (line 369).
- Normally `deliver` only touches a node once `pending == 0`. On cancel it skips the wait and clears every remaining sibling along the current path while workers finish their in-flight `list()`/`checks(for:)`.
- A read racing a release of the array buffer can crash on Cancel.
- **Fix:** take the candidates snapshot inside the lock in `checks(for:)`, or pass `wanted` in from `list`.

**M3. Each cancelled search can leak its whole walk** — leak, confirmed by reading.
- `JobStack.push` (`FileSearch.swift:468-474`) does not check `isClosed`. A worker finishing `list()` after `close()` pushes closures that capture the `Walk`.
- That forms a cycle: Walk → JobStack → closures → Walk, also pinning the `FileSearch`, its query (including `onlyItems`, possibly millions of URLs) and the nodes.
- **Fix:** `guard !isClosed` in `push`.

**M4. No bound on memory anywhere in the search** — performance, confirmed by reading.
- Workers never wait for delivery (`FileSearch.swift:398-426`). One slow front job (a huge file, a stalled mount) lets the other threads list the rest of the tree and buffer every candidate.
- With an empty mask and a text search, that is every file's `FileItem`.
- Results have no cap (`FindFiles/FindFilesWindowController.swift:352-357`). A 5M-hit search likely holds a few GB (my estimate, not measured).
- `runForDuplicates` collects every file before grouping (`FileSearch.swift:268-269`).
- **Fix:** a budget of undelivered candidates that pauses `list` jobs, and a result cap with a "more than N" notice.

**M5. "Search in found files" is quadratic and ignores Cancel** — performance, confirmed by reading.
- `FileSearch.swift:233-238`: `reached` tests every item against every folder with `isInside`, before the cheap name check and with no cancellation check.
- 200k results that include 20k folders is about 4·10⁹ string comparisons, likely tens of minutes.
- The window stays on "[Searching…]", Start stays disabled, and Cancel has no effect until it finishes.
- **Fix:** put folder keys in a set and walk each item's ancestors; test the name first; poll the flag.

**M6. Duplicate finder can list one remote file twice** — data-loss, plausible.
- `FindFiles/DuplicateFinder.swift:94-98`: non-file URLs are kept without any identity check. `FileSearch.swift:257` de-duplicates them by `absoluteString` only.
- Trigger: two start directories that are the same remote place by another spelling or route (`sftp://host/a;sftp://HOST/a`, or a server-side folder symlink given as a root).
- Every file then appears in a group with itself; deleting "the duplicate" deletes the only copy.
- The same applies to one share mounted twice locally (different `st_dev`).
- **Fix:** refuse or mark groups on file systems that offer no file identity; at least normalise host and path, and never put two entries with an equal `locationKey`/provider identity in one group.

**M7. Content search and duplicate hashing read iCloud "dataless" files** — performance/side effect, plausible.
- `FileSearch.swift:292-293`, `DuplicateFinder.swift:113-114`, via `FileHandle(forReadingFrom:)`.
- A text search over a home folder with optimised iCloud storage downloads everything and can fill the disk.
- **Fix:** skip `SF_DATALESS` (from `st_flags`) unless the user asks.

**M8. Multi-Rename moves non-local items of branch views and search results into new nested folders** — correctness, confirmed by reading.
- `MultiRename/RenameRun.swift:17-19` takes the URL's last component only for file URLs. An FTP/SFTP/archive item named by path (`sub/file.txt`, or the full display path) keeps that as its name.
- Any change then yields a name with `/`, and `target(of:named:)` (lines 128-135) resolves it below the item's own folder: `…/sub/sub/file_x.txt`. The folder is created and the file moved there.
- Full display paths such as `ftp://…` mostly become "A folder name is empty", so the tool is unusable on those lists.
- **Fix:** take the name from the URL for all schemes.

**M9. Undo can be pressed again while the first Undo job is queued or running** — correctness, confirmed by reading.
- `isRunning` is only set for Start (`MultiRename/MultiRenameWindowController.swift:316, 536-538`).
- Both jobs capture the same `last` run (`MultiRenameSession.swift:441`). The second finds nothing to restore and calls `replaceLastUndo(with: [])` (line 471), which deletes an older run that was never undone.
- For a swap (`1↔2`) the second job finds both names present and swaps again.
- **Fix:** disable Undo and Start while any of the session's jobs is pending; check that the history's last entry is still the captured one.

**M10. Undo history of a big run is too large for the settings store** — performance/freeze, plausible.
- `MultiRename/RenameStore.swift:166-175`: the latest run is kept whatever its size. A 500k-file run is on the order of 100 MB of JSON (my estimate) in `UserDefaults`, loaded with the defaults domain at every launch.
- It is decoded on the main thread on first access (`RenameStore.swift:136`, reached from `update()` → `canUndo` when the tool opens).
- **Fix:** keep undo runs in a file of their own, read and written off the main thread, with a hard cap.

**M11. `[T4]` opens every listed file with ImageIO on the preview threads** — freeze/security, plausible.
- `MultiRenameSession.swift:509-518`: no check for `isSpecial`, non-regular or dataless files.
- A FIFO in the list blocks that thread for good, and with it the serial preview queue.
- Arbitrary untrusted files are parsed in-process by ImageIO's decoders.
- The date cache is thrown away on every list change (line 141), so one Shift+Down re-reads all files.
- **Fix:** regular, non-dataless files only; keep content dates across reorders; consider an image-extension allow-list.

**M12. A regex-stuck or FIFO-stuck preview also blocks sorts** — threading, confirmed by reading.
- Sorts and previews share one serial queue (`MultiRenameSession.swift:100, 190`). Consequence of H1 and M11.

## Low

**L1. Stack overflow on a very long "Find text"** — crash, confirmed.
- `TextPattern.swift:121-132` recurses once per character on 512 KB threads. A 20,000-character text that occurs in a file crashed with a bus error in `tp/`; 12,000 passed.
- Fix: iterate, with an explicit stack only for alternatives.

**L2. Traps on numeric input** — crash, confirmed by reading (Swift trapping semantics).
- `FindFiles/SearchForm.swift:364`: `Int64(size)` traps for `1e30` or `inf`. Reached when a saved search with such a size is loaded, and that saved search then crashes on every load.
- `SearchCriteria.swift:38`: `-7 * count` traps for a huge "weeks" value (`integerValue` saturates to `Int.max`, checked).
- `SelectionPlugin.swift:381` (`cursor + count - 1`) and `:347` (`abs(Int.min)`) trap for extreme command parameters.

**L3. Same folder reached twice through a firmlink** — correctness, plausible.
- `/Users` and `/System/Volumes/Data/Users` have the same device and inode (checked).
- With a depth limit, a later shallower visit re-walks the subtree (`FileSearch.swift:392-395`) and the hits are reported twice, because de-duplication only runs for overlapping roots (line 250).
- Without a depth limit, which of the two paths is reported depends on thread timing.

**L4. Overlapping roots drop hard links** — correctness, confirmed by reading.
- `FileSearch.swift:254-255` de-duplicates hits by (device, inode), so a second hard link at a different path is not reported.
- Fix: key by path; use identity only for folders.

**L5. End-of-search work on the main thread is O(n) several times** — freeze, plausible.
- `FindFilesWindowController.swift:361-380`: `resultItems`, a rebuild of `rows`, a directory count. Likely around a second at 5M rows.
- `goToFile` (line 472) rebuilds the whole item list on every Enter.
- Cmd+C (`copyText`, line 519) builds one string of all rows.
- `selectedItems` (lines 143-146) walks the whole panel on every `windowDidBecomeKey`.

**L6. Spotlight path returns different results from a walk** — correctness, plausible.
- When the index "handles" the text, the files are not re-checked (`SpotlightSearch.swift:17-19, 80`), so "Case sensitive", the encoding boxes and exact substring matching are not enforced.
- The root filter is a case-sensitive `hasPrefix` on unresolved paths (line 84); a "Search in" typed in another case or through a symlink finds nothing.
- The final sort of all hits (line 92) is not cancellable.

**L7. Regular-file check is stat-then-open** — security, plausible.
- `FileIdentity.swift:25-28`, then `FileSearch.swift:293`; the local reader opens blocking and has no `interrupt`.
- A file swapped for a FIFO in between parks a worker for good; a read on a dead NFS/SMB mount does the same.
- Fix: `open(O_NONBLOCK|O_NOFOLLOW)` + `fstat` on the descriptor, then clear `O_NONBLOCK`.

**L8. `[u]` (precompose) never renames anything** — correctness, confirmed.
- Swift `==` treats NFC and NFD as equal (checked), so `name == diskName` (`RenameRun.swift:167`) says "unchanged" and `moves()` (`RenamePlanner.swift:71-74`) says no move.
- The test at `Tests/PluginTests/MultiRenameEngineTests.swift:176` passes for the same reason.
- Fix: compare UTF-8 bytes.

**L9. Two quick header clicks leave the list in the wrong order** — correctness, confirmed by reading.
- `MultiRenameSession.swift:188-196`: the second sort captured the generation before the first applied, so it is dropped. The header shows descending; the list is ascending.

**L10. Reopening Multi-Rename while its window is open loses the session reference** — correctness, confirmed by reading.
- `MultiRename/MultiRenamePlugin.swift:56-68`: the old window's `onClose` runs after `self.session` was already replaced and sets it to nil. "Last used settings" of the new window are then not remembered.

**L11. Preview is not cancelled when the window closes** — performance, confirmed by reading.
- `MultiRenameWindowController.swift:662`; the session has no `deinit`. A 500k preview runs to the end.
- After Undo there is no `refresh()` (`MultiRenameSession.swift:479-481`), so conflict marks stay stale.

**L12. Multi-Rename main-thread and serial costs per keystroke** — performance, confirmed by reading.
- `refresh()` copies all entries and reads the pasteboard on main (`MultiRenameSession.swift:77, 90`); `update()` runs `counts` and `reloadData` twice per keystroke.
- `planner.conflicts` and `steps` are serial and not cancellable (`RenamePlanner.swift:79-94`).
- Target folders are listed without a cancellation flag (`RenameRun.swift:210`), and listed a second time by `foldsCase` (line 265).
- Any row move discards the whole cache (line 141).
- Measured at 500k: `locationKey` 0.16 s, folded key 0.27 s, sort 2.2 s. This is preview latency, not a UI freeze.

**L13. Planner and runner edge cases** — correctness, plausible.
- `isSameFile` returns true when the target is missing (`RenameRun.swift:309`), so a case-only rename uses a replacing rename with a small race. Non-local URLs always return true (line 303) and rely on the case-folding probe.
- A target folder outside every source folder gets no verdict and is treated as case-sensitive (lines 243-249); the result is an EEXIST failure at run time, not an overwrite.
- Auto-renamed names (`name (2).ext`) are not re-checked against 255 bytes.
- A folder and its children in one list fail in list order, and remaining rows keep stale URLs.
- Undo identifies files by path only, so it can rename a different file that took the name since.

**L14. Loaded name lists may contain absolute paths** — security, confirmed by reading.
- `RenameRun.swift:129-133`: a name starting with `/` moves the file anywhere on the file system and creates folders. It never overwrites, and `..` is rejected.
- Worth a confirmation when names come from a file.

**L15. Selection files and the clipboard are parsed on the main thread** — freeze, plausible.
- `SelectionPlugin.swift:463, 469-478`: the file is capped at 32 MB, the clipboard is not capped.
- Overwriting a selection file is remove-then-write (lines 423-427); a failed write loses the old file.
- The read job ignores its monitor, so it cannot be cancelled.

**L16. `**` in path masks is exponential** — performance, confirmed by reading. `Selection/SelectionMask.swift:59-67`; several `**/` in one mask, on the main thread.

**L17. Regex content search details** — correctness, confirmed by reading.
- A forced cut of a long "line" can split a character or a match (`TextPattern.swift:378`).
- UTF-16 big-endian without a byte-order mark is not searched in regex mode (lines 372-376), though it is in plain-text mode.
- An invalid regex in a Plugins-tab rule is not reported: `regex` never matches and `!regex` always matches (`SearchCriteria.swift:231-232`).

## Shared mutable state

| State | Protection | Verdict |
|---|---|---|
| `Walk.Node` fields (`isListed`, `candidates`, `hits`, `children`, `pending`) | `Walk.condition` | Not sufficient for `candidates`: unlocked reads in `checks(for:)` (M2). The rest is correct. |
| `Walk.visited` | `visitedLock`; `stat` is outside the lock | Sufficient |
| `JobStack.stack`, `isClosed` | its own `NSCondition`; predicate loops | Sufficient for races; `push` after close leaks (M3) |
| `run`'s `reported` sets; the window's `pending`/`lastFlush`; `lastReport` in the duplicates path | confined to the delivering thread; hashing progress serialised by the `NSLock` in `DuplicateFinder` | Sufficient |
| `DuplicateFinder.done` | `NSLock` | Sufficient |
| `CancellationFlag` | internal lock | Sufficient |
| FindFiles window state (`rows`, `search`, `earlier`, `spotlight`) | main thread; batches guarded by `self.search === search` | Sufficient |
| `RenameCache` | `NSLock`; validity of `rows` by count only | Sufficient, because every list change installs a new cache (all paths checked) |
| `MultiRenameSession` state | main thread; preview guarded by flag identity, sort by `listGeneration` | Sufficient, apart from L9 |
| `RenameStore.Memory` | main thread; background encode works on a value copy; `undoWrite` stale guard; `flush` bumps the counter | Sufficient: an older background write cannot overwrite a newer one |
| `RenameStore.memories` | `memoriesLock` | Sufficient |
| `ContentDate.formatter`, `RenameFormats` | shared immutable `DateFormatter`s | Sufficient |
| Selection plugin state | main thread only | Sufficient |

## Checked and found sound

- **Search termination:** no early exit while a worker is about to push subfolders (`pending` stays 1 until `checks` sets it); no lost wake-ups (broadcast under the lock, plus 50 ms timed waits); listing errors finish the node.
- **Walk structure:** symlinked folders are not followed; nested archives are not descended by the same provider; depth limits are right; threads exit on close; the earlier-results cap always keeps the newest list.
- **Block-border carry** for byte needles, including whole-word boundaries and UTF-16.
- **`lastLineEnd`** is bounded by the 4 MB cap, so not quadratic.
- **Glob matcher** is iterative and Unicode-correct.
- **Spotlight query escaping:** quotes, backslashes and `*` are neutralised (parsed back with `NSPredicate` to check).
- **Duplicate finder, local files:** hard links, firmlink aliases, case/normalisation aliases and symlinked roots are all removed; read errors and cancellation never produce a group.
- **Rename planner:** rings and chains via temporary names (a temp-name collision cannot overwrite, the move is exclusive), the `skippingConflicts` worklist, `autoRenamed` numbering, parked-item recovery, what Undo records.
- **Mask language:** ranges, counters, overflow and width clamps hold; `/`, NUL, `.`/`..` and names over 255 bytes are handled.
- **Undo-history write ordering.**

## Not reviewed

- Nothing in scope was built or run except `TextPattern.swift`, compiled standalone with stubs.
- Not measured: `NSMetadataQuery` cost at scale, memory per result, `UserDefaults` behaviour with very large values, `renamex_np(RENAME_EXCL)` on case-only renames.
- Kernel and other plugins were read only where called from scope (`PanelModel` selection, `Parallel`, `CancellationFlag`, local provider read/item/move, job service, `SettingsStore`). The Network and Archives providers' `item(at:)`, `interrupt` and `move(replacing:)` behaviour, which L13 and M6 depend on, was not reviewed.
- Tests were not run.
