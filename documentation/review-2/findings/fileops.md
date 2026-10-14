# Review 2 — fileops

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### F001 [finding, critical] A Move whose destination is a vfolder: URL deletes the file it just 'moved' (branch view Cut+Paste, F6 same name in another case)

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileJob.swift:586-596; Plugins/FileOperations/FileJob.swift:708-735;
  Plugins/FileOperations/FileJob.swift:536-544; Plugins/FileOperations/FileJob.swift:959-987;
  Plugins/FileOperations/FileJob.swift:362-369; Plugins/FileOperations/FileJob.swift:1583-1639;
  Plugins/Clipboard/ClipboardPlugin.swift:140-154; Plugins/Clipboard/ClipboardPlugin.swift:149;
  Plugins/FileOperations/FileOperationsPlugin.swift:223-257; Plugins/FileOperations/FileOperationsPlugin.swift:418-449;
  Plugins/FileOperations/FileOperationsPlugin.swift:448
- **Basis:** reproduced (t1, t6, t1b)
- **Detail:** In a branch view items have real file: URLs but model.directory is vfolder://branch... Relative targets,
  Paste and multi-rename build destinations in the vfolder: scheme. isSameLocation is false (different schemes).
  entry(at: destination) returns the real item, so FileIdentity.sameEntry is true and plan returns .write(destination,
  replacing: true) without a question, assuming put will rename. put renames only when from === to; local is not the
  virtual provider so it stream-copies to a temp, renames the temp over the destination (the source), returns isMove,
  and the worker then runs remove(item.url) on that same file. Triggers: branch view, Cmd+X on a top-level file, Cmd+V
  in the same panel: file gone with no prompt (t6: asked: [] completed: 1 dir now: []); the Clipboard 'same folder'
  filter at line 149 compares file: with vfolder: and lets it through. Branch view, F6, same name in another letter
  case: same result (t1). By reading: with folders listed, the same on a folder merges it 'into itself' and then deletes
  every file and the folder. Related damage, same root cause: every rename by F6 with a plain name, Shift+F6 with
  several items (TargetSpec(directory: directory, ...) at line 448) and Shift+F5 in a branch view is a stream copy plus
  delete; t1b showed a new inode and extended attributes lost; a large file is copied in full.
  destination.isInside(source) and FileIdentity.isInside are also blind here so 'into own subfolder' is not detected.
- **Proposed fix:** Resolve a virtual directory to its real one before building any TargetSpec
  (VirtualLocation.realDirectory), in FileOperations.transfer, renameSelection, the transfer service and Clipboard
  paste. In FileJob never remove a source unless the destination is proven to be a different entry; if sameEntry was the
  reason for replacing: true and from !== to, refuse. Make FileIdentity compare what entry(at:) returned and re-check
  identity immediately before source removal. ArchiveFileSystem also has 'outside' URLs that alias local files; check
  the same class there.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F002 [finding, high] S2: putting 300k items on a pasteboard (drag start, Cmd+C/X, paste, drag-enter) takes seconds to tens of seconds on main

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** AFMShell/Panel/PanelViewController+Interaction.swift:348-356;
  AFMShell/Panel/PanelViewController+Interaction.swift:265-268; AFMShell/Panel/FileGridView.swift:443;
  Plugins/Clipboard/ClipboardPlugin.swift:122-126; AFMShell/Panel/PanelDragAndDrop.swift:24
- **Basis:** measured
- **Detail:** writeObjects costs 40-57 us per item: 1.2 s for 30k, so 12-17 s for 300k. Drag start in Full view after
  operands(); grid adds 300k NSDraggingItems. Cmd+C/Cmd+X 9.6 s for 300k (measured at 100k). Paste of 100k URLs 1.1 s.
  Drag-enter reads every item back: 5 us per item, about 1.5 s for 300k.
- **Proposed fix:** One pasteboard item carrying a list (or lazy data via NSPasteboardItemDataProvider); keep in-app
  drags in memory keyed by drag sequence number.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### F003 [finding, high] Copy Path of Each File (280 ms) and Copy Names with Path (88 ms) run on main, plus operands() and a large setString

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift
- **Basis:** measured
- **Detail:** Both plus operands(), then setString of 20 MB or more (estimated tens of ms; 100 MB measured 16 ms).
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F004 [finding, high] Cut/Copy to clipboard writes one NSURL per item: 3.2 s for 100k, about 9.6 s for 300k on main

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift:130-134
- **Basis:** measured
- **Detail:** place() calls writeObjects with one NSURL per item. Measured 3.2 s for 100k and linear (about 32 us per
  URL), so about 9.6 s for 300k, plus operands().
- **Proposed fix:** Cap the count or ask first; build one pasteboard item with a file-list type; at minimum show
  progress.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F005 [finding, high] Paste of 100k URLs takes 1.1 s readObjects + 139 ms isSameLocation filter + 0.1-0.2 s completion on main

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift:142,158; Plugins/FileOperations/FileOperationsPlugin.swift:362-364
- **Basis:** measured (completion estimated)
- **Detail:** files() -> readObjects at :142 measured 1.1 s. isSameLocation filter at :158 measured 139 ms. The transfer
  completion at FileOperationsPlugin.swift:362-364 adds about 0.1-0.2 s (estimate).
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F006 [finding, high] Several sources landing on one target name destroy each other under 'Overwrite all' (data loss)

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:498-503; Plugins/FileOperations/FileJob.swift:586-622;
  Plugins/FileOperations/FileJob.swift:644-646
- **Basis:** reproduced (t5)
- **Detail:** claimed only serialises the workers; afterwards the earlier file of this same job is treated as any
  existing file. Trigger: Move of a.doc, a.pdf, a.rtf with mask *.txt and Overwrite all: one a.txt remains, sources are
  empty, completed: 3. By reading, the same applies to: a branch view or search result with equally named files from
  different subfolders; File.txt and file.txt from a case-sensitive source to a case-insensitive target; NFC/NFD twins;
  'Overwrite older' (the second file is newer than the copy of the first).
