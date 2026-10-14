# Cross-requests from the shell agent (shell)

The shell has a working local fallback for every item below; none of them blocks the round.

## 1. Kernel: marks of a `PanelModel` readable off the main thread (S055, S004/S033, S015)

File: `Sources/AFMKernel/Panels/PanelModel.swift`. Wanted, additive:

```swift
/// The shown items and a test for "is marked", both safe to use on any thread: a snapshot of
/// the list and of the marks as they are now (copy-on-write, O(1) to take).
public func operandSource() -> (items: [FileItem], isMarked: (FileItem) -> Bool, cursorItem: FileItem?)
```

Why: a drag that starts on a marked row calls `operands()` on the main thread (O(n): 26 ms at 100k marked, 390 ms at
1M). With the snapshot the shell would build the list of dragged items in the background (`Background.compute`) like
everything else it does per drag. Until then `PanelViewController.draggedItems(fromRow:)` calls `operands()` once per
drag on the main thread; everything after that (the places of the sources, the pasteboard) is already lazy.

The same snapshot would let the status line count the selected totals of a very long list off the main thread (S015:
`PanelModel.totals` recounts every item after a multi-item selection change, 212 ms at 1M). If `PanelModel.totals`
itself becomes O(1) after `selectAll` / `invertSelection` / `select(mask:)` (kernel findings K010, K019, K020), nothing
is needed for that part.

## 2. Kernel: `PanelModel.setListed` with a filter, and `listVersion` on a no-op refresh (S001, S018)

Already kernel findings K012, K016, K017, K018. For the shell they matter in two places:

- `PanelViewController.setFilter` now never falls back to filtering on the main thread: a result for a list that changed
  meanwhile is worked out again in the background. That retry is only needed because `listVersion` moves with every
  piece, every computed size and every no-op refresh; it becomes rare once K017 is fixed.
- While a filter is set, every arriving piece is still filtered on the main thread inside `setListed`. Wanted
  (additive): `show` / `extend` / `update(with:)` variants that take the already filtered list, e.g.
  `extend(to:sortedBy:prefiltered:)`, so `PanelLoading` can filter each piece on its own thread.

## 3. Kernel: cancellation for `ContentColumn.value` (S048)

File: `Sources/AFMKernel/PluginAPI/ContentColumns.swift`. Wanted, additive: a second initialiser whose `value` takes a
`CancellationFlag` (`value: (FileItem, CancellationFlag) -> String`), so a column that reads the file can give up when
the panel leaves the folder. The shell already keeps a stalled value from blocking other folders (one batch per folder
lane, `ColumnValueStore`), so this is an improvement, not a fix.

## 4. Kernel: say in `JobMonitor.report` that it may block (S043)

File: `Sources/AFMKernel/PluginAPI/JobService.swift`, doc comment of `JobMonitor.report`. Wanted text: "May block for as
long as the user keeps the job paused. Do not call it while holding a lock that the main thread, or a question asked
through `ask`, may take." (`FileJob` calls it under its `counters` lock, kernel finding K055; that is safe today because
nothing on the main thread takes `counters`.) The shell side documents the same in `ProgressJobService`.

## 5. Plugins: `enabled:` / `checked:` closures must be O(1) (S004, S033, S034, S072)

The shell no longer validates the whole menu bar for a key (`MenuKeys`, `menuHasKeyEquivalent`), and the bars back off
after a slow validation pass, but the closures themselves are the plugins':

- `Sources/Plugins/SystemTools/SystemToolsPlugin.swift:54,70` (Print): use
  `model().directory.isFileURL && model().hasOperandFile` instead of `!localFiles().isEmpty` (builds the operand list:
  390 ms at 1M marked).
- `Sources/Plugins/ViewOptions/ViewOptionsPlugin.swift:128` (Only Selected Files): `selectionCount > 0` instead of
  `!selection.isEmpty` (builds a `Set<String>` of all marks).
- `Sources/Plugins/Clipboard/ClipboardPlugin.swift:62,129` and `Sources/Plugins/Navigation/NavigationPlugin.swift:132`
  (Paste, Paste Path): cache the pasteboard verdict by `NSPasteboard.changeCount`.
- `Sources/Plugins/FileProperties/FilePropertiesPlugin.swift:56` (Count Directory Contents): no scan of all items.

## 6. Plugins: quit work on the main thread (S013, S014)

`Kernel.shutdown()` calls every plugin's `stop()` on the main thread from `applicationWillTerminate`. Archives
(`ArchivesPlugin.stop` → `flushAll`), FileOperations (`OperationLog.flush`), Network (`NetworkPlugin.stop`, QUIT per
idle FTP connection) and Places (`TreeCache.flush`) block there for seconds or longer. Wanted: either each plugin makes
`stop()` return at once and bounds its own flush, or the kernel offers an additive
`Kernel.shutdown(deadline:completion:)` that runs the stops off the main thread; the shell would then call it from
`applicationShouldTerminate` in the `.terminateLater` phase (it already replies asynchronously there for running jobs:
`Shell.stopJobsToQuit`). Also in S013: `ViewerPane.stopWork` (reader close on main),
`ArchiveFileSystem.capabilities(for:)`, `AttributeDraft.fields` (`getpwuid_r`), `VirtualFileSystem.watch` (up to 512
folders; the shell now calls `watch` off the main thread, one folder per call).

## 7. Build files: `Resources/Info.plist`, `Scripts/build-app.sh` (S041, S042)

Not in any directory the shell agent owns.

- S041: add `NSAppleEventsUsageDescription` to `Resources/Info.plist` (FileProperties drives Finder through osascript).
- S042: `Scripts/build-app.sh` signs ad hoc without `--options runtime` and without entitlements, so
  `DYLD_INSERT_LIBRARIES` is honoured. Wanted: `codesign --options runtime` (hardened runtime) with an entitlements file
  that grants only what the program needs (Apple events).

## 8. Local file system: answered

Request 3 of `localfs.md` is done: `PlacesStore` (Sources/AFMShell/Window/PanelCoordinator.swift) observes the
notification named `AFMPlacesDidChange` (any object) and the workspace's mount notifications, asks every file system for
`places()` again in the background, and the drive bar and an open volume menu follow.

## 9. Kernel: `Kernel.askUser` starts its dialog inside a main-queue block (S023, S024)

File: `Sources/AFMKernel/PluginAPI/Kernel.swift`, `askUser`: `DispatchQueue.main.sync { question(ui) }`. A modal dialog
started from inside a block of the main dispatch queue keeps every later main-queue block waiting until it is closed
(directory pieces, progress, timers of the queue). Wanted: hop through the run loop instead, as the shell's
`ProgressSheet.ask` now does:

```swift
if Thread.isMainThread { return question(ui) }
var answer: Answer?
let done = DispatchSemaphore(value: 0)
withoutActuallyEscaping(question) { question in
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { answer = question(self.ui); done.signal() }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    done.wait()
}
return answer!
```

The same for `Sources/Plugins/Configuration/CommandRunner.swift:234` (verdict S024) and any plugin that shows an alert
from `DispatchQueue.main.async`: use `RunLoop.main.perform(inModes: [.common])`, or go through a job's `JobMonitor.ask`.
