# Cross-requests from the plugins-b-p2 agent (Viewer, DirectorySync, CompareContent, FileTools, second pass)

Nothing here blocks the four plugins; each has a local fallback already.

## 1. FileProperties (still open from the first pass: V070, T024, T047)

`Sources/Plugins/FileProperties/SpaceCalculator.swift` (`measure`) and `AttributeChange.swift` (`AttributeJob.process`) still call
`provider.list(_:showHidden:)` without the job's flag; `Descript.swift` (`CommentStore`) waits on a condition with no time-out and
loads without a flag. Wanted as in `cross-requests/viewer.md` items 1 and 2: `list(_:showHidden:cancellation:)` with the job's flag
and a cancellable wait. (The same request was first made in `cross-requests/viewer.md`; nothing in the four plugins changes it.)

## 2. Shell: call `Kernel.prepareToQuit` before `Kernel.shutdown`

`ViewerPlugin` now implements `prepareToQuit(cancellation:completion:)` (closes its windows, deletes the temporary copies of remote
files in the background, calls `completion` when they are gone), so that `stop()` finds nothing to wait for. It only helps once the
shell calls `Kernel.prepareToQuit` from `applicationShouldTerminate` (`.terminateLater`) as `status/kernel-p2.md` §0.1 describes.
Until then `stop()` does the same work and waits at most 2 s, as before.

## 3. Quarantine mark on the copies the Viewer makes (network.md item 2)

Done in `Viewer/UI/RichViews.swift` (`TemporaryCopies.localCopy`): the source's `quarantine(of:)` is put on the local copy. The
FileTools and DirectorySync copy paths: DirectorySync already did it (`SyncPlan`, streamed copies); FileTools writes new files from
what it computes (checksums, parts, decoded data) and has no copy of a remote file to mark.