- **Proposed fix:** Remember per target folder the folded names this job produced; a collision with the job's own output
  always asks, or auto-renames, whatever the mode.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F007 [finding, high] A named pipe (FIFO) in a streamed transfer hangs the job; Cancel has no effect and the app cannot quit

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:776; Plugins/FileOperations/FileJob.swift:842;
  Plugins/FileOperations/FileJob.swift:852; Plugins/FileOperations/FileJob.swift:879;
  Plugins/FileOperations/FileJob.swift:914; Plugins/FileOperations/Checksum.swift:15;
  Plugins/FileOperations/JobBridge.swift:96; AFMShell/App/Shell.swift:105
- **Basis:** reproduced (t3b)
- **Detail:** FileItem.isSpecial exists for this and FileJob never looks at it. Any streamed path opens the source with
  provider.read, and for a FIFO open() blocks for good; the local reader has no interrupt. Affected: local to archive or
  server, followed links, Append/Resume, and 'Compare contents' in the Overwrite dialog (which also holds decisions).
  Trigger: copy a folder containing a FIFO into a zip or to FTP. t3b: still running 4 s after cancel. isBusy stays true,
  every file command stays blocked, and Shell.swift:105 waits for cancelAll forever so quitting needs a force quit.
  Local-to-local copy and verify of a FIFO does not hang (copyItem fails cleanly).
- **Proposed fix:** Skip or report isSpecial items in transfer, verify, extend and compare; open with O_NONBLOCK and
  fstat in the local reader.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F008 [finding, high] Copy/Move/Delete completion computes names(of:among:) (387 ms) and model.deselect (97 ms) in one main-queue block (about 0.5 s)

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:202-208
- **Basis:** measured
- **Detail:** Completion.
- **Proposed fix:** Compute the names on the job thread before returning; the completion then only applies a ready set.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F009 [finding, high] Copy/Move/Delete start does operands() (up to 441 ms) and delete adds capabilities allSatisfy (35-50 ms local, est. 1-1.5 s in a zip or list)

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:327
- **Basis:** measured (zip/list case estimated)
- **Detail:** Start: operands() only, up to 441 ms. delete adds items.allSatisfy { capabilities(for:) } (:327), about
  35-50 ms on local files. Inside a zip or a list every call takes locks and parses a URL: estimated 1-1.5 s, and F2
  applies.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F010 [finding, high] Change Attributes and Create Link completions do per-item parentPaths/locationKey work on main (est. 0.3-0.5 s at 300k)

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileProperties/FilePropertiesPlugin.swift:128-131;
  Plugins/FileProperties/FilePropertiesPlugin.swift:373-375
- **Basis:** measured (closest figure; estimated)
- **Detail:** The closest measurement is 280 ms for parentPaths at 300k; the extra locationKey per item puts these at an
  estimated 0.3-0.5 s.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F011 [verdict, high] Pasteboard write at drag start and Cmd+C/X is slow on large selections

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/Plugins/Clipboard/ClipboardPlugin.swift:138-139;
  Sources/AFMShell/Panel/PanelViewController+Interaction.swift:266-271;
  Sources/AFMShell/Panel/PanelViewController+Interaction.swift:340-348
- **Basis:** CONFIRMED (ran), worse than claimed
- **Detail:** Linear ~0.1 ms/item on a private pasteboard with real files: writeObjects(NSURL) / drag NSPasteboardItems:
  3k 0.43 s / 0.43 s; 10k 1.28 s / 1.45 s; 30k 3.7 s / 3.6 s; 100k 9.8 s / 10.1 s. 300k extrapolates ~30 s, plus
  operands() 0.3 s at 1M. Process was sandboxed, which may inflate per-URL cost. Worse than claimed.
- **Proposed fix:** Write one pasteboard item whose data is provided lazily (NSPasteboardItemDataProvider or single
  custom-type item holding the list); cap or lazily supply public.file-url entries.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### F012 [verdict, high] Delete and Move descend through mount points

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:1222-1288;
  Sources/Plugins/FileOperations/FileJob.swift:1021-1029
- **Basis:** CONFIRMED (ran)
- **Detail:** deleteTree/deleteChildren and transferFolder have no device check (BranchWalker and DirectoryTree do).
  Delete: a permanent delete (not Trash) of a folder containing a mounted disk image erased everything on that volume;
  only error was 'Resource busy' for the mount point itself. Move: merging into an existing folder (item by item)
  emptied the mounted volume into the destination; content survives but the disk is emptied. Reproduced with real
  mounts.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F013 [verdict, high] Several sources onto one target name overwrite each other

**Outcome:** duplicate of F006 — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:498-503; Sources/Plugins/FileOperations/FileJob.swift:586-622
- **Basis:** CONFIRMED (ran), narrower than worded
- **Detail:** Job only waits for the first file to land; plan then treats it as an ordinary existing target. Observed
  (Move, Overwrite all): s/a/x.txt and s/b/x.txt into t/ gave completed=2, one x.txt containing 'from-b', both sources
  gone, no question. Report.txt and report.txt from a case-sensitive source onto APFS left one file with 'lower'. Same
  with and without the parallel pool. Narrower than worded: in default Ask mode the Overwrite question does appear for
  the second file; real loss needs Move plus Overwrite all (preset or answered earlier); with Copy the sources survive.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F014 [finding, high] NameTemplate.slice end = start + length - 1 overflows for <[N1,-9223372036854775808] because min($0, maxWidth) keeps negative lengths

**Outcome:** fixed (first pass) — see `status/fileops-p2.md`

