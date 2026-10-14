# Cross-requests from the second pass on file operations (`fileops-p2`)

Scope of the pass: `Sources/Plugins/FileOperations`, `Clipboard`, `FileProperties`. Nothing here blocks
anything: each item has its local part in place. Items of `cross-requests/fileops.md` that other areas have
answered meanwhile are listed in `status/fileops-p2.md`, not repeated here.

## Shell (AFMShell)

1. **`AlertInteraction.choose(…defaultButton:)` must be implemented** (asked for before by fileops 5, network 3,
   kernel.md). The file-operation questions now say which button Return presses; until the shell's dialog
   honours it, the protocol's default ignores the argument and Return still presses the first button. The call
   sites that depend on it:
   - `FileOperationsPlugin.delete`: "Permanently delete" Yes/No → `defaultButton: 1` (No). Move to Trash stays 0.
   - `JobBridge`: Overwrite dialog → 2 (Skip); "The directory … is not empty!" → 2 (Skip); read-only / hidden /
     locked / no-Trash question → 2 (Skip); "… is another volume" → 0 (Skip, which is its first button).
   - `ClipboardPlugin.saveDetails`: "Overwrite:" Overwrite/Cancel → 1 (Cancel).
   Finding: F055.

2. **Call `Kernel.prepareToQuit` before `Kernel.shutdown`** (kernel-p2 §0.1). `FileOperationsPlugin` now writes
   the operation log there, in the background, and gives up when the flag is set. Until the shell calls it,
   `stop()` still waits up to 2 s on the main thread, as after the first pass. Finding: F027, S014.

3. **Drag start and drag-enter with huge selections** (fileops 7 of the first pass, still open: F002, F011).
   Two things measured in this pass that may help there (two processes, a pasteboard of 50,000 file items):
   - the *first* look at such a pasteboard costs about 85 ms whichever call makes it (`types`,
     `availableType(from:)`, `canReadObject`); later looks are free. Nothing avoids that first look.
   - reading the files costs about 60 µs each whichever way (`propertyList(forType: NSFilenamesPboardType)`
     2.2 s, `readObjects` 2.7 s), but `pasteboardItems` itself is nearly free (8 ms), and the items can then be
     asked one by one (`string(forType: .fileURL)`) a few milliseconds' worth per turn of the run loop. The
     clipboard does that now (`FileListReading` in `ClipboardPlugin.swift`); a drop of a long list from another
     program could read it the same way instead of in one call.

## Kernel / Archives / Network

4. **A commit that can be held back while it runs** (F046, the part that is left). `FileJob` now announces the
   commit ("Writing: …") and passes the progress report right before `commit(_:cancellation:)`, so a job that is
   paused before the commit waits there. Once `commit` has been called nothing can pause it: the provider call
   takes a flag and nothing else. Wanted, additive:
   `func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws` (default:
   the call without `progress`), asked by the archive writer between members and by an uploader between blocks;
   `FileJob` would report from it, and the progress window's Pause would take hold inside the commit.

5. **Archives: `capabilities(for:)` on the main thread** (fileops 13, F081): `status/archives.md` A104 says it no
   longer takes the archive's lock. Not re-measured here; listed so that somebody who measures it knows the
   enabled closures of Clipboard, FileOperations and FileProperties still ask it at every validation.

## LocalFileSystem (kernel-p2)

6. **Directory-relative removal** (fileops 11, F043, still open): `FileJob` looks at the disk again (`lstat`)
   before it walks into a folder to delete and before it unlocks an item; between that look and `rmdir`/`unlink`
   by path the folder can still be swapped for a link. Closing it needs `openat`/`unlinkat` inside
   `LocalFileSystem` (a `removeTree(_:cancellation:onEntry:)` or descriptor-based `remove`).

7. `FileItem.device`: `FileJob` does **not** use it for its mount-point question; it asks the disk at the
   moment it is about to enter the folder (`lstat` of the folder and `stat` of its parent), because a listing can
   be minutes old by then. No change wanted; said so that nobody waits for an adoption. `FileItem.linkTargetSize`
   is used (the count of a copy that follows links).

## Navigation (plugins-a-p2) — for information

8. `Review2ConfigBNavigation.theClipboardIsAskedOnlyWhenItsChangeCountChanged` failed in two runs of this pass
   (`isEnabled("afm_CdFromClipboard")` false after `clearContents()` + `setString`) and passed in the later ones,
   so it may be fixed already. In case it is not: the same thing broke a clipboard test here when a "no" was
   remembered by change count. **`NSPasteboard.changeCount` moves when the pasteboard is cleared; data added
   after that can arrive under the same count**, so "nothing there" found right after a clear may be stale a
   moment later. `ClipboardPlugin` remembers only a "yes" by change count and asks again for a "no" (cheap:
   under a millisecond).

## Configuration / others

9. Nothing new. `%L`/`%F` list files (fileops 14) were done by plugins-a-p2.
