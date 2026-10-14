# Cross-requests from the kernel agent (kernel)

Nothing here blocks a kernel fix: every old call still works and is faster than it was. These are the places where
another area has to call the new API for a kernel finding to be fixed all the way to the user. The new APIs are
described in `documentation/review-2/status/kernel.md` ("New kernel API").

## For the shell agent (AFMShell)

1. **Read directories off the dispatch queues** (K004, K007, K040, K056). `Sources/AFMShell/Panel/PanelLoading.swift`
   (~97, ~167) starts `PanelLoader.stream` on `DispatchQueue.global`. Inside `stream` every blocking question to the
   file system now runs on a kernel thread and the calling thread only waits, cancellably, so a dead share no longer
   strands a thread per refresh; but the waiting thread is still one of the global queue's for as long as the load
   is not cancelled. Wanted: start the reader with `BlockingCalls.run { ... }` instead of `DispatchQueue.global().async`,
   and cancel the previous load's flag on every refresh and navigation (a cancelled `stream` returns at once).
   Any other place that asks a provider something that can block (`volume(of:)` after `volumeInfoDidChange`,
   `places()`, `item(at:)`) should use `BlockingCalls.answer(from:to:cancellation:_:then:)`.
2. **Sort, filter and refresh long lists with `prepare` / `apply`** (K012, K016, K017, K018).
   `PanelViewController+Interaction.swift` (~89-95) and `PanelViewController.swift` (where pieces are applied with
   `extend`, and reloads with `update(with:)`): take `tab.basis` on the main thread, call
   `PanelModel.prepare(basis, filter:)` / `prepare(basis, update:focus:presorted:)` /
   `prepare(basis, extendingTo:sortedBy:)` in the background, then `tab.apply(prepared)` on the main thread. `.stale`
   means: take a new basis and prepare again in the background (nothing was done on the main thread). The old calls
   still work and now use all cores, but they do the filtering and the mark carrying on the calling thread.
3. **Restore the quick filter with a snapshot** (K013, K014). `PanelModel.Snapshot` now holds the filter and the
   order, and `restore` puts the filter back. `PanelViewController` (~601-603, 657, 783) drops its own quick-filter
   entry before `open`; after `tab.restore(before)` it should set that entry again from `before.filter` (public).