- **Where:** Sources/Plugins/FileOperations/NameTemplate.swift:343
- **Basis:** reproduced (line inferred)
- **Detail:** Same entry point. Typed <[N1,-9223372036854775808] gives length = Int.min. The line is inferred from the
  code; the symboliser only resolved the frame to slice. Reproducer: repro/diff/nametemplate-slice-length-overflow.bin.
- **Proposed fix:** Same as finding 1.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### F015 [finding, high] NameTemplate.slice width = last - start + 1 overflows for a typed range like <[N9223372036854775807--9223372036854775807], crashing the app

**Outcome:** fixed (first pass) — see `status/fileops-p2.md`

- **Where:** Sources/Plugins/FileOperations/NameTemplate.swift:352
- **Basis:** reproduced
- **Detail:** User types it in New folder F7 / New file Shift+F4. start = Int.max-1 and last = count - Int.max, so the
  subtraction overflows. NameTemplate.names runs inside the job, so the trap kills the app. Reproducer:
  repro/diff/nametemplate-slice-overflow.bin; command: `$F/build-rel/release/fuzz-diff run nametemplate <file>`.
- **Proposed fix:** Limit the digits read (as RenameMask.Scanner.number does with 9), or clamp positions and lengths to
  0...255, reject negative lengths, and use overflow-reporting arithmetic.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### F016 [finding, high] Two crashes in name templates (New folder / New file) on typed ranges near Int.max/Int.min

**Outcome:** fixed (first pass) — see `status/fileops-p2.md`

- **Where:** Sources/Plugins/FileOperations/NameTemplate.swift:352;
  Sources/Plugins/FileOperations/NameTemplate.swift:343
- **Basis:** reproduced
- **Detail:** last - start + 1 (352) and start + length - 1 (343) overflow. Reproducers
  repro/diff/nametemplate-slice-overflow.bin and nametemplate-slice-length-overflow.bin (fuzz-diff, target
  nametemplate).
- **Proposed fix:** Limit the digits read, as RenameMask does.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### F017 [verdict, high] FIFO hangs a streamed transfer

