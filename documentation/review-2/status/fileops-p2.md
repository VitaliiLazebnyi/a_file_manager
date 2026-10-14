# Fix round 2, second pass — file operations (`fileops-p2`)

Scope: `Sources/Plugins/FileOperations`, `Sources/Plugins/Clipboard`, `Sources/Plugins/FileProperties` and their
tests in `Tests/PluginTests`. Work list: the requests to these three plugins in every `cross-requests/*.md`, the
rows of `OPEN-AFTER-PASS-1.md` whose work is here, the "Not done" list of `status/fileops.md`, and the kernel API
of `status/kernel.md` / `status/kernel-p2.md` §0.

"fixed" means built and covered by a test that passes in the final run. "tested" means the first pass's fix was
left as it is and got the test it lacked. Requests to other areas: `cross-requests/fileops-p2.md`.

## 1. Rows

### Findings of `findings/fileops.md` that were open, partly done or untested

| ID | Status | Note |
|----|--------|------|
| F001, F018, F026 | fixed | `JobSafety.swift` `RealLocation.resolve` asks the provider (`FileSystemRegistry.realLocation(of:)`) first; the inference from `parent(of:)` stays as the fallback for a file system that does not answer. No plugin is imported. Test: `aFileSystemThatSaysWhereItsFilesReallyAreIsBelieved` (a provider that gives the real folder away through `realLocation` only). |
| F002, F011 | needs other area | Clipboard side: Cut/Copy no longer make the list of the operands before the question (`operandsSnapshot()`), name lists are made off the main thread. Drag start and drag-enter are AFMShell (cross-request 3, with new measurements). |
| F003 | fixed | Tested (`aLongListOfNamesIsMadeInTheBackgroundAndTheLatestRequestWins`), and a defect found by the test fixed: a long list that was still being put together landed on top of a text or files put on the clipboard after it (only another *list* overtook it). `ClipboardPlugin.put`/`place` now overtake it too. The list is made on a kernel thread, not a shared dispatch queue. |
| F008 | fixed | `FileOperations.Processed`: the places of the processed items are found on the job's thread and the marks come off by index (`setSelected(_:indices:shownVersion:)`), by name only when the panel shows another list by then. Tests: `theMarksOfWhatWasProcessedComeOffAndTheOthersStay`, `afterACopyOnlyTheCopiedItemsLoseTheirMark`. |
| F009 | tested | `deleteAsksWhatTheFolderCanDoOnceNotPerItem`. |
| F010 | fixed | Also moved off the main thread: which folders were measured, the sum, "all local" (Calculate Occupied Space), the scan of the list for folders (Calculate All Folder Sizes); the sizes are written into a copy of the list on the job's thread (`PanelModel.prepare(_:computedSizes:)` + `apply`, by name when stale). Tests: `whatACommandChangedIsShownInThePanelAfterwards`, `allFolderSizesAreOfferedOnlyWhereThereAreFolders`, `theSizesAreShownAlsoWhenTheListChangedWhileTheyWereWorkedOut`. |
| F021 | fixed | `FileJob.swift`: every `remove`, `move`, `createDirectory`, `setAttributes`, `copyMetadata`, `setQuarantine` and the in-file-system `copy` carries the job's flag; `volume(of:cancellation:)`, the look-ups of `UniqueName` and `TargetSpec.parse` and of `Checksum.sameContents` too. Tidying up after a stop uses a flag of its own (decision 2). `FileOperationsPlugin` (rename, New Folder, New File), `ClipboardPlugin` (paste as file, save details), `Descript.swift` (comment file) pass their job's flag. Not cancellable: `trash` (no such call; local only). Tests: `everyChangingCallOfAJobCarriesTheJobsFlag`, `aRemovalThatWaitsForAServerEndsWhenTheJobIsCancelled`, `tidyingUpAfterACancelStillTakesTheTemporaryFileAway`, `aServerThatDoesNotAnswerTheTidyingUpIsGivenUpOn`. |
| F025 | fixed (this area's part) | Copy, Move, Delete, Rename with a mask, Cut/Copy, the name lists, the details lists and Calculate Occupied Space take `operandsSnapshot()` on the main thread and make the list on the job's thread (`FileOperations.Picked`). Still `operands()` on the main thread: Change Attributes, Create Link, Properties with several items, Rename "each file separately" (see Not done). Verify Checksums: plugins-b-p2. Test: `theOperandsAreCountedWithoutMakingTheListOfThem`. |
| F027 | fixed | `FileOperationsPlugin.prepareToQuit` writes the log in the background and gives up with the flag (`OperationLog.flush(cancellation:completion:)`); `stop()` keeps its 2 s. The log no longer opens anything but a plain file (a pipe at its path held its queue for ever). Failure paths tested: `aLogThatCannotBeWrittenHoldsUpNeitherTheQuitNorItsCaller`, `theLogIsWrittenWhileTheProgramPreparesToQuit`, `aPipeWhereTheLogShouldBeIsNotOpened`. Needs the shell to call `Kernel.prepareToQuit` (cross-request 2). |
| F037 | tested | `aDialogIsNotShownOnceThePanelShowsAnotherFolder` (attributes, comment, link target; and that they do come in the folder they were asked in). |
| F038 | tested (weakly) | `ownerAndGroupAreLookedUpBeforeTheDialogNotWhileItIsMade`, through a new counter `LocalInfo.nameLookups`. The test cannot make a user id unknown, so on a machine where the name was looked up earlier in the run it passes without proving anything. |
| F039 | fixed | `ClipboardPlugin.readFiles`, new `FileListReading`: a list of more than 256 files from another program is read on the main thread a few milliseconds per run-loop turn, inside a job that shows progress and can be cancelled; abandoned when the clipboard changes meanwhile. Measured first (two processes, 50,000 files): one list 2.2 s, `readObjects` 2.7 s, `pasteboardItems` 8 ms, then about 60 µs per item. Tests: `aLongListOfFilesFromAnotherProgramIsReadInSlices`, `aLongListFromAnotherProgramIsPastedWhole`, `aSliceIsShortAndOnlyFileLocationsAreTaken`. Left: see Not done. |
| F040 | tested | Failure path: `aTextThatCannotBeWrittenLeavesNoDraftBehind`. |
| F041 | tested | `theLinesOfAReportAreOnlyPutTogetherWhenAReportGoesOut`. |
| F043 | needs other area | Unchanged; cross-request 6. |
| F046 | fixed in part | The commit is announced and the progress report passed right before it starts, so a paused job waits there. A commit under way still cannot be paused: the provider call takes a flag and nothing else (cross-request 4). Test: `theCommitIsAnnouncedBeforeItStartsSoThatAPausedJobWaitsThere`. |
| F047 | tested | `aFolderThatIsSkippedIsNotWalkedAgainForTheCount`. |
| F052 | tested | `aMarkThatCannotBeSetIsCountedAndNotAskedAbout`. |
| F055 | fixed here, needs other area | Default buttons: decision 1; passed through `UserInteraction.choose(…defaultButton:)`, which the shell's dialog has to honour (cross-request 1). `DisplayName.escaped` and `PropertyText.shown` are `Format.displayName` now (one rule). More messages show names through it (rename, new file, properties, comment). Tests: `returnDoesNotConfirmADeletionThatCannotBeUndone`, `whatGoesToTheTrashIsStillConfirmedWithReturn`, `theQuestionsOfAJobThatDestroySomethingDefaultToSkip`. |
| F070 | tested | `allFolderSizesAreOfferedOnlyWhereThereAreFolders`. |
| F079 | not a defect | As before; the Finder script is started on a kernel thread now, not a dispatch queue. |
| F081 | needs other area | `status/archives.md` A104 says `capabilities` no longer takes the lock; not measured here. |
| F014, F015, F016, F074, F075 | fixed (first pass) | Checked: `rangesNearTheEndsOfIntDoNotCrash` feeds both `nametemplate-slice-*overflow.bin` reproducers, `aMaskThatComesToNothingNamesNothing`, `theDateFormattersAreMadeOncePerText` all pass. No change. |

### Requests from other areas

| Item | Status | Note |
|------|--------|------|
| G002 (general): `Descript.swift` BOM and Character parsing | fixed (first pass, F077/F078) | No change needed; the six reproducers of `Tests/Fuzz/repro/misc/descript-*.bin` now run as a test through the checks of the fuzz harness: `theCommentFilesThatWereMisreadOrLostAreReadAndRewrittenWhole`. |
| viewer 1, plugins-b-p2 1, T024 (V070): listings without the job's flag | fixed | `SpaceCalculator.measure(directory:)`, `AttributeJob.process` list with the flag; a listing cut short counts neither as "unreadable" nor as a failure. Tests: `measuringAFolderOnAServerThatStoppedAnsweringEndsWithTheJob`, `changingAttributesBelowAFolderThatStoppedAnsweringEndsWithTheJob`. |
| viewer 2, T024 (V070): `CommentStore` | fixed | `load`, `loadForUpdate`, `setComment` take a flag (reads are interrupted by it); a thread that waits for another's reading gives up with its flag or after `waitLimit` (10 s); the Comment column is registered with `cancellableValue`. A reading that was cut short is neither remembered nor written from. Tests: `nobodyWaitsForEverForACommentFileThatIsNotComing`, `aCommentThatIsBeingSavedIsNotWrittenFromAReadingThatWasStopped`. |
| T047: `AttributeJob` nests `concurrentPerform` | fixed | `Parallel.map` (the kernel's pool). The copy and delete workers of `FileJob` run on `BlockingCalls.run` threads instead of a dispatch queue. Test: `aTreeIsChangedOnAllCoresWithNothingLeftOut`. |
| network 1, archnet-p2 2: pass the job's flag | fixed | F021 above. |
| network 2 (N009): origin mark | fixed | Checked every `FileJob` path: stream, rename from the temporary name (the mark is on the temporary file), Resume in place, Append/Resume by rewriting (the mark is put back if `copyMetadata` took it), folders, Move. A file from an archive gets what the archive's `quarantine(of:)` answers. Test on the local disk: `whatIsCopiedFromAMarkedFileSystemCarriesTheMarkOnDisk`. Viewer and archive temporaries are theirs. |
| archives 3 (A044): pending writes | fixed | `FileJob` calls `FileSystemRegistry.flushPendingWrites` for every file before it is copied, moved, deleted or trashed; a throw is a failed step and the file is not touched. Tests: `aFileIsBroughtUpToDateBeforeItIsCopiedMovedOrDeleted`, `aFileThatCannotBeBroughtUpToDateIsLeftAlone`. |
| archives 4 (A041): read order | fixed | `FileJob` asks `readOrder(of:)` for the top-level sources and for the entries of every source folder when the files go to another file system; a batch that was reordered is copied one file after another (decision 3). Test: `theSourcesFileSystemSaysInWhichOrderItsFilesAreRead`. |
| localfs 4: names of temporaries | checked | `.afm-<UUID>.tmp` (FileJob), `.<name>.<8>.tmp` (Clipboard, comment file): all have the leading dot and `.tmp`. |
| localfs 5 (L029): exclusive folders | fixed | `FileJob.createFolder` and New Folder use `createDirectory(at:exclusive:cancellation:)`. Tests: `aLinkPutInPlaceOfANewTargetFolderIsNotCopiedThrough`, `aNewFolderIsNotTakenForOneThatAppearedMeanwhile`. |
| shell 5: enabled closures O(1) | fixed in part | Paste: a "yes" (files, text or picture) is remembered by change count. A "no" is not: it cannot be (decision 6); it costs under a millisecond. Count Directory Contents: was fixed (F070). Test: `whetherThereIsSomethingToPasteIsAskedOncePerStateOfTheClipboard`. |
| shell 6, kernel: quit | fixed | F027 above. |
| config-b: `realLocation` | fixed | F001 above. The pasteboard queue asked of the kernel there was declined by the kernel; nothing here reads the pasteboard off the main thread. |
| kernel-p2 §0.2 | adopted | `copy(_:to:cancellation:progress:)`, `createDirectory(at:exclusive:cancellation:)`, `prepare(_:computedSizes:)`, `FileItem.linkTargetSize` (count of a copy that follows links), `PathSafety.isSafeName` (`FileJob.isSafeName` is it now; test `theRuleForNamesIsTheKernels`). Not used: `FileItem.device` (decision 9). |
| fileops 1–6 (own first-pass requests) | adopted | The kernel provided all six; used as described above. 9, 10 were done by localfs, 14 by plugins-a-p2, 15 by the areas named; 7, 8, 11, 12, 13 are still with their areas. |

## 2. Decisions

1. **What Return presses in a question that destroys something.** "Permanently delete": No. Overwrite dialog:
   Skip. "The directory is not empty": Skip. Read-only / hidden / locked / "no Trash, delete for good?": Skip.
   "Is another volume": Skip. "Overwrite" when saving details to a file: Cancel. "Move to Trash" keeps Yes (it
   can be undone). Errors (Skip / Retry / Abort) and Merge are unchanged. This takes effect when the shell's
   dialog honours `defaultButton`.
2. **Tidying up after a stop.** The removal of a temporary file (and the like) is made with a flag of its own:
   with the job's flag, which is set by then, a file system would refuse it and leave the file. A local disk is
   simply asked. A file system that is not the local disk gets 10 seconds (`FileJob.cleanupPatience`); after
   that the job ends and the temporary file stays on the server.
3. **A reordered batch is serial.** Where a file system gave another order than the order of names, the files
   of that batch are copied one after another, not by the pool: several readers at once would undo the order.
   Questions are then asked in that order too.
4. **A file whose pending changes cannot be written is not touched** (copy, move, delete): the step fails with
   the flusher's message and is asked about like any failure.
5. **A name that appears where a new target folder was about to be made** (a link, a folder) is a failed step
   ("already exists") and is asked about; Retry then finds it and merges or refuses as for any existing entry.
6. **No "nothing on the clipboard" is remembered.** `NSPasteboard.changeCount` moves when the pasteboard is
   cleared; what is written after that can arrive under the same count. Tried, and it broke
   `pasteIsOfferedWhileFilesAreOnTheClipboard`.
7. **A long list from another program** (more than 256 files) is read in slices of 6 ms inside a job
   "Reading the clipboard:"; if the clipboard changes while it is read, nothing is pasted.
8. **Finder Info** opens at most 64 windows (the first 64 marked items); before, one per marked item.
9. **`FileItem.device` is not used** for the mount-point question: the job asks the disk when it is about to
   enter the folder, because a listing can be minutes old by then.
10. **Cancelled quick operations say nothing**: a rename, a paste as file, a saved comment or details file
    that the user stopped ends without a message, and the old file is as it was.
11. **A comment reading that does not come back**: the rows that wait for it show no comment after 10 s (or
    when the panel leaves the folder) and ask again later; a reading cut short is not kept.
12. **The log is written to a plain file only**; anything else at its path (a pipe, a device) is left alone and
    the lines are dropped.

## 3. Tests

New files (48 tests):
- `Tests/PluginTests/Review2FileopsP2DataLossTests.swift` — suite `Review2FileopsP2DataLoss` (5).
- `Tests/PluginTests/Review2FileopsP2JobTests.swift` — suite `Review2FileopsP2Job` (15), and the fakes
  `P2ProbeFileSystem`, `P2RacingLocalFileSystem`, `P2ViewFileSystem`, `P2Replies`.
- `Tests/PluginTests/Review2FileopsP2PluginTests.swift` — suites `Review2FileopsP2Commands` (11),
  `Review2FileopsP2Clipboard` (6), `Review2FileopsP2Properties` (6), `Review2FileopsP2PropertyCommands` (5), and
  `P2RecordingUI`, `P2DeferredJobs`, `P2Bench`.

No existing test was changed.

**The data-loss fixes against the code as it was.** `Review2FileopsP2DataLossTests.swift` uses nothing the
program did not have before the round. It was run in a private copy of `build/backups/before-round2-fixes.tgz`
(scratch folder `fileops-p2/old`): **all 5 tests fail there** — the file moved within a branch view is gone; of
two (and of three) sources with one target name only one content is left; Resume wrote through the link over the
other file; the file on the mounted volume was deleted. In the present tree all 5 pass. The fifth item of the
brief, "cancel deleting pre-existing files", is not a defect of the old code: there a cancelled or failed
overwrite left the old file alone, with and without "keep partial files" (read in the old `put`, lines 721–733).
The first pass's `aCancelledOrFailedOverwriteLeavesTheFileThatWasThere` guards the new `removePartial`, which is
the only code that removes something under the real name; it was not run against the old tree (it uses new
types) and would pass there.

Final runs (2026-10-14, the machine loaded by the other agents' builds and tests):
1. `swift test --scratch-path .build-fileops-p2 --filter "Review2Fileops|FileJob|FileOperations|FileOps|Clipboard|FileProperties"`:
   **344 tests in 54 suites passed**, twice in a row after the last change to the sources.
2. `swift test --scratch-path .build-fileops-p2 --filter PluginTests --skip Network`: **1541 tests in 190 suites
   passed, 0 failures** (the last of three runs, made after the last change to the sources; one comment in a test
   was reworded after it and run 1 repeated).
   - The first wide run died after a few seconds with `Fatal error: Index out of range` in
     `FileSearch.Walk.publish` (FindFiles, being edited then; crash report read).
   - The second had 13 issues: 8 in Viewer, Compare and kernel-p2 tests of other areas, and 5 in three of the
     new tests here. Those three set their flag from `DispatchQueue.global().asyncAfter`, which did not run for
     over a minute while every thread of the shared queues was held by other tests. That was a defect of the
     tests and of `FileJob.patience` alike (the same call): both use a thread or a queue of their own now.
KernelTests, ShellTests and the Network suites were not run by this pass.

## 4. Not done

- **F046**: a commit that is under way cannot be paused (needs a provider call that reports while it commits).
- **F002/F011** drag side, **F043** directory-relative removal, **F081**: other areas.
- **F055**: nothing changes for the user until the shell's dialog honours `defaultButton`. **F027**: the same for
  `Kernel.prepareToQuit`.
- **F025**: `operands()` is still called on the main thread by Change Attributes, Create Link, Properties with
  several items, Finder Info for up to 64 items, and Rename "each file separately". They use the list in the
  dialog they open; at 1M nearly-all-marked that is the kernel's 48 ms once per command.
- **F039**: a list of up to 256 files is read in one call (15 ms at 60 µs per file); the first look at a clipboard
  that another program filled costs about 1.7 µs per item on the main thread whichever call makes it (85 ms at
  50,000) and nothing here can avoid it; Pause in the "Reading the clipboard" job does not hold the reading (Cancel does).
- **F038**: the test is weak (see the row).
- `trash` has no cancellable variant; `LinkMaker` and the flag/owner changes of `AttributeJob` are POSIX calls on
  local paths without a flag.
- The enabled closures still ask `capabilities(for:)` of the panel's file system at every validation.
- The Clipboard's Cut and Copy are still not offered in a branch view (as after the first pass; not a finding).
- Build folder `.build-fileops-p2` and the private copy of the old tree are deleted.
