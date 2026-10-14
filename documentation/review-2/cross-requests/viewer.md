# Cross-requests from the viewer area

## FileProperties / FileTools (V070, V038)

Nothing here blocks the viewer; these are the parts of two viewer-area findings that sit in code the viewer agent does
not own.

1. `Sources/Plugins/FileProperties/SpaceCalculator.swift:~95` (`measure`) and
   `Sources/Plugins/FileProperties/AttributeChange.swift:~298` (`AttributeJob.process`): they call
   `provider.list(_:showHidden:)`. Wanted: the variant `provider.list(_:showHidden:cancellation:)` with the job's flag,
   as `FileTools/ChecksumFiles.swift:250` and now `Viewer/Model/FolderSummary.swift` do, so a listing on a stalled
   server ends when the job is cancelled and does not hold Parallel pool threads. (Finding V070.)
2. `Sources/Plugins/FileProperties/Descript.swift:~187-223` (`CommentStore`): `load` reads without any cancellation, and
   every column thread for that folder waits in `condition.wait()` with no time-out. Wanted: a cancellation flag (or a
   time-out) on the wait, and on the read. (V070.)
3. `Sources/Plugins/FileTools/FileToolsPlugin.swift:~291` (`createChecksums` clears the selection with no directory
   check) and the splitter (`Splitter` closes its reader twice on an error): both are named in finding V038 as "viewer
   leftovers" but live in FileTools. Wanted: check that the panel still shows the directory before clearing the
   selection; close the reader once. (V038.)