**Outcome:** duplicate of F007 — see `status/fileops.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:334-336;
  Sources/AFMKernel/FileSystem/FileSystemProvider.swift:346-349; Sources/Plugins/FileOperations/FileJob.swift:1118;
  Sources/AFMShell/App/Shell.swift:103-107
- **Basis:** CONFIRMED (ran)
- **Detail:** LocalFileSystem.read opens with a blocking FileHandle(forReadingFrom:); no cancellable variant, default
  only checks the flag before opening. isSpecial is not consulted in FileJob. Steps: copy a folder containing a named
  pipe to an archive, server or other file system. Observed: not finished after 3 s, not finished 3 s after cancel(),
  ended only when the pipe's write end was opened. Quit: applicationShouldTerminate returns .terminateLater and waits
  for the job with no timeout (read, app not launched). Scope: plain local-to-local copy does not hang (uses copy; pipe
  not copied); local-to-local with follow links on a link to a pipe does hang.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F018 [verdict, high] Move inside a branch view destroys the file

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Sources/Plugins/VirtualFolders/VirtualFileSystem.swift:271-276;
  Sources/Plugins/FileOperations/FileJob.swift:593-594; Sources/Plugins/FileOperations/FileJob.swift:709-734;
  Sources/Plugins/FileOperations/FileJob.swift:539-541; Sources/Plugins/FileOperations/FileJob.swift:362-368;
  Sources/Plugins/Clipboard/ClipboardPlugin.swift:149
- **Basis:** CONFIRMED (ran)
- **Detail:** virtualItem returns the real file for vfolder://.../d/a.txt so FileJob plans .write(replacing: true). In
  put the two providers differ, so the file is stream-copied to a temp, renamed over itself, then removed at 539-541.
  targetsSourceFolder is false for a move and the paste filter compares a file: folder with a vfolder: one. Steps: open
  a branch view, Cmd+X then Cmd+V on a file in the branch root, or F6/Shift+F6 and type the same name in another letter
  case. Observed: job reports completed=1, no error, no question; a.txt and c.txt gone from disk. Scope: only files
  directly in the branch root; a file from a subfolder is moved up into the root, and a copy is refused with 'cannot
  copy a file to itself'.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F019 [finding, medium] 'Follow links' cycle detection is textual only: a link to a directory outside the tree containing a link back to itself (Y/m -> .) is not seen as a cycle

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1108-1119; Plugins/FileOperations/FileJob.swift:1558-1565
- **Basis:** reproduced (t2)
- **Detail:** t2 produced 34 nested levels of copies before the kernel's link limit stopped it. With two such links the
  walk branches at every level, in the count before the job as well.
- **Proposed fix:** Compare the resolved target against the resolved ancestors, or keep a set of visited (dev, ino).
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F020 [finding, medium] Delete and Move descend through mount points (no st_dev comparison); a folder containing a mounted disk image or share has that volume's contents deleted one by one

**Outcome:** duplicate of F012 — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1222-1245; Plugins/FileOperations/FileJob.swift:1270-1288
- **Basis:** inferred (plausible)
- **Detail:** Data loss; plausible, read from the code, not run.
- **Proposed fix:** Stop at a device change and ask.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F021 [finding, medium] Job-thread provider calls that cannot be cancelled (remove, move, createDirectory, setAttributes, copyMetadata, quarantine); makePool looks only at the first source's folder

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileJob.swift:540; Plugins/FileOperations/FileJob.swift:1002;
  Plugins/FileOperations/FileJob.swift:1043; Plugins/FileOperations/FileJob.swift:1173;
  Plugins/FileOperations/FileJob.swift:1255; Plugins/FileOperations/FileJob.swift:745;
  Plugins/FileOperations/FileJob.swift:1059-1064; Plugins/FileOperations/FileJob.swift:450-453
- **Basis:** inferred (plausible)
- **Detail:** A stalled server or share holds run() until the provider times out, with the same quit consequence as
  finding 2. makePool: a search result that starts on the SSD puts pool workers on slow volumes too.
- **Proposed fix:** Cancellable variants or time limits; check every source folder in makePool.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F022 [finding, medium] Resume on a target that is a symlink truncates and overwrites the file the link points to (data loss)

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:616-618; Plugins/FileOperations/FileJob.swift:830-832;
  Plugins/FileOperations/FileJob.swift:876-886; Plugins/FileOperations/FileJob.swift:837-862
- **Basis:** reproduced (t4)
- **Detail:** A link has size 0, so Resume is offered and passes existing.size < item.size. startsWithPartial with
  length 0 is trivially true. append(to:at: 0) opens through the link and cuts the target. Also the rewrite path at
  837-862 (file systems without .append) has no prefix check at all unless Verify is on.
- **Proposed fix:** No Resume or Append when existing.isSymlink or isSpecial; O_NOFOLLOW in append; do the last-block
  check in both paths.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F023 [finding, medium] The 2-second timestamp tolerance applies to every volume: 'Overwrite all older' skips a genuinely newer source (up to 2 s), 'Overwrite older and same age' overwrites a target newer by up to 2 s

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:647-648; Plugins/FileOperations/FileJob.swift:653;
  Plugins/FileOperations/FileJob.swift:658-664
- **Basis:** read (confirmed by reading)
- **Detail:** Data loss: save, copy, save again, copy again loses the update in the copy.
- **Proposed fix:** Apply the tolerance only where a side has coarse timestamps (FAT, exFAT, non-local, or a whole even
  second); compare exactly on APFS.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F024 [finding, medium] 'Keep partial files' makes Retry impossible: the partial takes the real name, Retry copies in full then fails its exclusive rename with 'already exists' and the complete copy is discarded

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:725-733
- **Basis:** read (confirmed by reading)
- **Detail:**
- **Proposed fix:** On Retry treat the kept partial as replaceable (or resume it), or keep it under a recognisable name.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F025 [finding, medium] S9: operation start and completion at 300k: operands() 256 ms at every start, completions about 0.5 s; Verify Checksums 1.3-1.5 s before its alert (mask and regex compile per item)

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:202-208;
  Plugins/FileOperations/FileOperationsPlugin.swift:270; Plugins/FileTools/FileToolsPlugin.swift:291-303;
  Plugins/FileTools/ChecksumFiles.swift:429-433
- **Basis:** measured
- **Detail:** Fork-reported parts as reported.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### F026 [finding, medium] F5/F6 towards a panel in branch view creates a real folder named 'dir (branch)'

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:234-235;
  Plugins/FileOperations/FileOperationsPlugin.swift:263; Plugins/FileOperations/TargetSpec.swift:124-128
- **Basis:** reproduced (t8)
- **Detail:** The proposal is displayPath(target) + '/' + name. Only the bare display path reads back as the virtual
  folder; with a suffix it is a plain file path. makeJob then silently creates that folder and transfers into it.
- **Proposed fix:** Propose the real directory of a virtual target, or refuse a list as target.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F027 [finding, medium] FileOperationsPlugin.stop -> OperationLog.flush() does a queue.sync on main at quit; blocks if the log is on a stalled volume

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/OperationLog.swift:101-106
- **Basis:** read (reported as confirmed)
- **Detail:** Quit only.
- **Proposed fix:** Same: flush in applicationShouldTerminate with .terminateLater.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F028 [finding, medium] Typing 755 over a prefilled 4755 keeps set-user-ID (three digits mean 'keep special bits'); single folder with Recurse ticked and mode untouched changes nothing and returns silently

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/AttributeChange.swift:30-31; Plugins/FileProperties/AttributeChange.swift:87;
  Plugins/FileProperties/AttributeChange.swift:180; Plugins/FileProperties/FilePropertiesPlugin.swift:418-419;
  Plugins/FileProperties/FilePropertiesPlugin.swift:493
- **Basis:** read (confirmed by reading)
- **Detail:** Security/correctness. The dialog cannot clear setuid unless the user types 0755.
- **Proposed fix:** When the prefilled text had four digits, read three as absolute; when Recurse is ticked and the
  field is untouched, ask or say so.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F029 [finding, medium] Create Link joins every failure into one ui.inform detail; 300k lines make NSAlert lay out about 20 MB of text

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/FilePropertiesPlugin.swift:371
- **Basis:** inferred (plausible)
- **Detail:** Modal/scaling, plausible. Links into a read-only target for 300k items give 300k lines (the join itself
  measured 11 ms). NSAlert must lay out about 20 MB of text; estimated several seconds or more inside a modal.
- **Proposed fix:** Cap at about 20 lines plus '... and N more', as FileJob and ArchiveCommands.summary already do.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F030 [finding, medium] Create Link joins every failure into one unbounded alert text

**Outcome:** duplicate of F029 — see `status/fileops.md`

- **Where:** Plugins/FileProperties/FilePropertiesPlugin.swift:371
- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### F031 [verdict, medium] Link-cycle detection is textual

**Outcome:** duplicate of F019 — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:1108-1113;
  Sources/AFMKernel/FileSystem/FileItem.swift:103-111; Sources/Plugins/FileOperations/FileJob.swift:1558-1565
- **Basis:** CONFIRMED (ran)
- **Detail:** resolvingLink uses URL.isInside/isSameLocation which are string prefix tests. Steps: copy with follow
  links a folder containing loop -> . reached through a symlinked parent path. Observed: direct path gave 1 copy;
  through the alias gave 31 nested copies, 32 levels deep, stopped only by the kernel's link limit. Not tested: with k
  such links per folder growth would be about k^31; counting pass measure has the same test.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F032 [finding, medium] Deleting a symlink the system refuses with EPERM chmods the link's target

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:1360-1370; Sources/Plugins/FileOperations/FileJob.swift:745
- **Basis:** reproduced
- **Detail:** removing answers the 'locked' question by calling setAttributes(item.permissions | 0o200) on the URL,
  which for a link lands on its target (claim 11). Steps: delete a link inside a locked folder (sticky folder with
  foreign-owned link should behave the same), answer the locked question yes. Observed: delete still failed and the
  link's target private/key.pem went from 600 to 755. Permissions exposure, not data loss. discard (745) has the same
  pattern for a locked temp.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F033 [verdict, medium] Resume onto a symlink destination rewrites the link's target

**Outcome:** duplicate of F022 — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:617; Sources/Plugins/FileOperations/JobBridge.swift:56;
  Sources/Plugins/FileOperations/FileJob.swift:876-886; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:368-386
- **Basis:** CONFIRMED (ran)
- **Detail:** A link has size 0 so guard at 617 passes and the dialog offers Resume. resumeInPlace compares zero bytes,
  then LocalFileSystem.append opens with O_WRONLY, follows the link and truncates. Steps: copy f.txt to a folder where
  f.txt is a link, choose More > Resume. Observed: elsewhere/victim.txt (53 bytes) now contains 'source-bytes'; link
  still a link.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F034 [finding, medium] Every local read loop has the autorelease-retention problem (claim 12 class)

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:813; Sources/Plugins/FileOperations/Checksum.swift:21;
  Sources/Plugins/FindFiles/DuplicateFinder.swift:121; Sources/Plugins/FindFiles/TextPattern.swift:314-347;
  Sources/Plugins/FindFiles/FileSearch.swift:461; Sources/Plugins/DirectorySync/SyncComparison.swift:342;
  Sources/Plugins/FileTools/ToolRun.swift:135
- **Basis:** measured (isolated block); not measured in app
- **Detail:** In isolation a GCD block reading 200 MiB through FileHandle.read(upToCount:) held 200 MiB until the block
  ended. Same reader used with no pool in: FileJob:813 (stream copy local to server or archive; whole job is one block),
  Checksum.swift:21, DuplicateFinder.swift:121, TextPattern.swift:314-347 (on search threads that live for the whole
  search, FileSearch.swift:461), SyncComparison.swift:342, ToolRun.swift:135. Memory would grow by roughly the bytes
  read. Not measured in the app.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### F035 [finding, low] NameTemplate: empty names from the list branch, and a DateFormatter built per name

**Outcome:** duplicate of F074 — see `status/fileops.md`

- **Basis:** measured
- **Detail:** About 13 s for <0-99999>[d].
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### F036 [finding, low] CommentStore remembers a stale read after a write (load racing setComment/forget)

**Outcome:** fixed — see `status/fileops.md`

- **Where:** FileProperties/Descript.swift:198; FileProperties/Descript.swift:199-201;
  FileProperties/Descript.swift:208-212; FileProperties/Descript.swift:265;
  FileProperties/FilePropertiesPlugin.swift:325-326
- **Basis:** read
- **Detail:** Low-medium. T1: comments(in:) is in load (:198). T2: setComment moves the new file into place and calls
  forget (:265, :208-212). T1 then stores the old comments with a fresh timestamp (:199-201). save's completion reloads
  the panels at once, so the Comment column gets the old text and, per the ContentColumn contract, the panel keeps it.
- **Proposed fix:** A per-key generation bumped by forget; remember only if it is unchanged.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### F037 [finding, low] Attributes, comment and link-target completions have no stale-result guard (dialogs, or panel.show)

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** FileProperties/FilePropertiesPlugin.swift:385
- **Basis:** read
- **Detail:** Low.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### F038 [finding, low] getpwuid_r / getgrgid_r called on the main thread in AttributeDraft.fields

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** FileProperties/FilePropertiesPlugin.swift:466-467; FileProperties/FilePropertiesPlugin.swift:163;
  FileProperties/FilePropertiesPlugin.swift:152
- **Basis:** read
- **Detail:** AttributeDraft.fields is called from ask, which runs in a job completion on main. This can block with
  network directory services.
- **Proposed fix:** Resolve the names in the 'Reading attributes' job (:152).
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### F039 [finding, low] pasteboard.data and string read on the main thread (paste, rename template); a large or lazily provided item waits for the other application

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift:169-175; Plugins/Clipboard/ClipboardPlugin.swift:143;
  Plugins/FileOperations/FileOperationsPlugin.swift:480
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F040 [finding, low] A failed paste-as-file leaves a partial Clipboard.txt

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift:192-194
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F041 [finding, low] Performance: two display strings and two URL appends per child even when the report is throttled

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1027
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F042 [finding, low] Performance: isKept is linear with a key built per element

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1128-1130
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F043 [finding, low] Residual check-then-use races on paths: a folder swapped for a symlink between listing and use leads Delete, or the source removal of a Move, into the link's target; recursive chmod/date changes follow a link put in place after listing

**Outcome:** fixed in part — see `status/integration.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1222-1259; Plugins/FileProperties/AttributeChange.swift:334-343
- **Basis:** read
- **Detail:** Security.
- **Proposed fix:** openat/unlinkat/fchmodat with no-follow in the local provider.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F044 [finding, low] Any EPERM counts as 'locked' and adds owner-write to the file even when the retry fails

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1360-1371
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F045 [finding, low] Performance: record strings built before the log's filter

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1431-1434
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F046 [finding, low] Pause details: a paused thread holds counters so every other worker stops at its next counter update with reader/writer open; Pause not honoured while deferred sources are removed or during commit; Abort chosen in a dialog opened just after Pause sets stop but the gate watches only cancellation, so the job stays 'Paused' until Resume

