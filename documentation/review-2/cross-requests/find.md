# Cross-requests from the `find` area (FindFiles, Selection, MultiRename)

Everything here has a safe local fallback already in the `find` plugins; the requests make it faster or safer.

## 1. Kernel (`PanelModel`): bulk marking by row, and an off-main snapshot of the marks

Findings: R010, R035 (Selection at scale).

Today `setSelected(_:names:)`, `setSelection(names:)`, `selectAll()`, `invertSelection()`, `restoreSelection()` and
`operands()` are all O(n) on the main thread and look every name up (the first calls build a `[String: Int]` of all 1M
names on main). The Selection plugin now works the name lists out in the background and applies them in pieces of 20,000
names, guarded by `listVersion`, but the first piece still pays for the name index and each piece for the lookups.
Wanted, all additive:

- `public func setSelected(_ selected: Bool, indices: some Sequence<Int>, listVersion: Int) -> Bool` : marks the items
  at these indexes of `items` (no name lookup); does nothing and returns false if `listVersion` is not the model's
  current one. A `replacing:` variant (or `setSelection(indices:listVersion:)`) for "make exactly these the selection".
- `public func invertSelection()`, `selectAll()`, `restoreSelection()` that are O(n) over `ExactName` keys without
  building a `Set` of all names on main, or an async variant `func invertedSelection(completion:)` that returns `[Int]`
  computed off-main.
- A cheap, copy-on-write snapshot of the marks usable off the main thread, e.g.
  `public var selectionSnapshot: SelectionSnapshot` (a `Sendable` struct with `contains(_ item: FileItem)`, `count`), so
  that invert / restore / operands can be worked out in the background and exactly (the plugin now uses
  `model.selection`, a `Set<String>`, for lists above 20,000 items, which treats two names that read the same as one).
- `operands()` is an O(n) filter on main (Selection save-to-file, Multi-Rename open). A `PanelModel.operandsSnapshot()`
  returning the items and the marks for off-main filtering would remove it.

## 2. AFMContracts `FileListService`: a list that is already unique

Finding: R011 (VirtualFolders `register(files:)` / `unique()` is O(list) on main; Find Files hands it up to 2,000,000
URLs). Find Files keeps its result URLs unique and in order (it de-duplicates while it reports). Wanted:
`func show(_ files: [URL], title: String, in panel: PanelHandle, isUnique: Bool)` (default `false` = today's behaviour),
so that the service need not build a key per URL on the main thread. The service's own `unique()` should in any case
move off main (VirtualFolders area).

## 3. LocalFileSystem (`move(_:to:replacing:)`): DATA LOSS hazard on a rename that changes only the way an accent is written

`LocalFileSystem.move` with `replacing: true` decides after a successful `rename(2)` whether to `unlink(source.path)`
("two names of one file") with `entryNamed(source)`, which compares names with `precomposedStringWithCanonicalMapping`.
For `e` + U+0301 renamed to U+00E9 (same inode, normalization-insensitive volume) `entryNamed(source)` is true although
the rename has already given the file its new name, so `unlink(source.path)` removes **the file itself** (the path
resolves to it). Multi-Rename's `[u]` (precompose) used to be a no-op because of an unrelated bug (R060); now that it
renames, Multi-Rename never uses `replacing: true` for this case (it goes by way of a temporary name), but any other
caller can hit it. `entryNamed` should compare the stored name byte for byte
(`Array(name.utf8) == Array(url.lastPathComponent.utf8)`), or the unlink should be skipped when `source` and
`destination` names are canonically equal.

## 4. LocalFileSystem `read(_:)` (R062)

Find Files and the duplicate finder now open local files themselves (`open(O_RDONLY|O_NONBLOCK)`, `fstat`, regular and
not dataless, then clear `O_NONBLOCK`), because the provider's `read` opens blocking after a separate `stat`. The
provider itself has the same stat-then-open gap for every other caller (viewer, copy, compare): the same `open` +
`fstat` on the descriptor would close it there.

## 5. DirectorySync `SyncSession.adopt`, CompareContent `CompareOperands.choose` (R024)

Both walk the whole panel with a set lookup per item when 300k are marked (100-200 ms at 1M; `adopt` also sorts the 300k
names). They should ask `model.selectionCount` first, take `operands()` only when needed, and (with item 1) work off the
main thread. (The Find Files part of R024 is fixed: it asks `selectionCount`.)

## 6. SettingsStore (R031/R032)

The Multi-Rename undo history is still kept in the settings (JSON). It is now capped (50,000 renamed files in all, a
bigger newest run is kept in memory only), counted without decoding (`undoCount` key) and decoded in the background. A
file of its own (read and written off main) would remove the multi-megabyte `Data` hand-over to `SettingsStore.set` that
still happens on the main thread for a run of up to 50,000 files: e.g. `SettingsStore.setLarge(_:forKey:)` /
`largeData(forKey:)` backed by a file in Application Support, with the write on a background queue.
