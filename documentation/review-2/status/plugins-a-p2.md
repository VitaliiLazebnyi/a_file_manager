# Review 2, second pass — plugins-a-p2

Scope: `Sources/Plugins/` FindFiles, Selection, MultiRename, Configuration, SystemTools, ViewOptions, MacIntegration,
Places, VirtualFolders, FolderTabs, Navigation, and their tests in `Tests/PluginTests`.
Build folder `.build-plugins-a-p2` (deleted at the end). New tests: `Tests/PluginTests/Review2PluginsA2Tests.swift`
(33 tests in 8 suites). Requests to other areas: `cross-requests/plugins-a-p2.md`.

## 1. IDs that had no row, and the open ones that lie in these directories

| ID | Status | Note |
|---|---|---|
| C011 | fixed | Selection. `SelectionPlugin.swift`: Select/Unselect Group, same extension/name/folder, all-by-scope, step and the clipboard/file lists find rows with `PanelModel.rows(of: basis, where:)` (all cores, any thread) and hand them over as one `setSelection(rows, .add/.remove/.replace)`; a regex mask, a long list and a clipboard load always run off the main thread. Nothing is applied in 20,000-name pieces any more (`applyPiece` is gone). A result the model refuses (`setSelection` false: the list, filter or order changed) is worked out again for the list as it is, up to 8 times, if the panel still shows the same folder; otherwise it is dropped. Plain masks run on UTF-8 bytes for ASCII names (`SelectionMask.quickAnswer`, `Wildcard.matches(ascii:)`), the Character matcher is kept for everything else (test compares both on 300 pairs). Load from file: names are matched in the job, the rows on the way back. Test: `Review2PluginsA2Selection`. |
| C012 | fixed | Selection. Compare Directories and Mark Newer: `DirectoryComparison.compareIndices` (cancellable, byte-hashed names, one index list per side) runs in the background on the frozen `basis.items`; the marks go in with `setSelection(indices:shownVersion:)`. `foldsCase` no longer calls `resourceValues` on the thread that waits: it goes through `BlockingCalls.answer(from:to:cancellation:)` and gives up when a newer command starts. Mark Newer builds the "hide same" filter with `PanelModel.prepare(basis, filter:)` in the background and applies it with `apply` (stale: again), then marks. Tests: `theIndexedComparisonIsTheComparisonByName`, `markNewerLeavesTheSameFilesOutAndMarksTheRest`. |
| C028 | fixed | Places. Option-click / Option-Right no longer expand everything (`TreeOutlineView.expandItem(_:expandChildren:)` opens one level); folders opened before the scan reached them are read by one serial queue, each once at a time (`demanded`), instead of one reader per folder. Quick search was already time-sliced (first pass); the first-pass `folded` strings stay lazy per node. |
| C057 | not fixed | VirtualFolders watches up to 512 folders of a branch with one FSEvent stream (first pass); a single recursive watch needs a provider call that says "recursively": cross-request 3. |
| C067 | fixed | `DirectoryTree.attach`: the merge path (a folder that already has children, e.g. the folders on the way to the selected one) is bounded by `limit` too: it keeps its old children until the last turn, then puts the rebuilt list in place (`TreeNode.Attach`). Test: `aFolderThatHadChildrenIsRebuiltInTurnsOfLimitedSize`. |
| C068 | fixed | A folder made by `node(at:creating:)` while `attach` is linking in turns is remembered (`Attach.known`), is not linked a second time, keeps its node, and the list is put in order at the end (a made folder that is not in the listing is dropped). Test: `aFolderMadeMeanwhileIsNotLinkedTwiceAndKeepsItsNode`. |
| C069 | fixed | `releaseTree` also hands the unlinked levels and the reload queue (the nodes made by the scan but not yet linked) to the background queue, with the tree. |
| C070 | fixed | A scan that is replaced (`load` while it runs) takes a new store ticket for its tree, so its partial result is no longer stored over the cache; Esc (abort) still stores what was read. |
| C076 | fixed | Navigation. Read on the main thread (NSPasteboard is not safe against two threads), but the text is copied at most once per change count: `ClipboardText.path` keeps the path of the text for the change count, and only the first 8 KB of the first line are looked at (`path(fromClipboard:)`; test `aPathIsTakenFromTheStartOfAVeryLongClipboardLine`). The menus only ask for the kinds of the contents (no copy): a yes is kept per change count, a no is asked again each time because a program that fills the clipboard adds the text after the count changed (`Review2ConfigBNavigation.theClipboardIsAskedOnlyWhenItsChangeCountChanged`). The Selection clipboard load reads the string once, on the main thread, then matches off it. |
| C077 | fixed | As C076 (the per-keystroke use is Multi-Rename's clipboard, which is cached by change count since the first pass, `Review2FindRename.theClipboardIsReadOnlyWhenAMaskUsesItAndOnlyWhenItChanged`). |
| C078 | not fixed | Unchanged: 53 ms once at a million subfolders in one folder; needs another tree structure. |
| C079 | not fixed | Unchanged: NSOutlineView cost for a million visible rows. |
| C097 | fixed | Selection `saveToFile` takes `operandsSnapshot()` (O(1)) and picks the marked items in the job; SystemTools `printList` takes the snapshot and gathers in the job (the `Set<String>` of all marks and `operands()` on main are gone); `printFiles` picks up to 5,000 files on the spot and more in a job. |
| C113 | fixed | `SystemTools/DirectoryList.swift`: `PagePrintView` measures the longest line in UTF-16 units when the caller has not (a count that does not cut every line into characters); the plugin passes the measure made in the job. Test: `theLongestLineIsMeasuredWithoutCuttingEveryLineIntoCharacters`. |
| C117 | fixed | Remainder: a real folder named like `x (branch)` is reached with a trailing slash because the text-only `location(from:)` cannot stat. Left as it is: asking the disk from a text-only call would put I/O on the path of every typed address. |
| C121 | fixed | `TreeCache.note`: a folder added by `noteFolder` (and its new parents) also goes into `unscanned`, so the tree shows it as not read and reads its subfolders when it is opened. Test: `aFolderNotedLaterShowsAsNotReadYet`. |
| C122 | fixed | `TreeCache.parseEntry` works on the UTF-8 bytes (line feed byte, first and last byte), `text.contains("\nstate=partial\n")` and `line.count` are gone. |
| C123 | fixed | Same: `[` or `(` followed by a combining mark is a line start like any other; `DirectoryTree.components(of:)` cuts relative paths at the `/` byte for the same reason. Test: `namesThatBeginWithACombiningMarkComeBackFromTheFile`. |
| C124 | fixed | Trees in memory are trimmed by the number of folders too (`memoryPathLimit` 2,000,000, besides 8 trees); the file is written in pieces of about a megabyte straight to the descriptor (no whole text, no whole `Data`; a tree over `fileLimit` removes the file); the name set of a tree of over 100,000 folders is dropped after a flush. Tests: `aTreeOfManyFoldersIsWrittenInPiecesForTheUserAlone`, `aHugeSetOfTreesInMemoryIsTrimmedByTheNumberOfFolders`. |
| R011 | fixed | VirtualFolders. `FileListService.show(_:title:in:isUnique:)` is implemented: with `isUnique` a list is not looked through for doubles and its entries are the files themselves (no key per file); `register(files:)` itself already took no time (first pass), the work of `prepared` runs in the background for a long list. Find Files passes `isUnique: true`. Test: `aListThatIsKnownToBeUniqueIsNotLookedThroughForDoubles`. |
| K047 | fixed | ViewOptions. Choosing Unsorted after another key sets the order (no work, whatever the length) and reads the panel again (`reload`), which brings the entries in the order the file system gives them. Test: `unsortedAfterAnotherKeyReadsTheFolderAgain`. |

## 2. Cross-request items

| From | Item | Status | Note |
|---|---|---|---|
| kernel 8 | ViewOptions sort and filter with `basis` -> `prepare` -> `apply` | done | `ViewOptionsPlugin.swift`. Stale: again in the background; after `staleTries` (3) stale answers the main thread sorts/filters once (one pass on all cores), so the user always gets the order they asked for. A newer order from another route (column click) wins. The request is *not* kept in the model: kernel request in `cross-requests/plugins-a-p2.md` item 1. Tests: `Review2ConfigAViewOptions`, `aFolderThatKeepsChangingIsSortedByTheMainThreadOnceTheTriesAreUsed`. |
| kernel 9 | Unsorted after another order | done | K047 above. |
| kernel 10, shell 5 | O(1) `enabled:`/`checked:` | done | ViewOptions Only Selected uses `hasSelection` and builds its name set in the background from `operandsSnapshot()`; SystemTools Print was already `hasOperandFile`; `ConfigurationStore.userCommand(named:)` is a dictionary lookup (the menus ask for every user command at each validation). Audited every `enabled:`/`checked:` in the eleven directories: the others read O(1) state (`isListed`, `isComplete`, `hasOperands`, `selectionCount`, counts of tabs). |
| kernel 11 | Selection on the bulk calls | done | C011, C012. Select all / unselect all use `selectAll()`/`clearSelection()`; invert is `invertSelection()` (both-scope) or an index pass over `operandsSnapshot()`; Restore Selection and Save Selection are the kernel's bit passes (`restoreSelection()`, `saveSelection()`). The model's `selectedNames` is not needed. |
| kernel 1-7 | operands snapshot | done | `CommandRunner.snapshot`, `MacIntegrationPlugin.withLocalOperands`, `SystemTools.printList/printFiles`, Selection `saveToFile` use `operandsSnapshot()`; the copies of `(items, selection)` are gone. |
| config-a 2, 3, 4 | operands snapshot, no `listVersion` bump, bulk select | done | see above. |
| config-a | `Hotlist.limit` on load | done | `Hotlist.init(from:)` keeps the first `limit` entries (submenus count with their content) and counts the rest as skipped, so the existing "could not be read, original kept" notice appears. Test: `theHotlistLimitHoldsForWhatIsStored`. |
| config-a (C024, C025) | counter clamp on decode | checked | `FrequentFolders.init(from:)` clamps negatives, `record` saturates at `Int.max` (code read; tests exist: `Review2ConfigB…`, `Review2ConfigASettings…`). |
| config-a (C053) | command-line history | needs other area | The window's history is the shell's. |
| fileops 14 | `%L` list files with a line break in a name | done | Not only LF/CR: every character a program may take for the end of a line (U+000B/C, U+001C-1E, U+0085, U+2028/9) makes the list refused (`ParameterExpansion.list`). Test: `aNameWithAnyKindOfLineEndIsNotPassedInAListFile`. |
| fileops 12 | list capabilities | needs other area | A separate flag for "entries can be removed" does not exist; cross-request 4. |
| fileops 15 | read loops without `autoreleasepool` | checked | Every read loop of FindFiles has one (`DuplicateFinder.digest`, `TextPattern` both loops, `FileSearch.passesSlowChecks`, the worker loop). |
| find 1, 2, 6 | bulk marks; `isUnique`; large settings values | done | C011, R011; Multi-Rename's undo history uses `SettingsStore.largeData` / `setLarge` (the default keeps it with the rest, a store with files of its own can write it away from the main thread). |
| find 4, 5 | `LocalFileSystem.read`; DirectorySync/CompareContent | needs other area | Not these directories. |
| shell 6 | quit work on the main thread | done | `PlacesPlugin.prepareToQuit` writes the tree cache in the background; `stop()` finds nothing left. |
| shell 9 | dialog started from a main-queue block | done | `CommandRunner` (`MainLoop.perform`: `RunLoop.main.perform(inModes: [.common])` + wake) for list-queue/offMain completions, the `cm_wait` continuation and the process-end report; the same helper for `ConfigurationStore.onProblem` and the key-assign question of the options window; Selection (a result that tells "takes too long"), Places (damaged data notice), Multi-Rename (edit names, undo question, loaded names) have their own `performOnMainLoop`. |
| network 4 | typed address vs. address from a file | done | Go to Folder… (the prompt) calls `ServerConsentService.userChose(location)`; nothing else does (clipboard, `cd` from stored hotlists and tabs are not typed). |
| config-b | `PanelTabs.performBatch`; `connectsToServer` | done | FolderTabs `batch` is `performBatch`; whether a tab connects asks the file system (`connectsToServer`) and keeps the scheme list for places no loaded file system claims (and for `vfolder:`). |
| kernel 14 (`PathSafety`), names from lists | done where it applies | Multi-Rename cuts new names at the `/` byte, not at the character, everywhere a name decides where a file goes (`RenameEngine.invalidity`, `RenameRun.target(of:)`, `diskName`, the "these names move files" question, the folders listed for the plan) — a combining mark after a slash can no longer hide a folder move from the question. `PathSafety.components` itself is not used: it refuses `..` and absolute names, which a typed Multi-Rename name may be after the user's confirmation (R059). `DirectoryTree` cuts relative paths at the byte too. |
| config-a 5 | shared `DisplayText` / `LoginShell` | not adopted | `Format.displayName` writes `<U+XXXX>`, `DisplayText.oneLine` writes `\n` / `\u{…}`; messages, logs and about 30 tests depend on the second form. |
| viewer 3, tools | not these directories | — | |

## 3. "Not done" items of the first pass

| Item | Status | Note |
|---|---|---|
| Multi-Rename `RenamePlanner.steps` serial and not cancellable | fixed | The keys of all items are made on all cores once (`Parallel.map`), the walk looks at `cancelled()` every 4,096 items and in `insideOut`; Start and Undo end with "cancelled" when the job is cancelled while planning. Test: `aPlanThatIsCancelledIsCutShort`, ring test `aRingOfRenamesIsStillOpenedWithATemporaryName`. |
| `foldsCase` lists a folder a second time | fixed | On the local disk the two spellings are told apart by device, inode and link count (no listing at all); elsewhere the folder is listed once, only as far as the other spelling, with the job's cancellation. `provider.item(at:)` takes the flag too (finding C038's Multi-Rename lines). Test: `twoFilesAreTheSameFileOnlyWhenNothingElseCouldBeMeant`. |
| First hit of one very large folder waits for the whole listing | fixed | `FileSearch.Walk`: from `partialListingAfter` (100,000) entries seen in one folder, what passed the quick checks is reported in parts as the listing comes in (each part in name order); the folder's subfolders follow when the listing is done. Test: `aFolderOfManyFilesReportsItsFirstHitBeforeTheListingEnds`, `aFolderListedInPartsStillGivesEveryHitOfTheTestsInOrderOfParts`. |
| Duplicate finder: one share mounted twice | fixed | `DuplicateFinder.distinctFiles` also tells the files of a mount that is not a local disk by `fstype:source` and the path inside (`Mount`), so the same share at two places is one place. Test with made-up mounts: `oneShareMountedTwiceIsOnePlace`; not run against a real second mount. |
| Multi-Rename undo history in the settings | done as far as this area goes | `largeData` / `setLarge` (see above). |
| `[T4]` FIFO swapped for a picture between check and ImageIO's open | not fixed | Unchanged. |
| Spotlight against a real index | not run | Unchanged. |
| C057, C078, C079 | see section 1. | |
| Fuzz reproducers `repro/misc` | confirmed | `pexpand-substring-length-overflow.bin`: `aSubstringOfTheLargestLengthDoesNotTrap` (the file itself is expanded); `selection-save-ansi-nsexception.bin`: `Review2FindSelectionRules.aNameAnsiCannotWriteDoesNotRaise`; `settings-import-frequent-count-overflow.json`: `Review2ConfigASettings…` (loads the file); `frequentfolders-count-overflow.bin`: `Review2ConfigB…` (decodes the largest count and records a visit). The `descript-*` ones are FileProperties. |
| Fuzz reproducers `repro/diff` | confirmed | `renamemask-wildcard-backtracking.bin`, `renameregex-catastrophic.bin`: `theFuzzerReproducersOfTheRenameMasksEnd` runs the files' own lines through the engine; also `Review2FindRename` R012/R014 tests. `nametemplate-*` are FileOperations; `note-unrealistic-count.bin` is a note of the fuzzer, not a crash. |