**Outcome:** fixed — see `status/integration.md`

- **Where:** Plugins/FileOperations/FileJob.swift:1440-1443; Plugins/FileOperations/FileJob.swift:1470-1480;
  Plugins/FileOperations/FileJob.swift:811-818; Plugins/FileOperations/FileJob.swift:1164-1178;
  Plugins/FileOperations/FileJob.swift:1409
- **Basis:** read
- **Detail:** Server connections time out during the pause, then error dialogs.
- **Proposed fix:** Report progress outside counters (snapshot under the lock, call the delegate after); let Abort open
  the gate.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F047 [finding, low] Performance: the measure cache can hold 100,000 long keys, tens of megabytes rather than 'a few'

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileJob.swift:206-214
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F048 [finding, low] Performance: each top-level source is looked up three times (three round trips per selected file on servers)

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:377; Plugins/FileOperations/FileJob.swift:1532;
  Plugins/FileOperations/FileJob.swift:418; Plugins/FileOperations/FileJob.swift:590
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F049 [finding, low] Top-level source names are not passed through isSafeName; a provider entry named .. would merge into the target's parent

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:412
- **Basis:** inferred (plausible)
- **Detail:** Plausible; depends on the providers.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F050 [finding, low] Source removal of a cross-volume move does not use the unlock route, so each locked file errors

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:539-542
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F051 [finding, low] Leak: `.afm-<uuid>.tmp` files stay forever when discard fails or the app dies

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:740-748
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F052 [finding, low] setQuarantine failures are ignored, and for folders it runs after copyMetadata, which may have locked the folder

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileOperations/FileJob.swift:789; Plugins/FileOperations/FileJob.swift:860;
  Plugins/FileOperations/FileJob.swift:897; Plugins/FileOperations/FileJob.swift:1063-1064
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F053 [finding, low] Streamed permissions applied unmasked, including setuid and world-writable bits from an archive or server

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:807-809
- **Basis:** inferred (plausible)
- **Detail:** Plausible.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F054 [finding, low] Append rewrites the target as a new file, losing its extended attributes, ACL and creation date

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileJob.swift:837-862
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F055 [finding, low] Destructive prompts default to 'Yes' (even Permanently delete); untrusted names rendered raw everywhere (newline, U+202E, zero-width); newlines forge operation-log lines and add entries to %L/%F list files

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:329-331; AFMShell/App/AlertInteraction.swift:32-37;
  Plugins/FileOperations/TargetSpec.swift:130-135; Plugins/FileOperations/OperationLog.swift:114-121;
  Plugins/Configuration/ParameterExpansion.swift:514-516
