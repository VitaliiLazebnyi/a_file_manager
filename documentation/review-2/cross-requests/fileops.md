# Cross-requests from the fileops area (review 2)

Each request names the file or type, the behaviour wanted, why, and the finding IDs of
`findings/fileops.md` that depend on it. Everything listed has a local guard in the fileops
code already; none of it blocks.

## Kernel (AFMKernel)

1. **`FileSystemProvider.realLocation(of url: URL) -> URL?`** (default `nil`) — "this location is
   another spelling of that real one". To be implemented by `VirtualFileSystem` (branch and
   selected-branch locations and everything below them: the real URL; lists: nil) and by
   `ArchiveFileSystem` (its "outside" locations: the outer URL). Plus
   `FileSystemRegistry.realLocation(of:)` that follows it to the end.
   Why: Copy/Move/Rename must compare source and target as real places. Today fileops infers it
   (`RealLocation.resolve` in `Sources/Plugins/FileOperations/JobSafety.swift`): a provider whose
   `parent(of:)` answers with the same path under another scheme is taken for a view of that
   place, and an `item(at:)` that answers with a URL of another scheme likewise. An explicit
   API would replace the inference. Findings: F001, F018, F026.

2. **Cancellable variants of the changing calls**: `remove(_:cancellation:)`,
   `move(_:to:replacing:cancellation:)`, `createDirectory(at:cancellation:)`,
   `setAttributes(_:of:cancellation:)`, `copyMetadata(from:to:cancellation:)`,
   `setQuarantine(_:of:cancellation:)`, each defaulting to the call without a flag, implemented
   by the network providers. Why: a stalled server holds a job (and the quit) inside these
   calls until the provider times out; fileops has no way to end them. `FileJob` would pass its
   flag at once. Finding: F021.

3. **A shared helper for showing untrusted names** (`Format.displayName(_:)` or similar in
   AFMContracts): control characters, U+2028/2029, zero-width and bidi override characters
   written out as `<U+XXXX>`. fileops has `DisplayName.escaped` (FileOperations/JobSafety.swift)
   and FileProperties a private copy (`PropertyText.shown`); both would call the shared one.
   Findings: F055, F060.

4. **`PanelModel.deselect` for many names / by URL** without the per-name search (97 ms at
   300k on main), and a cheaper `operands()` (256–441 ms at 300k–1M on main at every command
   start). fileops now computes the names to deselect on the job thread; the model call and
   `operands()` themselves remain. Findings: F008, F009, F025.

## Shell (AFMShell)

5. **`AlertInteraction.choose`: the default button of a `.critical` question** must not be the
   destructive one. Either make the last button the Return default for `.critical`, or give
   `UserInteraction.choose` a `defaultButton:` parameter. fileops cannot reorder its buttons
   safely, because Esc chooses the last one. Affects "Permanently delete" (Yes/No) in
   `FileOperationsPlugin.delete`. Finding: F055.

6. **Quit: flush the operation log from `applicationShouldTerminate` with `.terminateLater`**
   instead of relying on `Plugin.stop()` on the main thread. `FileOperationsPlugin.stop()` now
   waits at most 2 seconds (`OperationLog.flush(timeout:)`); with the shell change it would not
   have to wait on main at all. Finding: F027.

7. **Drag start and drag-enter with huge selections** (`PanelViewController+Interaction.swift`,
   `FileGridView.swift`, `PanelDragAndDrop.swift`): keep in-app drags in memory keyed by the
   drag sequence number, and do not read every item back on drag-enter. Measured here while
   fixing the clipboard side: (a) `NSFilenamesPboardType` cannot be given to an
   `NSPasteboardItem` data provider ("not a valid UTI"), so one lazily provided item cannot
   carry a file list that other programs read as files; (b) with the legacy
   `declareTypes(owner:)` route the list is lazy but `readObjects(forClasses: [NSURL.self])`
   does not see it, and providing 100k paths took 36 s; (c) `writeObjects` from a background
   thread works but the items become visible one by one, and a later `clearContents` on the
   main thread does not stop it (the rest is appended to the new contents). So the per-item
   cost cannot be moved off the main thread safely; the clipboard now asks before writing more
   than 1000 files for other programs. Findings: F002, F011.

8. **The job monitor's pause gate** (`ProgressJobService`): `FileJob` now also sets the job's own
   cancellation flag when the user answers Abort or Cancel in a question, which opens the gate.
   A gate that watched "the job has ended" directly would not need that. Finding: F046.

## LocalFileSystem

9. **`LocalFileSystem.read`: open with `O_NONBLOCK` (and `O_NOCTTY`), `fstat`, refuse what is
   not a regular file**, then clear `O_NONBLOCK`; and make the opening end early for the
   `cancellation` variant. fileops refuses special files before opening (FileItem.isSpecial plus
   its own `stat`), which leaves the window between the check and the open. Findings: F007,
   F017, F066.

10. **`LocalFileSystem.append(to:at:cancellation:)`: open with `O_NOFOLLOW`.** fileops no longer
    offers or performs Resume/Append onto a link (checked at planning and again right before
    opening); `O_NOFOLLOW` closes the window between. Findings: F022, F033.

11. **`LocalFileSystem.setAttributes`: never follow a link** (`fchmodat(..., AT_SYMLINK_NOFOLLOW)`,
    `lutimes`/`utimensat(..., AT_SYMLINK_NOFOLLOW)`), and directory-relative removal
    (`openat`/`unlinkat`) for trees. fileops re-checks with `lstat` before it changes
    permissions, before it unlocks an item and before it walks into a folder to delete, which
    narrows the check-then-use race but cannot close it. Findings: F032, F043.

## VirtualFolders

12. `VirtualFileSystem.capabilities(for:)` of a **list** contains `.write` (meaning: its files can
    be deleted), so Paste, New Folder and New File are offered in a list although nothing can
    be created there. fileops refuses a list as a target with a message; a separate capability
    for "entries can be removed" would let the commands be withheld. Finding: F026.

## Archives

13. `OpenArchive.capabilities` takes a lock that a long archive operation holds; the enabled
    closures of the clipboard, file-properties and file-operations commands ask
    `capabilities(for:)` on the main thread at every menu validation. It should answer from a
    value that needs no lock. Finding: F081. Also `ArchiveCommands.swift:320` uses
    `selection.count > 1` (builds a set of all marks); `selectionCount` is O(1). Finding: F058.

## Configuration

14. `ParameterExpansion.swift:514-516`: a newline in a file name adds entries to `%L`/`%F` list
    files. Not in fileops. Finding: F055.

## Other areas with the same read loop (F034)

15. `FindFiles/DuplicateFinder.swift:121`, `FindFiles/TextPattern.swift:314-347`,
    `FindFiles/FileSearch.swift:461`, `DirectorySync/SyncComparison.swift:342`,
    `FileTools/ToolRun.swift:135` and `FileTools/ChecksumFiles.swift` read block by block without
    an `autoreleasepool`; the fileops loops (FileJob, Checksum, Descript) now have one per block.