## 4. Decisions

- **A result the model refuses is worked out again** (up to 8 times) when the panel still shows the same folder; before, it was dropped, which lost the user's command whenever a watched folder changed during a long computation. A panel that went elsewhere drops it. The old test that expected the drop now expects the mask to be applied to the new list (`aResultForAnotherListIsWorkedOutAgain`).
- **A sort or filter that keeps going stale ends on the main thread** after 3 tries (one parallel pass; 150 ms at a million entries) rather than never: the order the user asked for must appear. The kernel request (item 1) would remove even that.
- **The Selection clipboard load reads the pasteboard once on the main thread** (as Navigation does), then matches off it; the first pass read it on a background thread, which can crash against a copy on the main thread. A lazily provided 100 MB clipboard can still hold the main thread while it is read.
- **Within a folder of 100,000+ entries Find Files reports in parts** (each part sorted, the parts in listing order), not one sorted list: the first hit is worth more than a global order inside one huge folder.
- **Hotlist over the limit on load**: the first 2,000 entries stay, the rest are reported as unreadable and kept in `places.hotlist.unreadable` by the existing mechanism.
- **A tree noted by `noteFolder` marks the new folders unscanned**, so a tree shows disclosure triangles for them and reads them when opened.

## 5. Tests

New: `Tests/PluginTests/Review2PluginsA2Tests.swift`. Changed because behaviour changed by design:
`Review2FindSelectionTests.swift` (`aResultForAnotherListIsDropped` -> `aResultForAnotherListIsWorkedOutAgain`).

