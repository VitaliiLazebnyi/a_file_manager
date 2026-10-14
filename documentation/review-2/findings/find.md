# Review 2 — find

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent rulings on a finding and sit next to it by file. Status is filled in by the fix round.


## Findings and verdicts

### R001 [finding, critical] B4b: Compare Directories (Shift+F2) calls resourceValues(.volumeSupportsCaseSensitiveNamesKey) on main for both panels.
**Outcome:** fixed — see `status/find.md`


- **Where:** Plugins/Selection/SelectionPlugin.swift:493-496
- **Basis:** read (call confirmed, blocking plausible)
- **Detail:** Confirmed call; blocking plausible (critical on a stalled mount).
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### R002 [finding, high] Cmd+C in Find Files results builds the whole text on main (about 1 s at 2M).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FindFilesWindowController.swift:504-524
- **Basis:** measured
- **Detail:** handleResultKey -> copyText calls displayPath per row and joins. 536 ms measured for url.path plus join at 2M; with the provider lookup and setString of about 150 MB, roughly 1 s. Reported severity high/medium, scaling.
- **Proposed fix:** Build the text in the background, or use lazy pasteboard data.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R003 [finding, high] H2: Spotlight results are collected on the main thread, one attribute fetch per result.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/SpotlightSearch.swift:124-128; FindFiles/SpotlightSearch.swift:60
- **Basis:** inferred (plausible)
- **Detail:** With no criteria the query is kMDItemFSName == "*" which returns every indexed file in scope. At a million results the per-item value(forAttribute:) loop is likely several seconds of main-thread stall, plus all paths held in memory. Cost not measured.
- **Proposed fix:** Give the NSMetadataQuery a background operationQueue, read the paths there, and cap the count.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R004 [finding, high] Spotlight results are extracted on main; a 2M-file query can take 10-40 s.
**Outcome:** duplicate of R003 — see `status/find.md`


- **Where:** FindFiles/SpotlightSearch.swift:124-131
- **Basis:** inferred (plausible)
- **Detail:** SpotlightSearch.finished loops result(at:) and value(forAttribute:) over every result. Trigger: a query matching 2M files (an empty mask asks for kMDItemFSName == "*"). Roughly 5-20 us per result gives 10-40 s; gathering itself also runs on the main run loop. Scaling, reported as plausible.
- **Proposed fix:** Give the NSMetadataQuery an operationQueue, extract paths there, and cap or page the results.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R005 [finding, high] Multi-Rename job completions do per-item URL work on main (about 0.7 s on finish, 1.5-2 s on undo at 500k).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameSession.swift:413-434; MultiRename/MultiRenameSession.swift:466-483
- **Basis:** measured
- **Detail:** finish (:413-434): Set of 500k locationKey (measured 273 ms) plus removeAll by locationKey (317 ms), then appendUndo, panels.refresh and listChanged. About 0.7 s in total. Undo completion (:466-483): two such sets, two filters, and Set(last.flatMap { deletingLastPathComponent x2 }) (measured 816 ms). About 1.5-2 s in total.
- **Proposed fix:** Compute gone, folders, attempted and left in the job's work closure and hand over finished values.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R006 [finding, high] Multi-Rename reads the clipboard (and builds environment and titleRule) on every keystroke on main.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameWindowController.swift:285; MultiRename/MultiRenameSession.swift:77; MultiRename/MultiRenamePlugin.swift:55
- **Basis:** read (reported as confirmed)
- **Detail:** controlTextDidChange (MultiRenameWindowController.swift:285) -> session.settings didSet -> refresh() -> makeContext (MultiRenameSession.swift:77) -> NSPasteboard.general.string(forType:) (MultiRenamePlugin.swift:55). Blocking call plus scaling. Trigger: 100 MB of text on the clipboard costs tens to hundreds of ms per key; lazily provided data from a hung application blocks without limit. The same call also builds ProcessInfo.environment and store.titleRule each time.
- **Proposed fix:** Read the clipboard once at open, or only when the mask contains the clipboard placeholder, off main and capped in size.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R007 [finding, high] P5: Spotlight results extracted on main, estimated 10-40 s for 2M results.
**Outcome:** duplicate of R003 — see `status/find.md`


- **Where:** Plugins/FindFiles/SpotlightSearch.swift:124-131
- **Basis:** inferred
- **Detail:** Scaling, plausible.
- **Proposed fix:** Give the query an operation queue and page the results.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### R008 [finding, high] P3: Multi-Rename completions take 0.7 s after a rename and 1.5-2 s after an undo on main (per-item URL sets).
**Outcome:** duplicate of R005 — see `status/find.md`


- **Where:** Plugins/MultiRename/MultiRenameSession.swift:413-434; Plugins/MultiRename/MultiRenameSession.swift:466-483
- **Basis:** measured
- **Detail:** Scaling, measured (fork-reported, not re-read).
- **Proposed fix:** Compute them in the job.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### R009 [finding, high] P2: Multi-Rename reads the clipboard on every keystroke and does O(rows) work with no debounce (50-150 ms at 500k rows).
**Outcome:** duplicate of R006 — see `status/find.md`


- **Where:** Plugins/MultiRename/MultiRenameSession.swift:77; Plugins/MultiRename/MultiRenamePlugin.swift:55
- **Basis:** read (confirmed)
- **Detail:** Slow with 100 MB of text; unbounded if another app provides the data lazily.
- **Proposed fix:** Read the clipboard only when the mask uses it, off main; debounce.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### R010 [finding, high] P4: Compare Directories at 1M x 1M runs 1.7-1.9 s on main; select by *.txt 1.1 s; Load Selection from Clipboard about 1.7 s for 100 MB.
**Outcome:** fixed — see `status/find.md`


- **Where:** Plugins/Selection/SelectionPlugin.swift:484-514; Plugins/Selection/SelectionPlugin.swift:258; Plugins/Selection/SelectionPlugin.swift:469-478
- **Basis:** measured
- **Detail:** Scaling, measured (fork-reported, not re-read).
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### R011 [finding, high] VirtualFileSystem.register(files:) / unique() does O(list) work on main (est. 2-4 s for 2M results).
**Outcome:** fixed — see `status/plugins-a-p2.md`