- **Basis:** read (confirmed)
- **Detail:** Rated LOW/MEDIUM. Buttons [Yes,No] and the first button is the Return default. TargetSpec interpolates the
  bare name with no path; no code neutralises newlines, U+202E or zero-width characters in alerts, titles or the list. A
  newline in a file name forges operation-log lines and adds entries to %L/%F list files so a user command processes
  paths the user did not select.
- **Proposed fix:** One display-escaping helper for control and bidi characters; default button 'No' for .critical;
  escape \n in logs; refuse or escape names with newlines in list files.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### F056 [finding, low] 'Overwrite all' does not carry across the per-item jobs of a multi-rename

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:446-456
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F057 [finding, low] nameContext reads the pasteboard string on main when the typed name contains [X

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:480
- **Basis:** read
- **Detail:**
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F058 [finding, low] model.selection.count > 1 builds a `Set<String>` of all marks (22 ms at 300k) in enabled closures and unpack

**Outcome:** fixed — see `status/archnet-p2.md`

- **Where:** Plugins/FileOperations/FileOperationsPlugin.swift:71;
  Plugins/FileProperties/FilePropertiesPlugin.swift:206; Plugins/Archives/ArchiveCommands.swift:320
- **Basis:** measured
- **Detail:**
- **Proposed fix:** Use selectionCount.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F059 [finding, low] NameTemplate [X] keeps /, .. and ~ from the clipboard

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/NameTemplate.swift:180-183; Plugins/FileOperations/FileOperationsPlugin.swift:515
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F060 [finding, low] OperationLog: names and error texts go in raw; a newline in a file name forges log lines

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/OperationLog.swift:114-121
- **Basis:** read
- **Detail:**
- **Proposed fix:** Escape control characters.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F061 [finding, low] OperationLog: after one rotation in a burst, size is 0 and no further rotation happens in that burst

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/OperationLog.swift:143-148
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F062 [finding, low] OperationLog handle is not O_APPEND; external truncation leaves a hole of NULs and a second writer is overwritten

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileOperations/OperationLog.swift:170-176
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F063 [finding, low] Attribute changes: symbolic modes and partial dates start from the listed (possibly stale) values, not the file's current ones

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/AttributeChange.swift:337; Plugins/FileProperties/AttributeChange.swift:340
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F064 [finding, low] Any mode containing owner-write silently unlocks a Finder-locked file through the provider, even with 'Locked: Unchanged'

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/AttributeChange.swift:343
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F065 [finding, low] CommentStore keeps a stale read after a write

**Outcome:** duplicate of F036 — see `status/fileops.md`

- **Where:** Plugins/FileProperties/Descript.swift:198-212
- **Basis:** read (reviewer)
- **Detail:** Low-medium; reviewer-reported.
- **Proposed fix:** A per-key generation bumped by forget.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### F066 [finding, low] descript.ion: a FIFO (or link to one) named descript.ion blocks the Comment column threads and hangs the Properties and Edit Comment jobs

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/Descript.swift:217; Plugins/FileProperties/Descript.swift:235;
  Plugins/FileProperties/PropertyDetails.swift:124
- **Basis:** inferred (plausible)
- **Detail:** Plausible; same class as finding 2.
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F067 [finding, low] descript.ion: a symlinked or hidden comment file is replaced by a plain, possibly unhidden one

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/Descript.swift:275-280
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F068 [finding, low] descript.ion: names containing " or a line break are written unescaped and read back as other entries

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/Descript.swift:68-78; Plugins/FileProperties/Descript.swift:127
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F069 [finding, low] A symbolic mode passed as a parameter is dropped when the dialog is shown

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/FileProperties/FilePropertiesPlugin.swift:435
- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F070 [finding, low] countDirectoryContents enabled closure scans all 1M items (items.contains(where: \.isFolder)) when the folder holds only files (est. 2-5 ms per validation)

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/FileProperties/FilePropertiesPlugin.swift:56
- **Basis:** inferred (estimated)
- **Detail:** Scaling; runs on every Files-menu or context-menu validation.
- **Proposed fix:** Keep a folder count in PanelModel.totals.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F071 [finding, low] Paste validation hasFiles() grows with clipboard contents

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Sources/Plugins/Clipboard/ClipboardPlugin.swift:62
- **Basis:** measured
- **Detail:** Copying a large selection makes every later validation slower (see claim 6).
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### F072 [verdict, low] 2-second timestamp tolerance applied on every volume

**Outcome:** duplicate of F023 — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:660-664
- **Basis:** CONFIRMED (ran)
- **Detail:** Unconditional. On APFS with 'Overwrite all older', a source 1.5 s newer was skipped and one 2.5 s newer
  was copied. Also affects 'older or same' and 'rename older, skip newer'.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F073 [verdict, low] Keep partial files breaks Retry

**Outcome:** duplicate of F024 — see `status/fileops.md`

- **Where:** Sources/Plugins/FileOperations/FileJob.swift:727-729; Sources/Plugins/FileOperations/FileJob.swift:724
- **Basis:** CONFIRMED (ran)
- **Detail:** Option renames the partial to the real name; Retry re-runs the same .write(replacing: false) plan and 724
  fails with 'already exists'. Observed: error 1 injected failure, error 2 '.../big.bin already exists'; 4-byte partial
  stayed, job did not complete. With option off Retry succeeded. No data loss.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F074 [finding, low] NameTemplate builds a DateFormatter for every [d]/[t] of every name; <0-99999>[d] took 26.7 s

**Outcome:** fixed (first pass) — see `status/fileops-p2.md`

- **Where:** Sources/Plugins/FileOperations/NameTemplate.swift:284-289
- **Basis:** measured
- **Detail:** Slow but bounded. <0-99999>[d] took 26.7 s in the driver, which expands it twice (names plus
  rangePreview), so about 13 s per names() call on the job thread. Reproducer: repro/diff/nametemplate-slow-range.bin
  (--timeout 100).
- **Proposed fix:** One formatter per expansion.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### F075 [finding, low] NameTemplate.names returns empty names from the list branch while the range branch filters them out

**Outcome:** fixed (first pass) — see `status/fileops-p2.md`

- **Where:** Sources/Plugins/FileOperations/NameTemplate.swift:66-78; NameTemplate.swift:65
- **Basis:** reproduced
- **Detail:** Property mismatch. Minimal counterexample <[T2+1D] returns [""]. Reproducer:
  repro/diff/nametemplate-empty-name.bin, target nametemplate, with FZ_EMPTY_NAMES=1.
- **Proposed fix:** Filter empty names in the list branch too.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### F076 [verdict, low] '755' over 4755 keeps setuid (deliberate)

**Outcome:** duplicate of F028 — see `status/fileops.md`

- **Where:** Sources/Plugins/FileProperties/AttributeChange.swift:31;
  Sources/Plugins/FileProperties/AttributeChange.swift:87; Sources/Plugins/FileProperties/FilePropertiesPlugin.swift:460
- **Basis:** CONFIRMED (ran)
- **Detail:** Comment at 19-20 documents it. Observed: '755' gives 4755, 'rwxr-xr-x' gives 4755, '0755' gives 755.
  Differs from chmod 755; dialog hint does not mention it.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### F077 [finding, low] descript.ion rewrite drops leading empty lines so a first name starting with FF FE / FE FF / EF BB BF becomes a byte-order mark; comments are lost and later edits refused

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Sources/Plugins/FileProperties/Descript.swift:55-57
- **Basis:** reproduced
- **Detail:** D1. Together with data(). After any comment edit the file reads differently or not at all: all comments
  disappear and later edits are refused as "unreadable". Minimal: 0A FF FE. Reproducers
  descript-rewrite-bom-collision.bin (target descript); descript-store-bom-name-lost.bin and
  descript-store-file-unreadable-after-edit.bin (target descript-store). Run with FZ_DESCRIPT_ALL=1.
- **Proposed fix:** Parse and write on scalars or bytes, and never let a mark-free file begin with BOM bytes.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### F078 [finding, low] descript.ion line parser works by Character, so a separator space or quote that forms one character with its neighbour is not seen

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Sources/Plugins/FileProperties/Descript.swift:71-76
- **Basis:** reproduced
- **Detail:** D2. E.g. a name ending in U+0600, a comment starting with a combining mark, "<U+0301>". Minimal: E3 83 D8
  80 62. Reproducers descript-line-misread-prepend-char.bin and descript-quoted-line-misread-combining-mark.bin (target
  descript-line); descript-rewrite-prepend-char.bin (target descript). Comments misread or lost, no crash.
- **Proposed fix:** Parse and write on scalars or bytes.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### F079 [finding, info] One global().async per Finder Info request

**Outcome:** not a defect — see `status/fileops-p2.md`

- **Where:** FileProperties/FilePropertiesPlugin.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### F080 [finding, info] Paste enabled closure costs 55 ms on the first call after 100k URLs land on the pasteboard

**Outcome:** fixed — see `status/fileops.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift
- **Basis:** measured
- **Detail:** canReadObject(NSURL) measured 55 ms on the first call after 100k URLs land on the pasteboard, about 0.01
  ms after; 0.09 ms with 100 MB of text; types only, never the data.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F081 [finding, info] saveDetails (two), setAttributes and editComment, and the file-operation enabled closures inherit the OpenArchive.capabilities lock stall (F2) inside a zip

**Outcome:** fixed — see `status/archnet-p2.md`

- **Where:** Plugins/Clipboard/ClipboardPlugin.swift; Plugins/FileProperties/FilePropertiesPlugin.swift;
  Plugins/FileOperations/FileOperationsPlugin.swift
- **Basis:** read
- **Detail:** From the enabled-closure inventory.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

## Checked and found sound

### F082 [sound, info] Progress reporting is throttled at the source

- **Basis:** read
- **Detail:** FileJob progressInterval = 0.04 (FileOperationsPlugin.swift:185, enforced at FileJob.swift:1472-1474), so
  at most 25 reports/s regardless of worker count. ToolRun.advance allows at most 20/s with a try-lock; forced reports
  are per part or phase, not per block. Archive testing ticks at 10 Hz. The failures list is capped at 20. How
  monitor.report reaches main is the shell's side.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F083 [sound, info] Questions from jobs are modal one at a time and user-driven

- **Basis:** read
- **Detail:** All go through monitor.ask or kernel.askUser. Compare-contents hashing runs on the job thread between
  dialogs. The archive failure alert is shown once per distinct message.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F084 [sound, info] Transfer setup runs on the job thread

- **Basis:** read
- **Detail:** TargetSpec.parse, FileJob construction, target-folder creation and the per-item URL mapping all run inside
  makeJob. The dialog texts are O(1) ('Copy N file(s) to'), with no joining of names.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F085 [sound, info] Operation log writes go to their own queue in 0.25 s bursts

- **Basis:** read
- **Detail:** flushSoon is asynchronous.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F086 [sound, info] FileProperties attribute reads, properties, space calculation, comment load/save and link creation run in jobs

- **Basis:** read
- **Detail:** Content columns (LocalInfo, CommentStore, whose condition.wait is at Descript.swift:193) are evaluated by
  the shell's ColumnValueStore on a utility queue, not main.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F087 [sound, info] Paste enabled closure looks at types only, never data

- **Basis:** read
- **Detail:**
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### F088 [sound, info] FileJob: semaphore and group balanced on all paths; job thread never waits for a slot while holding decisions; monitor.report serialised by counters so ProgressSheet.lastReport is not raced (same for ToolRun, ProgressMeter, SyncExecutor); interrupting tokens released before reader.close()

- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### F089 [sound, info] OperationLog concurrency, flush at quit and pruning are sound; size-rotation and prune path ran clean in the tsan case

- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F090 [sound, info] descript.ion size cap, strict decoding, atomic replace and read-once condition are sound

- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F091 [sound, info] Answers to questions: cut then paste removes the source only after the destination has its real name (except finding 1); deferred-writes Move removes nothing before a successful commit and a failed/cancelled commit keeps all pending sources and parents

- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F092 [sound, info] Folder ordering (create, children settled, setAttributes, copyMetadata, quarantine, source rmdir only if empty) is correct; Skip All / Overwrite All between workers serialised under decisions

- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F093 [sound, info] Exceptions in pool work: only Cancelled can escape and both pools are waited for on every exit path; parallel delete never follows symlinks and unsafe names are rejected and keep the parent; Save Details write is atomic

- **Basis:** read
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F094 [sound, info] Shared mutable state in FileJob/OperationLog/CommentStore/ProgressMeter/AttributeJob/Clipboard is sufficiently protected (decisions, counters, remembered, pendingRemovals, Batch lock, Tally lock, serial queue, NSCondition); lock order: decisions, counters and leaf locks never nested; main takes none; no inversion or lost wake-up. A ThreadSanitizer run of a parallel copy with verify, filtered move and parallel delete with the log on reported no race

- **Basis:** reproduced
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### F095 [sound, info] FileJob stress: no invariant violation, crash, hang or deadlock in any run; no main-thread stall over 100 ms attributable to the app

- **Basis:** measured
- **Detail:** Runs through the real ProgressJobService headless; random pause/resume/cancel (half via main, half from a
  background thread). jobs-50seeds-20k: 20,006 files, 400 folders, 64 MB, 50 seeds, 274 local jobs (95 cancelled) + 60
  deferred, 611 s, peak RSS 157 MB, max main stall 15.0 ms, threads 8/40/8-9. jobs-full-100k-rerun: 100,012 files, 2,000
  folders, 225 MB, 4 seeds, 26 jobs (8 cancelled), 275 s, 409 MB, max stall 33.3 ms (move-back), threads 10/38/9.
  jobs-full-100k: 8 seeds, 47 jobs, 594 s, 414 MB, stall data not usable.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### F096 [sound, info] FileJob invariants hold in all runs

- **Basis:** measured
- **Detail:** No file lost; no partial or different file under a final name; no .afm-*.tmp left; every job ended
  (cancelled within milliseconds); no job reported an error or counted a failure; progress never went backwards or past
  total; threads returned to baseline within 8 s.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### F097 [sound, info] Deferred-writes target: no source removed without a successful commit covering its write

- **Basis:** measured
- **Detail:** 60 moves from disk to a MemoryFileSystem claiming .deferredWrites, commit failure rates 0/20/50/100 %,
  batch sizes 7/40/250/10,000, random cancel/pause: 581 good and 32 failed commits; 40,258 sources removed, 139,922 kept
  (renames into place counted as writes).
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### F098 [sound, info] FileJob rates uninterrupted on 100k tree: copy 6.0k files/s (16.7 s), delete 22k files/s, move with half merged 16.9k files/s

- **Basis:** measured
- **Detail:** Noise floor: while the harness verified trees on 16 threads, 2-3 % of pings exceeded 8 ms (max 87 ms); the
  few >8 ms pings in job phases are below that.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open