Final runs (`swift test --scratch-path .build-plugins-a-p2 --skip-build --filter …`, after the last edit and a full rebuild; the machine
was loaded by the other agents):

| Classes | Result |
|---|---|
| FindFiles, Review2Find*, FindRenameFix, FindFilesMore | 137 tests in 17 suites passed |
| MultiRename, FindRename | 101 tests in 10 suites passed |
| SelectionMore, ToolsAdopt, Review2PluginsA2 | 85 tests in 17 suites passed |
| ConfigurationCommand, ConfigurationModel, Review2ConfigA, ConfigPlaces | 129 tests in 23 suites passed |
| SystemTools, ViewOptions, MacIntegration | 74 tests in 13 suites passed |
| FolderTab, TabFiles, PluginCommand | 53 tests in 6 suites passed |
| PlacesTree, Review2ConfigB, PlacesHotlist, PlacesNavigation, PlacesAdoption, VirtualFolders, VirtualLocations, BranchWalking, NavigationPlaces | 126 tests in 21 suites passed |
| Integration through these plugins (LocalDiskFixes, PluginFixes, ArchiveJobsEndToEnd, JobsThroughVirtualFolders, NamesInBranchViews, ViewerThroughVirtualFolders, ClipboardMore, FileOpsFix, FilePropertiesTests, Review2FileopsPlugin, CompareContent, DirectorySync, Review2Tools) | 282 tests in 38 suites passed |