- **Where:** Plugins/VirtualFolders/VirtualFileSystem.swift:134-138; Plugins/VirtualFolders/VirtualFileSystem.swift:122-123; Plugins/VirtualFolders/VirtualFoldersPlugin.swift:91-95; Plugins/VirtualFolders/VirtualFoldersPlugin.swift:117-121
- **Basis:** read (confirmed; durations estimated from measured 0.64 us per locationKey)
- **Detail:** unique() builds a locationKey, a [UInt8] and a Set insert per URL, then filters by scheme at :122-123. Entry points: VirtualFoldersPlugin.show (:91-95), called by Find Files 'feed to listbox' and by the loadList completion; and enter(selectedOnly:) (:117-121). Estimate: 2-4 s for 2M results; about 0.4 s plus operands() for 300k marked. Durations estimated from the measured 0.64 us per locationKey.
- **Proposed fix:** Dedupe when the list is produced, off main.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### R012 [finding, high] H1: user regexes run with no time limit and no cancellation inside a match (catastrophic backtracking hangs Selection on main, MultiRename preview/Start, FindFiles workers).
**Outcome:** fixed — see `status/find.md`


- **Where:** Selection/SelectionMask.swift:103; Selection/SelectionPlugin.swift:258; MultiRename/RenameRules.swift:163; MultiRename/RenameRules.swift:166; MultiRename/RenameRun.swift:147; MultiRename/MultiRenameSession.swift:100; MultiRename/MultiRenameSession.swift:357; FindFiles/SearchCriteria.swift:71; FindFiles/TextPattern.swift:344; FindFiles/SearchCriteria.swift:231; MultiRename/RenameRules.swift:195-204
- **Basis:** measured
- **Detail:** Measured: ^(\w+[ _-]?)+\.jpg$ against aaaa....png takes 0.18 s at 22 chars, 0.73 s at 24, 2.8 s at 26 (x4 per 2 chars; a 40-char name is hours). Selection: a <regex mask of that shape on the main thread hangs the whole app for good. MultiRename preview: cancellation only checked between items so shared ParallelPool threads spin and the serial preview queue never runs another preview or sort. MultiRename Start computes the same preview inside the job; the job cannot be cancelled and jobs run one after another, so every later copy/move/delete in the app is blocked until restart. FindFiles: name regex, content regex on chunks of up to about 5 MB, field-rule regex; after Cancel or closing the window the worker threads keep spinning, each such search leaves up to max(4, cores) threads burning CPU. The plain-wildcard Search & Replace has the same shape: *a*b*c*d*e* becomes chained .*? (polynomial per name).
- **Proposed fix:** Run every user regex through enumerateMatches(options: .reportProgress) and set stop when the cancellation flag is set or a per-item deadline passes. Move Selection matching off the main thread.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R013 [verdict, high] Long Find text overflows the stack
**Outcome:** fixed — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/TextPattern.swift:121-132; Sources/Plugins/FindFiles/FileSearch.swift:461
- **Basis:** CONFIRMED (ran), lower threshold than reported
- **Detail:** Recurses once per matched character; search workers are plain Threads with default 512 KB stack. TextPattern.swift compiled alone -O: 5,000 characters found, 6,000 and above crash with bus error; debug build crashes already at 2,000 (lower threshold than reported). Conditions: case-insensitive (default) or whole-words, and a file containing the text or a long prefix. Case-sensitive goes through memmem, fine at 20,000.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R014 [finding, high] Hang in Multi-Rename wildcard/regex backtracking
**Outcome:** fixed — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/RenameRules.swift:163-166
- **Basis:** reproduced
- **Detail:** A plain wildcard search with many * against a 250-letter name becomes a backtracking regex and ran over 60 s; user regex (a*)*b does the same. Preview cannot cancel it. Reproducers repro/diff/renamemask-wildcard-backtracking.bin (target renamemask, --timeout 60) and renameregex-catastrophic.bin (target renameregex).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### R015 [finding, high] Multi-Rename plain wildcard search like *a*a*...*b against a 250-letter name backtracks without end (over 60 s), and the preview cannot cancel it.
**Outcome:** duplicate of R014 — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/RenameRules.swift:166; RenameRules.swift:163
- **Basis:** reproduced
- **Detail:** matches(in:) and firstMatch; pattern from wildcardPattern. The plain non-regex search `*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b` against a 250-letter name of a's becomes ^.*?a.*?a...b and backtracks without end; ran over 60 s for one name and was stopped. isCancelled is only asked between names. Reproducer: repro/diff/renamemask-wildcard-backtracking.bin (--timeout 60). The same happens with the user regex (a*)*b on 32 a's: repro/diff/renameregex-catastrophic.bin, target renameregex.
- **Proposed fix:** Match wildcards with a linear matcher instead of a regex, and run user regexes through enumerateMatches with a deadline or the cancel flag, showing <Error!> on timeout.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### R016 [finding, high] Saving a selection to file in ANSI raises an uncaught NSInternalInconsistencyException for names like U+3000 U+0300.
**Outcome:** fixed — see `status/find.md`


- **Where:** Sources/Plugins/Selection/SelectionFile.swift:19
- **Basis:** reproduced
- **Detail:** C4. text.data(using: .windowsCP1252, allowLossyConversion: true): Foundation raises "didn't convert all characters" for a marked name such as U+3000 U+0300; the process aborts. Reach: Save Selection To File (ANSI) with such a name marked. Reproducer selection-save-ansi-nsexception.bin, target selection.
- **Proposed fix:** Convert per character with a ? fallback instead of the lossy NSString call.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### R017 [finding, high] Abort saving a selection as ANSI (uncaught NSException)
**Outcome:** duplicate of R016 — see `status/find.md`


