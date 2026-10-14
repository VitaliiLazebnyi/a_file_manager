# Cross requests from plugins-a-p2 (Find / Selection / Multi-Rename, Configuration, Places and their neighbours), second pass

Every item has a working local fallback in place; none blocks the round.

## 1. Kernel (`PanelModel`): a sort the user asked for that is met by the loader itself (ViewOptions, K012, C063)

ViewOptions sorts a long list with `basis` -> `PanelModel.prepare(basis, sort:)` -> `apply`. When the folder changes
while the sort is made, `apply` answers `.stale` and the plugin starts again; after `ViewOptionsPlugin.staleTries` (3)
stale answers the main thread sorts the list once with `setSort(_:)` (one pass on all cores, 150 ms at 1M), so the user
always gets the order they asked for. That is a fallback. The better thing, which the plugin cannot do alone because
`sort` and `listedItems` must agree inside the model, is that the **request is kept in the model** and the next list
that arrives is sorted by it by the path that reads the folder:

```swift
/// The order the user asked for, which the list is not in yet. Set on the main thread; O(1).
public func requestSort(_ order: ListOrder)
public var requestedSort: ListOrder? { get }          // nil once the list is in it
```

- `Basis` carries `requestedSort`; `prepare(_:update:…)`, `prepare(_:extendingTo:…)` and `show(_:)` sort an arriving
  listing by `requestedSort ?? sort` and the resulting `Prepared` sets `sort = requestedSort` on `apply` (and clears the
  request). `prepare(_:sort:)` for the same order clears it as now.
- A request made while the list is being sorted in the background simply replaces the earlier one; `apply` of a
  `prepare(_:sort:)` whose order is no longer the request is `.stale`. Then ViewOptions would call `requestSort` and
  `prepare(sort:)` once, and never race a second sort against updates.

## 2. Kernel (`PanelModel.RowSet`): build a row set from indexes off the main thread (Selection)

Selection finds rows with `PanelModel.rows(of:where:)` where the test is a function of the item alone. Three commands
cannot be written that way (a mask with `A>B` that pairs files, a step "every n-th line from the cursor", Compare
Directories, the clipboard/file name lists matched by hash) and so produce `[Int]` indexes of `basis.items`; those are
applied with `setSelected(_:indices:shownVersion:)` / `setSelection(indices:shownVersion:)` on the main thread, O(marks)
(about 10 ms for a million). Wanted, additive: `PanelModel.RowSet.init(basis: Basis, indices: [Int])` (any thread), so
that even this is one `setSelection(rows)`.

## 3. Kernel / local file system: a recursive watch for a branch view (C057)

`VirtualFileSystem.watch` watches up to 512 folders of a branch (one FSEvent stream for all of them) and the upper
levels only for bigger branches. A single recursive watch for a local branch needs `FileSystemProvider.watch` to be able
to say "the directory and everything below it" (e.g. `watch(_ directories:, recursively: Bool, onChange:)`, default
calling the present one).

## 4. Kernel / list file system capabilities (fileops request 12)

`VirtualFileSystem.capabilities(for:)` of a _list_ contains `.write` because that is what lets Delete work on its files.
Withholding Paste / New Folder / New File in a list needs a separate flag (e.g. `FileSystemCapabilities.removeOnly` or
`.createsEntries`); VirtualFolders can set it as soon as it exists.

## 5. Shell: start-up restore of tabs (C072/C111) and the command-line history (C053)

Unchanged from the first pass (`cross-requests/config-b.md`, `config-a.md`): `PanelTabs.init(restoring:)` should use
`FileSystemProvider.connectsToServer` to decide what is shown first; the window's command-line history should follow the
two rules of `systemTools.recordHistory`.