4. **`UserInteraction.choose(_:detail:buttons:style:defaultButton:)`** exists with a default that ignores
   `defaultButton` (asked for by network #3 and fileops #5). `AlertInteraction` should implement it: `nil` = no button
   answers Return.
5. **`SettingsStore.largeData(forKey:)` / `setLarge(_:forKey:)`** exist with defaults that keep the value with the
   rest (asked for by find #6). The real store should keep such values in files of their own, written off main.
6. **Quit**: `Kernel.shouldTerminate()` and `Kernel.prepareToQuit(cancellation:completion:)` exist (tools #1,
   archives #1, shell #6, fileops #6). `applicationShouldTerminate` should call the first (cancel the quit on
   false), then, after the jobs are drained, the second with `.terminateLater` and a Cancel that sets the flag.
7. **Drags and the status line**: `PanelModel.operandsSnapshot()` is the value asked for in shell #1 (its shape
   differs: `isMarked(at:)` takes an index of `shownItems`, and `items()` / `markedItems()` build the list on any
   thread). `PanelModel.totals` is O(1) after select all / invert, and one parallel pass otherwise.

## For config-a (ViewOptions)

8. **Sort in the background with `prepare` / `apply`** (K012, K017, K022). `ViewOptionsPlugin.swift` (~190-200):
   `let basis = model.basis`, background `PanelModel.prepare(basis, sort: order)`, main `model.apply(prepared)`; on
   `.stale` repeat. That also removes the filtering and mark carrying that `setSort(_:presorted:)` still does on the
   main thread, and the fall-back `model.setSort(order)` on the main thread.
9. **Unsorted after another order** (K047). The model keeps its list sorted, so the order the entries came in is
   gone once another key was used; `Sorter.resort(to: unsorted)` can only leave the files as they are. Wanted: when
   the user chooses Unsorted and the previous key was another one, reload the panel after `setSort`
   (`kernel.panels.source.reload()`), which brings the entries in the order the file system gives them.
10. `ViewOptionsPlugin.swift:128` and other `enabled:` closures: `model.hasSelection` (new, O(1)) or
    `selectionCount > 0` instead of `!selection.isEmpty`.

## For the find agent (Selection plugin)

11. **Marking at scale** (K010, K019, K020). `SelectionPlugin.swift` (~240-258, ~338-354): use
    `model.select(where:select:)` (all cores, on the calling thread: 1-15 ms at 1M) or, for the longest lists,
    `PanelModel.rows(of: model.basis, where:)` in the background and `model.setSelection(rows, .add / .remove /
    .replace)`. `selectAll`, `invertSelection`, `saveSelection`, `restoreSelection` are O(n/64) now; the plugin's
    own name lists and 20,000-name pieces are no longer needed. For exact names use `model.selectedNames`
    (one per marked entry, as written) instead of `model.selection`.
    Note: indexes of `items` are guarded by `model.shownVersion`, not `listVersion` (which no longer moves with a
    filter): `setSelected(_:indices:shownVersion:)`, `setSelection(indices:shownVersion:)`.

## For the localfs agent

12. **`volume(of:cancellation:)`** (K004, K040) is a protocol requirement now, with a default that calls
    `volume(of:)`. `LocalFileSystem` should implement it so that the `statfs` / resource-value calls can be given up
    (run them where they can be abandoned, or check the flag between them), and likewise the network providers.
13. `FileItem.linkTargetSize` and `FileItem.device` exist (localfs #1); `FileSystemRegistry.placesDidChange` exists
    with the raw name `AFMPlacesDidChange` (localfs #2); `createDirectory(at:exclusive:)` exists with a default that
    looks with `item(at:)` first (localfs #5): the local file system should implement it with `mkdir` alone.

## For the archives, network, tools and file-properties agents: path safety

14. **`PathSafety`** (AFMKernel, `FileSystem/FileItem.swift`) is the byte-based helper for names and paths from
    outside. The three places the fuzzers got through split on `Character`
    (`Tests/Fuzz/repro/arch/containment-slash-combining-mark.{zip,tar}`,
    `repro/tools/decode-containment-slash-combining-mark.bin`, `repro/tools/combine-containment-slash-combining-mark.crc`,
    and `RemotePath.normalized` in `Network/ServerAddress.swift:65`). Wanted there:
    `PathSafety.location(ofRelativePath:below:)` (or `components(ofRelativePath:)` and `isContained(_:in:)`) in
    place of the local splitting, and `URL.appending(safeName:)` for single names.

## For whoever owns `Tests/Fuzz` (fuzz-kernel)

15. Three checks of `Tests/Fuzz/pkg/Fuzz/fuzz-kernel/main.swift` state the old behaviour and now fail by design:
    - `sorter-nokeys-differs-from-definition`: `Sorter.sort(_:by:collator: .unavailable)` is the order of the
      fallback keys (lowercase), not that of the system's collator. Compare it with
      `Sorter.areInOrder(_:_:by:collator: .unavailable)` instead.
    - `panel-selectioncount-vs-marked-names` (target `paneldup`): marks belong to entries now, so two entries of
      the very same name can be marked one without the other; `selectionCount` is the number of marked rows.
    - `panel-selection-set-size`: `selection` is a `Set<String>` and still holds one member for two names that
      read the same (documented); `selectedNames` has one per marked entry.
    I ran a private copy of the harness with those three adapted (and with added checks that the comparison is an
    order, that `selectedNames`, `operands()` and `isSelected(_:)` agree with the marked rows) under the address
    sanitizer: filemask 1.35M, panel 39k, paneldup 20k, sorter 1.6k executions, no finding. The kernel reproducer
    `repro/kernel/panel-computed-size-shown-vs-listed.bin` passes with the unchanged harness.