- **Where:** Sources/Plugins/Selection/SelectionFile.swift:19
- **Basis:** reproduced
- **Detail:** Foundation raises an uncaught exception for a name such as U+3000 U+0300. Reproducer repro/misc/selection-save-ansi-nsexception.bin (target selection).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### R018 [finding, medium] M6: duplicate finder can list one remote file twice (no identity check for non-file URLs), so deleting 'the duplicate' deletes the only copy.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/DuplicateFinder.swift:94-98; FindFiles/FileSearch.swift:257
- **Basis:** inferred (plausible)
- **Detail:** Non-file URLs are kept without any identity check; FileSearch de-duplicates them by absoluteString only. Trigger: two start directories that are the same remote place by another spelling or route (sftp://host/a;sftp://HOST/a, or a server-side folder symlink given as a root). Every file appears in a group with itself. Same for one share mounted twice locally (different st_dev).
- **Proposed fix:** Refuse or mark groups on file systems that offer no file identity; at least normalise host and path, and never put two entries with an equal locationKey/provider identity in one group.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R019 [finding, medium] M5: 'Search in found files' is quadratic and ignores Cancel (reached tests every item against every folder with isInside).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:233-238
- **Basis:** read (confirmed by reading)
- **Detail:** Runs before the cheap name check and with no cancellation check. 200k results including 20k folders is about 4x10^9 string comparisons, likely tens of minutes. The window stays on '[Searching...]', Start stays disabled, Cancel has no effect until it finishes.
- **Proposed fix:** Put folder keys in a set and walk each item's ancestors; test the name first; poll the flag.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R020 [finding, medium] M7: content search and duplicate hashing read iCloud 'dataless' files (download everything, can fill the disk).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:292-293; FindFiles/DuplicateFinder.swift:113-114
- **Basis:** inferred (plausible)
- **Detail:** Via FileHandle(forReadingFrom:). A text search over a home folder with optimised iCloud storage downloads everything.
- **Proposed fix:** Skip SF_DATALESS (from st_flags) unless the user asks.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R021 [finding, medium] M4: no bound on memory anywhere in the search (workers never wait for delivery; results uncapped; runForDuplicates collects every file).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:398-426; FindFiles/FindFilesWindowController.swift:352-357; FindFiles/FileSearch.swift:268-269
- **Basis:** read (confirmed by reading)
- **Detail:** One slow front job (a huge file, a stalled mount) lets the other threads list the rest of the tree and buffer every candidate; with an empty mask and a text search that is every file's FileItem. A 5M-hit search likely holds a few GB (estimate, not measured).
- **Proposed fix:** A budget of undelivered candidates that pauses list jobs, and a result cap with a 'more than N' notice.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R022 [finding, medium] M2: data race on Node.candidates when a search is cancelled (unlocked read in checks(for:) vs write in deliver).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:433; FindFiles/FileSearch.swift:440; FindFiles/FileSearch.swift:369
- **Basis:** read (confirmed by reading)
- **Detail:** Normally deliver only touches a node once pending == 0; on cancel it skips the wait and clears every remaining sibling along the current path while workers finish in-flight list()/checks(for:). A read racing a release of the array buffer can crash on Cancel.
- **Proposed fix:** Take the candidates snapshot inside the lock in checks(for:), or pass wanted in from list.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R023 [finding, medium] M3: each cancelled search can leak its whole walk via JobStack.push after close() (Walk -> JobStack -> closures -> Walk cycle).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:468-474
- **Basis:** read (confirmed by reading)
- **Detail:** JobStack.push does not check isClosed. A worker finishing list() after close() pushes closures that capture the Walk, pinning the FileSearch, its query (including onlyItems, possibly millions of URLs) and the nodes.
- **Proposed fix:** guard !isClosed in push.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R024 [finding, medium] O(panel items) passes with a set lookup per item when 300k are marked in Find Files selectedItems, SyncSession.adopt and CompareOperands.choose (100-200 ms at 1M).
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** FindFiles/FindFilesWindowController.swift:143-146; FindFiles/FindFilesWindowController.swift:560; DirectorySync/SyncSession.swift:102; CompareContent/CompareContentPlugin.swift:86-98
- **Basis:** read (reported as confirmed)
- **Detail:** Find Files selectedItems (:143-146) runs on every windowDidBecomeKey (:560), on prepare and on startSearch, only to test emptiness. SyncSession.adopt (SyncSession.swift:102) also sorts the 300k names. CompareOperands.choose (CompareContentPlugin.swift:86-98) adds a linear name search in the target panel. Roughly 100-200 ms at 1M.
- **Proposed fix:** Find Files: use selectionCount > 0.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R025 [finding, medium] Find Files end-of-search and result actions do O(results) work on main (about 0.3 s at 2M); one folder with 1M matches arrives as a single batch.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FindFilesWindowController.swift:361-398; FindFiles/FindFilesWindowController.swift:472; FindFiles/FindFilesWindowController.swift:483; FindFiles/FindFilesWindowController.swift:255; FindFiles/FindFilesWindowController.swift:296-298
- **Basis:** measured
- **Detail:** finish (:361-398): resultItems (66 ms), rebuilding rows (167 ms), a directory count (8 ms), then freeing the old array and reloadData. About 0.3 s at 2M. goToFile (:472) rebuilds resultItems on every Enter or double-click (about 66 ms); feedToListbox (:483) is O(n) before handing 2M URLs to the list service; startSearch with 'search in found' (:255) likewise. A single folder with 1M matches arrives as one batch, because flush only runs from onDirectory (:296-298).
- **Proposed fix:** Keep counts incrementally, keep the rows at the end instead of rebuilding them, read the single item directly, and cap the batch size.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R026 [finding, medium] M12: a regex-stuck or FIFO-stuck preview also blocks sorts (sorts and previews share one serial queue).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameSession.swift:100; MultiRename/MultiRenameSession.swift:190
- **Basis:** read (confirmed by reading)
- **Detail:** Consequence of H1 and M11.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R027 [finding, medium] M11: [T4] opens every listed file with ImageIO on the preview threads (no isSpecial/non-regular/dataless check); FIFO blocks the serial preview queue; untrusted files parsed in-process.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameSession.swift:509-518; MultiRename/MultiRenameSession.swift:141
- **Basis:** inferred (plausible)
- **Detail:** A FIFO in the list blocks that thread for good, and with it the serial preview queue. Arbitrary untrusted files are parsed in-process by ImageIO decoders. The date cache is thrown away on every list change, so one Shift+Down re-reads all files.
- **Proposed fix:** Regular, non-dataless files only; keep content dates across reorders; consider an image-extension allow-list.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R028 [finding, medium] Multi-Rename per-keystroke O(rows) work on main at 500k rows, with no debounce (50-150 ms per key); other O(rows) actions.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameSession.swift:90; MultiRename/MultiRenameWindowController.swift:307-341; MultiRename/MultiRenameSession.swift:111-119; MultiRename/MultiRenameWindowController.swift:201-207; MultiRename/MultiRenameWindowController.swift:285-291
- **Basis:** measured (partly estimated)
- **Detail:** refresh() maps rows to entries (MultiRenameSession.swift:90; 18 ms measured for a comparable copy). update() (MultiRenameWindowController.swift:307-341) runs counts over all rows and reloadData, once at the keystroke and again when the preview lands, after apply (MultiRenameSession.swift:111-119) has written 500k names. Roughly 50-150 ms per key. The preview itself is correctly in the background and cancellable, but there is no debounce. Shift+Up/Down (:201-207), nextStep, Edit names (:285-291, a 500k-line modal text view) and loadNames(fromText:) (up to 32 MB split on main) are O(rows) too.
- **Proposed fix:** Debounce about 100 ms, keep an entries array alongside the rows, and have the preview return its counts.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R029 [finding, medium] M9: Undo can be pressed again while the first Undo job is queued or running (isRunning only set for Start).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameWindowController.swift:316; MultiRename/MultiRenameWindowController.swift:536-538; MultiRename/MultiRenameSession.swift:441; MultiRename/MultiRenameSession.swift:471
- **Basis:** read (confirmed by reading)
- **Detail:** Both jobs capture the same last run. The second finds nothing to restore and calls replaceLastUndo(with: []), which deletes an older run that was never undone. For a swap (1<->2) the second job finds both names present and swaps again.
- **Proposed fix:** Disable Undo and Start while any of the session's jobs is pending; check that the history's last entry is still the captured one.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R030 [finding, medium] M8: Multi-Rename moves non-local items of branch views and search results into new nested folders (name taken from URL last component only for file URLs).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/RenameRun.swift:17-19; MultiRename/RenameRun.swift:128-135
- **Basis:** read (confirmed by reading)
- **Detail:** An FTP/SFTP/archive item named by path (sub/file.txt, or the full display path) keeps that as its name. Any change then yields a name with /, and target(of:named:) resolves it below the item's own folder: .../sub/sub/file_x.txt; folder created and file moved there. Full display paths such as ftp://... mostly become 'A folder name is empty', so the tool is unusable on those lists.
- **Proposed fix:** Take the name from the URL for all schemes.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R031 [finding, medium] Multi-Rename undo history is JSON-decoded on main at first window open; a 500k-item run is persisted and decoded next session (est. 1-3 s).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/RenameStore.swift:134-138; MultiRename/RenameStore.swift:166-175; MultiRename/RenameStore.swift:185-189
- **Basis:** inferred (plausible)
- **Detail:** update() -> canUndo -> RenameStore.undoHistory (:134-138) JSON-decodes [[RenamedItem]] at the first window open. persistedRuns (:166-175) always keeps the newest run, whatever its size, so a 500k-item run is stored and decoded next session; estimated 1-3 s. The write hop (:185-189) hands a multi-megabyte Data to the settings store on main. Reported severity medium/high, scaling, plausible.
- **Proposed fix:** Decode lazily in the background and store only a count for canUndo.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R032 [finding, medium] M10: undo history of a big run is too large for the settings store (500k-file run about 100 MB of JSON in UserDefaults, decoded on main at tool open).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/RenameStore.swift:166-175; MultiRename/RenameStore.swift:136
- **Basis:** inferred (plausible)
- **Detail:** The latest run is kept whatever its size; loaded with the defaults domain at every launch; decoded on the main thread on first access via update() -> canUndo. 100 MB is the auditor's estimate.
- **Proposed fix:** Keep undo runs in a file of their own, read and written off the main thread, with a hard cap.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R033 [finding, medium] Data race on cancel in FileSearch.Walk: deliver writes node.candidates = [] under the lock while checks(for:) reads it without the lock.
**Outcome:** duplicate of R022 — see `status/find.md`


- **Where:** Plugins/FindFiles/FileSearch.swift:367-370; Plugins/FindFiles/FileSearch.swift:433; Plugins/FindFiles/FileSearch.swift:440; Plugins/FindFiles/FileSearch.swift:425; Plugins/FindFiles/FileSearch.swift:423
- **Basis:** read (confirmed)
- **Detail:** deliver sets node.candidates = [] under condition as soon as the search is cancelled, even while pending > 0. A worker in checks(for:) reads node.candidates.count (:433) and captures node.candidates (:440) without the lock, called from list at :425 after the unlock at :423. An unsynchronised array read against a write can crash.
- **Proposed fix:** Pass wanted into checks instead of re-reading the node, or read under the lock.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### R034 [finding, medium] P8: Find Files at 2M results: finish about 0.3 s, Cmd+C about 1 s; a single folder with 1M hits arrives as one batch.
**Outcome:** duplicate of R025 — see `status/find.md`


- **Where:** Plugins/FindFiles/FindFilesWindowController.swift:361-398; Plugins/FindFiles/FindFilesWindowController.swift:504-524
- **Basis:** measured
- **Detail:** 
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### R035 [finding, medium] M1: everything in the Selection plugin runs on the main thread, O(n) or worse (mask select, same folder, Compare Directories, foldsCase resourceValues).
**Outcome:** fixed — see `status/find.md`


- **Where:** Selection/SelectionPlugin.swift:258; Selection/SelectionPlugin.swift:342-348; Selection/SelectionPlugin.swift:354; Selection/SelectionPlugin.swift:365-373; Selection/SelectionPlugin.swift:477; Selection/SelectionPlugin.swift:486; Selection/SelectionType.swift:132; Selection/SelectionPlugin.swift:370; Selection/SelectionFile.swift:98-164; Selection/SelectionPlugin.swift:493-496
- **Basis:** measured
- **Detail:** Measured core cost at 1M names: Array(name.lowercased()) 0.12 s, regex firstMatch 0.36 s; add filter, MaskEntry building, name.contains('/') and setSelected on top. A path-limited or A>B mask adds pathComponents per item, about 1.1 us each, so over 1 s at 1M. 'Same folder' and Compare Directories (several normalise+lowercase passes per name) are similar. foldsCase calls resourceValues on main; blocks on a stalled network mount.
- **Proposed fix:** Compute name lists on a background queue (with Parallel.map), then apply with a listVersion guard.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R036 [finding, medium] No Find result appears until a whole folder is done (first hit after 5.2-5.7 s name search, 42-53 s text search in a 1M-file folder).
**Outcome:** fixed — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/FileSearch.swift:365
- **Basis:** measured
- **Detail:** In the 1M-file folder the first hit came after 5.2-5.7 s for a name search (13 s for "everything") and 42-53 s for a text search; the window showed only "[Searching...]". Walk.deliver waits for node.pending == 0, meaning the folder is fully listed and every candidate tested.
- **Proposed fix:** Deliver the already-tested prefix of a folder's candidates while the rest are pending, and stream the listing in batches.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R037 [verdict, medium] FindFiles batching: one folder is one unbounded batch and finish re-passes the model
**Outcome:** duplicate of R025 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/FileSearch.swift:365-375; Sources/Plugins/FindFiles/FindFilesWindowController.swift:287-300; Sources/Plugins/FindFiles/FindFilesWindowController.swift:361-374
- **Basis:** CONFIRMED (ran)
- **Detail:** deliver waits for node.pending == 0 so a folder's hits arrive only when the whole folder is tested; flush only at folder boundaries. On main at 1M (model passes only): append 187 ms; three passes in finish 349 ms. At 100k 10 ms and 15 ms.
- **Proposed fix:** Flush by time and size inside onMatch; in finish keep the rows and update only the summary row.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### R038 [verdict, medium] FileSearch.Walk data race on cancel
**Outcome:** duplicate of R022 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/FileSearch.swift:367; Sources/Plugins/FindFiles/FileSearch.swift:369; Sources/Plugins/FindFiles/FileSearch.swift:375; Sources/Plugins/FindFiles/FileSearch.swift:423; Sources/Plugins/FindFiles/FileSearch.swift:433; Sources/Plugins/FindFiles/FileSearch.swift:440
- **Basis:** CONFIRMED (read), narrow window
- **Detail:** On cancel deliver leaves its wait with pending > 0 and writes node.candidates = [] under the lock; a worker that just left the lock at 423 reads node.candidates unlocked (two reads of .count at 433, array copy at 440). Only with a text pattern or field rules (needed true); without cancellation the wait at 367 prevents it; after cancel deliver sweeps sibling nodes at 375, widening the set. User sees possible crash cancelling a content search: use-after-free on the array buffer, or trap at 433 if count goes N to 0 between two reads (range lower bound above upper).
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### R039 [finding, medium] Find window stalls the main thread 448-589 ms with about 1M hits (append and finish handle whole batches).
**Outcome:** duplicate of R025 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/FindFilesWindowController.swift:352; FindFilesWindowController.swift:361; FindFilesWindowController.swift:280
- **Basis:** measured
- **Detail:** append(_:) took 498-589 ms: all hits of one folder arrive as a single batch because walk (:280) only flushes in onDirectory. finish(items:groups:) took 448-543 ms: rebuilds rows from resultItems, counts directories and frees old rows, all on the main thread.
- **Proposed fix:** Flush by count as well as time (a few thousand per main-queue block), and in finish keep the rows already shown, with the directory count carried along from the search thread.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R040 [finding, medium] Find window with about a million hits stalls 448-589 ms and no hit appears until a folder is fully done.
**Outcome:** duplicate of R025 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/FindFilesWindowController.swift:352; FindFilesWindowController.swift:361; Sources/Plugins/FindFiles/FileSearch.swift:365
- **Basis:** measured
- **Detail:** append(_:) takes a whole folder's hits in one batch; finish rebuilds the rows on the main thread. First hit after 5.2-5.7 s for a name search and 42-53 s for a text search in the 1M directory.
- **Proposed fix:** Flush by count as well as time, and deliver the tested prefix of a folder.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### R041 [verdict, medium] Spotlight results read on main
**Outcome:** duplicate of R003 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/SpotlightSearch.swift:124-128
- **Basis:** CONFIRMED (read)
- **Detail:** Reads every result on main. Not timed.
- **Proposed fix:** Set metadataQuery.operationQueue and read results there.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### R042 [verdict, medium] User regex has no time limit in FindFiles content search
**Outcome:** duplicate of R012 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/TextPattern.swift:344; Sources/Plugins/FindFiles/TextPattern.swift:348
- **Basis:** CONFIRMED (ran) as mechanism
- **Detail:** Flag checked once per 1 MB block. Cancelled at 0.20 s, the call returned at 1.20 s. Threads spinning long after cancel not reproduced.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R043 [verdict, medium] Multi-Rename reads clipboard and maps rows per keystroke
**Outcome:** duplicate of R006 — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/MultiRenameWindowController.swift:285; Sources/Plugins/MultiRename/MultiRenameSession.swift:77; Sources/Plugins/MultiRename/MultiRenamePlugin.swift:55; Sources/Plugins/MultiRename/MultiRenameSession.swift:89; Sources/Plugins/MultiRename/MultiRenameSession.swift:109-116
- **Basis:** CONFIRMED (read)
- **Detail:** controlTextDidChange -> refresh() -> makeContext -> clipboard(). Same keystroke runs rows.map(\.entry) on main and apply on main, both O(rows). Not timed.
- **Proposed fix:** Read the clipboard once when window activates or changeCount changes.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### R044 [verdict, medium] User regex has no time limit in Multi-Rename
**Outcome:** duplicate of R012 — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/RenameRules.swift:163-166; Sources/Plugins/MultiRename/MultiRenameSession.swift:356-358; Sources/AFMShell/Interaction/ProgressJobService.swift:69-108
- **Basis:** CONFIRMED (ran) as mechanism
- **Detail:** Same curve (1.27 s at 25 characters). Jobs run one after another; cancel flag only checked between items. Blocked job queue not reproduced.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R045 [verdict, medium] User regex has no time limit in Selection mask
**Outcome:** duplicate of R012 — see `status/find.md`


- **Where:** Sources/Plugins/Selection/SelectionMask.swift:103; Sources/Plugins/Selection/SelectionPlugin.swift:167
- **Basis:** CONFIRMED (ran) as mechanism; each run stopped at 25 characters, ~1.3 s
- **Detail:** Plugin states it runs on the main thread. Mask <(a+)+$ on a name of 19/21/23/25 characters took 0.02/0.08/0.32/1.31 s (~4x per two characters). Actual frozen window not reproduced.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R046 [finding, low] L4: overlapping roots drop hard links (de-dup by (device, inode) hides a second hard link at a different path).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:254-255
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Proposed fix:** Key by path; use identity only for folders.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R047 [finding, low] L3: same folder reached twice through a firmlink (/Users and /System/Volumes/Data/Users): hits reported twice with a depth limit; without a depth limit which path is reported depends on thread timing.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/FileSearch.swift:392-395; FindFiles/FileSearch.swift:250
- **Basis:** inferred (plausible)
- **Detail:** Same device and inode (checked). De-duplication only runs for overlapping roots.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R048 [finding, low] L5: end-of-search work on the main thread is O(n) several times (resultItems, rows rebuild, directory count; goToFile rebuilds item list on every Enter; Cmd+C builds one string; selectedItems walks the whole panel on every windowDidBecomeKey).
**Outcome:** duplicate of R025 — see `status/find.md`


- **Where:** FindFiles/FindFilesWindowController.swift:361-380; FindFiles/FindFilesWindowController.swift:472; FindFiles/FindFilesWindowController.swift:519; FindFiles/FindFilesWindowController.swift:143-146
- **Basis:** inferred (plausible)
- **Detail:** Likely around a second at 5M rows.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R049 [finding, low] L17c: an invalid regex in a Plugins-tab rule is not reported: regex never matches and !regex always matches.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/SearchCriteria.swift:231-232
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R050 [finding, low] L2: traps on numeric input: Int64(size) for 1e30 or inf in SearchForm (saved search then crashes on every load); -7 * count for huge weeks; cursor + count - 1 and abs(Int.min) in Selection.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/SearchForm.swift:364; FindFiles/SearchCriteria.swift:38; Selection/SelectionPlugin.swift:381; Selection/SelectionPlugin.swift:347
- **Basis:** read (confirmed by reading, Swift trapping semantics)
- **Detail:** integerValue saturates to Int.max (checked). Selection traps are for extreme command parameters.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R051 [finding, low] L6: Spotlight path returns different results from a walk (index-handled text not re-checked: case sensitive/encoding/exact substring not enforced; root filter is a case-sensitive hasPrefix on unresolved paths; final sort not cancellable).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/SpotlightSearch.swift:17-19; FindFiles/SpotlightSearch.swift:80; FindFiles/SpotlightSearch.swift:84; FindFiles/SpotlightSearch.swift:92
- **Basis:** inferred (plausible)
- **Detail:** A 'Search in' typed in another case or through a symlink finds nothing.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R052 [finding, low] L1: stack overflow on a very long 'Find text' (recursion once per character on 512 KB threads).
**Outcome:** duplicate of R013 — see `status/find.md`


- **Where:** FindFiles/TextPattern.swift:121-132
- **Basis:** reproduced
- **Detail:** A 20,000-character text that occurs in a file crashed with a bus error in tp/; 12,000 passed.
- **Proposed fix:** Iterate, with an explicit stack only for alternatives.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R053 [finding, low] L17b: UTF-16 big-endian without a byte-order mark is not searched in regex mode (it is in plain-text mode).
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/TextPattern.swift:372-376
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R054 [finding, low] L17a: regex content search: a forced cut of a long 'line' can split a character or a match.
**Outcome:** fixed — see `status/find.md`


- **Where:** FindFiles/TextPattern.swift:378
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R055 [finding, low] L10: reopening Multi-Rename while its window is open loses the session reference (old window's onClose sets session to nil after replacement); 'Last used settings' of the new window not remembered.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenamePlugin.swift:56-68
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R056 [finding, low] L9: two quick header clicks leave the list in the wrong order (second sort captured generation before first applied, so dropped; header shows descending, list ascending).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameSession.swift:188-196
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R057 [finding, low] L12: Multi-Rename main-thread and serial costs per keystroke (refresh() copies all entries and reads the pasteboard; update() runs counts and reloadData twice; planner.conflicts/steps serial and not cancellable; target folders listed without cancellation flag and a second time by foldsCase; any row move discards the whole cache).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameSession.swift:77; MultiRename/MultiRenameSession.swift:90; MultiRename/RenamePlanner.swift:79-94; MultiRename/RenameRun.swift:210; MultiRename/RenameRun.swift:265; MultiRename/MultiRenameSession.swift:141
- **Basis:** measured
- **Detail:** Measured at 500k: locationKey 0.16 s, folded key 0.27 s, sort 2.2 s. This is preview latency, not a UI freeze.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R058 [finding, low] L11: preview is not cancelled when the window closes (session has no deinit; a 500k preview runs to the end); after Undo no refresh() so conflict marks stay stale.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/MultiRenameWindowController.swift:662; MultiRename/MultiRenameSession.swift:479-481
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R059 [finding, low] L14: loaded name lists may contain absolute paths; a name starting with / moves the file anywhere and creates folders (never overwrites; .. rejected).
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/RenameRun.swift:129-133
- **Basis:** read (confirmed by reading)
- **Detail:** Security. Worth a confirmation when names come from a file.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R060 [finding, low] L8: [u] (precompose) never renames anything; Swift == treats NFC and NFD as equal; the test at MultiRenameEngineTests.swift:176 passes for the same reason.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/RenameRun.swift:167; MultiRename/RenamePlanner.swift:71-74; Tests/PluginTests/MultiRenameEngineTests.swift:176
- **Basis:** reproduced (checked: Swift == treats NFC/NFD equal)
- **Detail:** 
- **Proposed fix:** Compare UTF-8 bytes.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R061 [finding, low] L13: planner and runner edge cases: isSameFile returns true when target missing (case-only rename uses replacing rename with small race; non-local URLs always true); target folder outside every source folder treated as case-sensitive (EEXIST at run time); auto-renamed names not re-checked against 255 bytes; folder and children in one list fail in list order with stale URLs; Undo identifies files by path only.
**Outcome:** fixed — see `status/find.md`


- **Where:** MultiRename/RenameRun.swift:309; MultiRename/RenameRun.swift:303; MultiRename/RenameRun.swift:243-249
- **Basis:** inferred (plausible)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R062 [finding, low] L7: regular-file check is stat-then-open; a file swapped for a FIFO in between parks a worker for good; a read on a dead NFS/SMB mount does the same (local reader opens blocking, no interrupt).
**Outcome:** fixed — see `status/find.md`


- **Where:** Plugins/FindFiles/FileIdentity.swift:25-28; FindFiles/FileSearch.swift:293
- **Basis:** inferred (plausible)
- **Detail:** Security.
- **Proposed fix:** open(O_NONBLOCK|O_NOFOLLOW) + fstat on the descriptor, then clear O_NONBLOCK.
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R063 [finding, low] FindFilesWindowController.askSpotlight: the outer global-queue closure captures self strongly and may release it last, after the inner main block has run (AppKit dealloc off main).
**Outcome:** fixed — see `status/find.md`


- **Where:** Plugins/FindFiles/FindFilesWindowController.swift:339-347
- **Basis:** read
- **Detail:** Medium-low.
- **Proposed fix:** Capture weakly in the outer closure and take the strong reference only inside main.async.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### R064 [finding, low] renlog.txt sits in temp.
**Outcome:** fixed — see `status/find.md`


- **Where:** Plugins/MultiRename/MultiRenamePlugin.swift:52
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### R065 [finding, low] L16: ** in path masks is exponential (several **/ in one mask, on main thread).
**Outcome:** fixed — see `status/find.md`


- **Where:** Selection/SelectionMask.swift:59-67
- **Basis:** read (confirmed by reading)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R066 [finding, low] L15: selection files and clipboard parsed on main (file capped at 32 MB, clipboard not capped); overwriting a selection file is remove-then-write (failed write loses the old file); read job ignores its monitor so cannot be cancelled.
**Outcome:** fixed — see `status/find.md`


- **Where:** Selection/SelectionPlugin.swift:463; Selection/SelectionPlugin.swift:469-478; Selection/SelectionPlugin.swift:423-427
- **Basis:** inferred (plausible)
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R067 [finding, low] Find cancel-to-finished reaches about 0.55 s (p95 489 ms) when a search of the 1M folder is cancelled, in the engine itself.
**Outcome:** fixed — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/FileSearch.swift
- **Basis:** measured (cause inferred)
- **Detail:** Inferred: freeing the million-item candidate list.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R068 [verdict, low] Numeric trap in SearchCriteria age cutoff
**Outcome:** duplicate of R050 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/SearchCriteria.swift:38
- **Basis:** CONFIRMED (ran)
- **Detail:** -7 * count; Age(Int.max, .weeks).cutoff trapped. Reaching it needs ~19 digits in 'older than N weeks'.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R069 [verdict, low] Numeric trap in SearchForm size to String(Int64(size))
**Outcome:** duplicate of R050 — see `status/find.md`


- **Where:** Sources/Plugins/FindFiles/SearchForm.swift:364; Sources/Plugins/FindFiles/SearchForm.swift:315; Sources/Plugins/FindFiles/SearchForm.swift:429; Sources/Plugins/FindFiles/SearchCriteria.swift:85-89
- **Basis:** CONFIRMED (read)
- **Detail:** String(Int64(size)) for a whole-number Double at or above 2^63 or infinity; reached when a saved search with size 1e19 or inf is loaded. SizeRule.bytes itself is clamped. Not run.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R070 [verdict, low] Multi-Rename nested folders: branch view item names with slash produce doubled subfolder
**Outcome:** duplicate of R030 — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/RenameRun.swift:17-19; Sources/Plugins/MultiRename/RenameRun.swift:132-139; Sources/Plugins/VirtualFolders/BranchWalker.swift:146-149
- **Basis:** CONFIRMED at preview level (ran)
- **Detail:** RenameRun strips the path from an item name only for file: URLs and treats a slash in the new name as a subfolder; branch view names items by path on every file system. Run: item mem:///root/sub/a.txt named sub/a.txt, replacing a->b gave status ready and target mem:///root/sub/sub/b.txt; local control gave a.txt. Rename itself not run.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### R071 [finding, info] RenameMask.swift:499 (context.count - 1) traps only for count = Int.min, which the app never passes; not a product bug.
**Outcome:** not a defect — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/RenameMask.swift:499
- **Basis:** reproduced
- **Detail:** Came from an unrealistic first version of the driver (count is entries.count); input kept as repro/diff/note-unrealistic-count.bin.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### R072 [verdict, info] Multi-Rename Undo history limit is not a defect
**Outcome:** refuted — see `status/find.md`


- **Where:** Sources/Plugins/MultiRename/RenameStore.swift:132-162; Sources/Plugins/MultiRename/MultiRenameSession.swift:440-444
- **Basis:** REFUTED as a defect
- **Detail:** History is a deliberate 20-run stack, each Undo asks first with list of pairs, spec says MultiRenameUndoHistoryLen 'sets how many operations can be undone'; button disabled while a run is in progress.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open


## Checked and found sound

### R073 [sound, info] Multi-Rename preview, sorts and undo writes are off main.

- **Basis:** read
- **Detail:** Preview and long sorts are in the background and cancellable; large undo writes are encoded off main.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R074 [sound, info] Find Files uses insertRows and an early-exit updateButtons.

- **Basis:** read
- **Detail:** insertRows rather than reloadData per batch; updateButtons exits early.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### R075 [sound, info] Shared state: Walk.visited (visitedLock), JobStack (own NSCondition), run's reported sets/window pending/lastFlush, DuplicateFinder.done, CancellationFlag, FindFiles window state, RenameCache, MultiRenameSession state, RenameStore.Memory/memories, ContentDate.formatter/RenameFormats, Selection plugin state are sufficiently protected (exceptions: Node.candidates M2, JobStack.push leak M3, sort L9).

- **Basis:** read
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R076 [sound, info] Search termination: no early exit while a worker is about to push subfolders; no lost wake-ups (broadcast under lock plus 50 ms timed waits); listing errors finish the node.

- **Basis:** read
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R077 [sound, info] Walk structure: symlinked folders not followed; nested archives not descended by the same provider; depth limits right; threads exit on close; earlier-results cap keeps the newest list.

- **Basis:** read
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R078 [sound, info] Block-border carry for byte needles (whole-word boundaries and UTF-16), lastLineEnd bounded by the 4 MB cap, iterative Unicode-correct glob matcher, Spotlight query escaping (parsed back with NSPredicate).

- **Basis:** read
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R079 [sound, info] Duplicate finder on local files: hard links, firmlink aliases, case/normalisation aliases and symlinked roots removed; read errors and cancellation never produce a group.

- **Basis:** read
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R080 [sound, info] Rename planner (rings and chains via temp names, skippingConflicts worklist, autoRenamed numbering, parked-item recovery, Undo records), mask language (ranges, counters, overflow and width clamps; /, NUL, ., .., names over 255 bytes), and undo-history write ordering are sound. The rename runner never replaces a different local file.

- **Basis:** read
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R081 [sound, info] FindFiles correctness: every uncancelled search complete and duplicate-free, two runs same order, 8 concurrent tree searches all complete.

- **Basis:** measured
- **Detail:** Cancelled searches listed only a duplicate-free subset of the truth; searches after the torture still complete. Driven via FileSearch.run and the real FindFilesWindowController headless against independent readdir plus byte scan truth. Data: 100,002 files in 2,000 folders (903 MB) and a 1,000,000-file flat directory plus 200 folders.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R082 [sound, info] Find timings: tree name *.txt 80,000 results 0.33 s; tree text 1,129 results 3.0-3.2 s; million name *7.png 16,667 results 5.2-5.7 s; million text xxxx 99,750 results 42.7-53.4 s; million everything 1,000,200 results 13.0-13.3 s.

- **Basis:** measured
- **Detail:** Stalls >8 ms in window phase: 3, 9, 1, 118, 5 respectively; max stalls 451 ms (harness), 32, 10, 59, 589 ms. 100 window-cancelled searches: 751 s, 457/9/2 stalls, product max 543 ms (2140 ms harness). 100 engine cancels from another thread: 588 s, 61/0/0, max 23 ms.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R083 [sound, info] Find cancellation worked: 88 window cancels ended median 20 ms, p95 489 ms, max 549 ms; 12 finished before cancel; engine run returned median 12.5 ms, p95 492 ms, max 558 ms; none hung.

- **Basis:** measured
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R084 [sound, info] Find threads returned to baseline: baseline 19, 8-29 right after each round, 9 within 0.5 s of the last search.

- **Basis:** measured
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R085 [sound, info] Find memory: no growth in a tree-only run.

- **Basis:** measured
- **Detail:** Peak RSS 11.6 GB for the whole run including harness data. Malloc in use about 690 MB while search threads lived and 143 MB 5 s later, flat over 20 further text searches. Shorter million run ended at 1.1 GB in use (harness truth sets plus the window's kept result sets). CPU: 1,415 s user and 6,439 s system; million text search 209-389 CPU-seconds for 43-53 s wall.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R086 [sound, info] Find stall attribution: product frames appear in only six stalls of 448-589 ms plus two AppKit layout passes of 120 and 248 ms with every core busy; the two stalls over 1 s and several others are the harness's own result checking.

- **Basis:** measured
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### R087 [sound, info] Misc group executions

- **Basis:** reproduced
- **Detail:** 883,773 asan and 726,860 rel: 4 crashes, quoting injection. Diff/rename group 488,763 asan and 639,799 rel: 2 crashes, 2 hangs.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### R088 [sound, info] Spotlight queries escaped.

- **Where:** Plugins/FindFiles/SpotlightSearch.swift:28-63
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open


## Not covered / left behind

### R089 [gap, info] Not covered: user-regex backtracking in Find Files, Multi-Rename and Compare.

- **Basis:** 
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### R090 [gap, info] Nothing in scope was built or run except TextPattern.swift compiled standalone with stubs; tests not run.

- **Basis:** 
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R091 [gap, info] Not measured: NSMetadataQuery cost at scale, memory per result, UserDefaults behaviour with very large values, renamex_np(RENAME_EXCL) on case-only renames.

- **Basis:** 
- **Detail:** 
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### R092 [gap, info] Not covered: SearchForm field handling, saved searches and history sizes.

- **Where:** FindFiles/SearchForm.swift
- **Basis:** read
- **Detail:** Only grepped.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open