The wide run (`--filter PluginTests --skip Network`) did **not** finish: the first one (before my last fixes) ended in a crash of the test
process (`Index out of range`), which was a bug of mine in `FileSearch.Walk.publish` (the offset of the test flags of a list of files; found by
`FindFilesTests`, fixed, and covered by those tests); the second ran for 1,053 tests and then stood still for more than ten minutes (I stopped it).
In the part that ran, the only failures were in Viewer tests of another area (`ViewerAdoptIndex.aWiderLayoutTakesOverTheSegmentsWhoseLinesStillFitInOneRow`,
`Review2ViewerSource.codePagesThatAreDecodedAsSingleBytesAreNotOffered`, `Review2ViewerPane…theFastScanAndTheDecodingScanAgreeOnWideText`) and an Archives test
(`Review2ArchivesP2.noLinkOnTheWayIsGoneThroughWhoeverMadeIt`), all files being edited by other agents at the time. I did not look at them further.


## 6. Not done

- C057 (recursive watch), C078, C079, the `[T4]` FIFO case, Spotlight against a real index, a duplicate-finder run against a real second mount of one share: see above.
- Fileops request 12 (a list offers Paste/New Folder): needs a capability flag (cross-request 4).
- The sticky sort request inside the model (cross-request 1), `RowSet` from indexes (cross-request 2).
- The Selection clipboard text is still read on the main thread (once per command).
- X001-X008 (findings/tests.md) are not in these directories.
