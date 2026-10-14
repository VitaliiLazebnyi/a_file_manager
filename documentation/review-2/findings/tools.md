# Review 2 — tools

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### T001 [finding, high] Create separate checksum files passes up to 300k folders to panels.refresh, which compares each against both panels (est. 0.8 s or more)

**Outcome:** fixed — see `status/tools.md`

- **Where:** Plugins/FileTools/FileToolsPlugin.swift:283
- **Basis:** inferred (estimated)
- **Detail:**
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### T002 [finding, high] Verify Checksums on ordinary files builds a FileMask and compiles an NSRegularExpression per item on main (about 1.3-1.5 s at 300k) and reads the pasteboard string

**Outcome:** fixed — see `status/tools.md`

- **Where:** Plugins/FileTools/FileToolsPlugin.swift:291-303; Plugins/FileTools/FileToolsPlugin.swift:297;
  Plugins/FileTools/ChecksumFiles.swift:429-433
- **Basis:** measured
- **Detail:** isChecksumFile builds a FileMask per item: measured 286 ms. checksumInName compiles an NSRegularExpression
  per item: measured 773 ms. Total with operands() about 1.3-1.5 s, before the 'Please select only...' alert. It also
  reads the general pasteboard string on main at :297; that blocks if the clipboard owner supplies the text lazily and
  is slow.
- **Proposed fix:** Hoist the mask and the regex out of the loop; do the classification in the job.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### T003 [finding, high] The cost-limited Myers split produces grossly wrong diffs on large files

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/Myers.swift:77, 178-188
- **Basis:** reproduced
- **Detail:** When a split hits limit (256 for typical sizes) only the furthest point of the forward walk is used. If
  files are shifted by more than limit lines that also occur on the other side, each split lands on a random diagonal
  and the rest of the file is consumed as "different". Trigger: files of 20,000+ lines after filtering with a large
  moved or deleted block plus scattered edits. Seeded runs, 20/20 seeds each: 30k-line source-like file, 300 edits,
  2,000-line block deleted: 25,894 changed lines shown, shortest script 2,548; 400-line block moved plus 100 edits:
  46,806 shown, shortest 994; 500 edits plus a 500-line block deleted (random values): 47,224 shown, shortest 1,458
  (17/20 seeds). The script is always valid but shows nearly identical files as almost entirely different.
- **Proposed fix:** At the limit choose the split from whichever walk progressed further, or the diagonal with the
  longest recent snake as GNU diff does. Better, anchor on lines unique to both sides (patience/histogram) before
  falling back to Myers.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T004 [verdict, high] DirectorySync: empty left side proposes deleting all right-side files

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncModel.swift:139; Sources/Plugins/DirectorySync/SyncSession.swift:377
- **Basis:** CONFIRMED (ran) as behaviour
- **Detail:** In asymmetric mode all four right-side files came out rightOnly -> deleteRight and the delete checkbox is
  pre-ticked. This is what mirror mode means; no guard for an empty or unmounted source.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T005 [finding, high] Unreadable checksum lines and empty checksum files report "Errors: 0"

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ChecksumFiles.swift:103, 137-143, 364
- **Basis:** reproduced
- **Detail:** A line with a damaged digest (one hex digit short), an empty file, or a file of junk each yield zero rows
  and "Checksums: Errors: 0" (short.sha256, empty.md5, junk.md5 all gave zero rows and no error). Related, low,
  confirmed by reading: run.contents(of:) silently stops at 64 MiB (ToolRun.swift:150), so entries beyond it are never
  verified.
- **Proposed fix:** Count non-comment lines that do not parse as errors ("cannot read line N") and treat a checksum file
  with no entries as a failure.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T006 [finding, high] SFV entries whose name starts with ; or # are never verified

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ChecksumFiles.swift:18, 112
- **Basis:** reproduced
- **Detail:** Create writes "#notes.txt 1A2B3C4D"; Verify treats the line as a comment. An .sfv for #notes.txt, ;x.txt,
  ok.txt with the first two damaged verified as "CRC32: Errors: 0", one row.
- **Proposed fix:** Do not treat # as a comment in SFV; write ./name for names starting with ;; or refuse such names in
  the SFV format.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T007 [verdict, high] Cancel after Overwrite deletes pre-existing files in Encode/Split

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:172; Sources/Plugins/FileTools/Transcoding.swift:228;
  Sources/Plugins/FileTools/SplitCombine.swift:96; Sources/Plugins/FileTools/SplitCombine.swift:122;
  Sources/Plugins/FileTools/ToolRun.swift:186-191
- **Basis:** CONFIRMED (ran)
- **Detail:** The list of written files holds the final name, still the old file while the new one is in a temporary;
  cleanup deletes every name in the list. With existing data.b64 and data.001, answering Overwrite and cancelling during
  the read left the folder empty for both Encode and Split. A cancel before the writer opens leaves the old file alone.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T008 [finding, high] A missing "end" in UUE/XXE is accepted: a multi-part set with a missing last part yields a short file and success

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:312
- **Basis:** reproduced
- **Detail:**
- **Proposed fix:** Report "incomplete or damaged" and keep or flag the output.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T009 [verdict, high] Decode accepts UUE with missing end

**Outcome:** duplicate of T008 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:312
- **Basis:** CONFIRMED (ran)
- **Detail:** 315 of 450 bytes accepted; finish() closes whatever is open.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T010 [finding, high] URL-safe Base64 decode is cut at "--" (taken for a MIME boundary) and reports success with a truncated file

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:387
- **Basis:** reproduced
- **Detail:** The alphabet accepts - and _, but a line or 64 K piece starting with -- is taken for a MIME boundary. A
  file starting "----" decoded to 0 bytes; a one-line file whose second 64 K piece starts with -- decoded to 49,152 of
  98,604 bytes. For random data about 1 in 4,096 per piece.
- **Proposed fix:** Only treat -- as a boundary when the body came from MIME headers.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T011 [verdict, high] Decode silently truncates: URL-safe Base64 with '--' line

**Outcome:** duplicate of T010 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:387; Sources/Plugins/FileTools/Transcoding.swift:276-278
- **Basis:** CONFIRMED (ran)
- **Detail:** A line starting '--' ends the file though '-' is a valid digit. Decoded 57 of 171 bytes, no error;
  standard alphabet gave 171.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T012 [finding, high] Damaged UUE/XXE lines are dropped silently (855 of 900 bytes written, no error); the sum -r/size trailer is never checked

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:420
- **Basis:** reproduced
- **Detail:**
- **Proposed fix:** Report "incomplete or damaged" and keep or flag the output.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T013 [verdict, high] Decode accepts UUE with a dropped line

**Outcome:** duplicate of T012 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:420
- **Basis:** CONFIRMED (ran)
- **Detail:** 405 of 450 bytes, no error.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T014 [finding, high] yEnc size= and crc32= are never checked: a truncated body with a wrong CRC decoded to 9 of 16 bytes with no error

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:422
- **Basis:** reproduced
- **Detail:**
- **Proposed fix:** Report "incomplete or damaged" and keep or flag the output.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T015 [verdict, high] Decode accepts yEnc with wrong size and crc

**Outcome:** duplicate of T014 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:422
- **Basis:** CONFIRMED (ran)
- **Detail:** A body with =yend size=999999 crc32=deadbeef was accepted.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T016 [finding, high] Decode appends unrelated numbered sibling files (photo1.b64 + photo2.b64) into one output

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:557-565
- **Basis:** reproduced
- **Detail:** photo1.b64 and photo2.b64, both plain base64 output without padding, decoded to one 6,000-byte file
  (photo1 + photo2). A crafted file can pull numbered siblings into the output the same way.
- **Proposed fix:** Only continue into further parts for bodies that began with a header, or when the first part ends on
  a full line.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T017 [verdict, high] Decode concatenates unpadded numbered neighbours

**Outcome:** duplicate of T016 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:557-565; Sources/Plugins/FileTools/Transcoding.swift:536-548
- **Basis:** CONFIRMED (ran)
- **Detail:** Decoding IMG_0001.b64 alone wrote 'first file!!SECOND, unrelated!', pulling in IMG_0002.b64;
  startsFreshFile only recognises headers. Padded control stopped correctly.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T018 [finding, medium] Compare recomputes on main when both files total under 20,000 lines (est. 0.3-1 s per option change, edit, copy, undo or resync)

**Outcome:** fixed — see `status/tools.md`

- **Where:** CompareContent/CompareSession.swift:175-177; CompareContent/CompareLoader.swift:98
- **Basis:** read (path confirmed, time estimated)
- **Detail:** CompareSession.recompute runs CompareLoader.text inline when both files total under 20,000 lines; the diff
  is then exact (Myers.exactBelow = 20,000), and it calls Parallel.map from main (CompareLoader.swift:98). Trigger: two
  unrelated 10k-line files, on every option checkbox, cell edit, copy, undo or resync. Estimated 0.3-1 s; more with long
  lines, since up to 128 MB is normalised. Code path confirmed, time estimated.
- **Proposed fix:** Always go to the background, or gate on bytes and elapsed time.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### T019 [finding, medium] Compare cells lay out whole lines, so multi-megabyte lines take seconds on main

**Outcome:** fixed — see `status/tools.md`

- **Where:** CompareContent/CompareWindowController.swift:497-527; CompareContent/TextDiff.swift:203
- **Basis:** inferred (plausible)
- **Detail:** viewFor builds an attributed string of the entire line, and TextDiff.inline copies both whole lines to
  UTF-16 before truncating to 4,096. Trigger: a file of up to 128 MB with multi-megabyte lines (minified JSON); layout
  of one such cell takes seconds. Reported severity medium/high, scaling, plausible.
- **Proposed fix:** Truncate the displayed text to a few thousand characters and take a prefix before Array(utf16).
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### T020 [finding, medium] Sync window with 1M rows: rebuild, plan() and selectedRows do O(rows) work on main

**Outcome:** fixed — see `status/tools.md`

- **Where:** DirectorySync/SyncSession.swift:209-238; DirectorySync/SyncSession.swift:354;
  DirectorySync/SyncPlan.swift:32-52; DirectorySync/SyncWindowController.swift:345
- **Basis:** read (reported as confirmed; times estimated)
- **Detail:** rebuild() (SyncSession.swift:209-238) runs on every Show toggle, header click and finish: a dictionary
  grouped by directory string, an optional sort, positions, and SyncSummary(rows). Estimated 0.2-0.5 s, followed by
  reloadData. synchronize() -> plan() (:354, SyncPlan.swift:32-52) copies all visible rows and builds the plan with a
  small array allocation per row; estimated 0.3-1 s before the dialog appears. selectedRows
  (SyncWindowController.swift:345) is rebuilt on every key press in the table.
- **Proposed fix:** Cache per-directory groups and summary counts, build the plan in the background, compute
  selectedRows only in the branches that use it.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### T021 [finding, medium] Pause does not pause parallel checksum jobs: ToolRun.advance holds reportLock across a blocking monitor.report

**Outcome:** fixed — see `status/tools.md`

- **Where:** FileTools/ToolRun.swift:99-105; AFMShell/Interaction/ProgressJobService.swift:172-178;
  AFMShell/Interaction/ProgressJobService.swift:207; FileTools/ChecksumFiles.swift:216;
  FileTools/FileToolsPlugin.swift:125; FileProperties/SpaceCalculator.swift:46-53
- **Basis:** read
- **Detail:** Medium-low. ToolRun.advance holds reportLock across monitor.report, which enters PauseGate.passWhenOpen
  and blocks while paused. Every other hashing thread (ChecksumFiles.swift:216, Parallel pool threads) takes the
  non-forced path where reportLock.try() fails and it returns and keeps hashing. One thread pauses and the rest finish
  the job; the job thread then blocks at the forced advance (FileToolsPlugin.swift:125). ProgressMeter
  (SpaceCalculator.swift:46-53) holds its lock across the report so there every thread stops; the two are inconsistent.
- **Proposed fix:** Call gate.passWhenOpen from every thread, outside reportLock.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T022 [finding, medium] P9: Compare diff runs on main below 20,000 lines on each option change (est. 0.3-1 s); cells lay out whole multi-megabyte lines

**Outcome:** duplicate of T018 — see `status/tools.md`

- **Where:** Plugins/CompareContent/CompareSession.swift:175-177;
  Plugins/CompareContent/CompareWindowController.swift:497-527
- **Basis:** inferred
- **Detail:** Fork-reported.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### T023 [finding, medium] P7: Sync window at 1M rows: rebuild() on each Show toggle 0.2-0.5 s; plan() 0.3-1 s

**Outcome:** duplicate of T020 — see `status/tools.md`

- **Where:** Plugins/DirectorySync/SyncSession.swift:209-238; Plugins/DirectorySync/SyncSession.swift:354
- **Basis:** measured
- **Detail:** Fork-reported.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### T024 [finding, medium] Cancellation not wired through in Viewer/FileProperties: FolderSummary, SpaceCalculator and AttributeChange list without the flag; CommentStore waiters have no timeout

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** Plugins/Viewer/Model/FolderSummary.swift:25; Plugins/FileProperties/SpaceCalculator.swift:95;
  Plugins/FileProperties/AttributeChange.swift:298; Plugins/FileProperties/Descript.swift:193
- **Basis:** read (reviewer)
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### T025 [finding, medium] The "output equals source" guards use isSameLocation, a plain string compare, missing case variants (X.CRC vs X.crc), symlinked directories (/tmp vs /private/tmp) and hard links; with the Overwrite cleanup the source can be deleted

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** Sources/AFMKernel/FileSystem/FileItem.swift:103
- **Basis:** read
- **Detail:** Part of finding 14.
- **Proposed fix:** Compare by device/inode for local files.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T026 [finding, medium] Unsaved Compare edits are lost on quit

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** Sources/Plugins/CompareContent/CompareContentPlugin.swift:73-76; Sources/AFMShell/App/Shell.swift:103
- **Basis:** read
- **Detail:** stop() calls close(), which bypasses windowShouldClose. Shell.swift:103 only asks the job service, so
  Cmd+Q with edited files discards them silently. Data loss.
- **Proposed fix:** Have the plugin veto or prompt on termination.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T027 [finding, medium] Private files are world-readable while being saved or copied

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareLoader.swift:216-221;
  Sources/Plugins/DirectorySync/SyncPlan.swift:358-370; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:359
- **Basis:** read
- **Detail:** Local write opens with 0o644; permissions are applied only in close(attributes:). Saving a 0600 file
  writes its full content to .name.afm-save readable by others first. Same for streamed sync copies. Security.
- **Proposed fix:** Create with 0600 and widen at close.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T028 [finding, medium] Save fallback can delete both the original and the new content

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareLoader.swift:223-232
- **Basis:** inferred
- **Detail:** If move(replacing: true) fails the code does remove(url) then move(temporary, to: url); if that second
  move fails the outer catch removes the temporary as well. Trigger: a provider that cannot rename over an existing file
  (typical SFTP/FTP) plus a dropped connection or error between the two steps. Plausible.
- **Proposed fix:** Move the original aside as SyncExecutor does, and never delete the temporary once the original is
  gone.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T029 [finding, medium] A cancelled Compare can leave a stale diff in phase .ready, so copy(rows:) traps or copies wrong lines

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** Sources/Plugins/CompareContent/CompareSession.swift:132-141, 433-447, 465-482
- **Basis:** inferred
- **Detail:** Trigger: edit a file of 20,000+ lines (content becomes new documents plus old diff, background recompute
  starts), press Compare (supersedes the recompute), press Esc. "What was shown before stays" leaves new documents with
  old row indexes. copy(rows:) then indexes source.lines[$0] and target.lines[range] unchecked: it traps, or copies the
  wrong lines, which can then be saved. Plausible.
- **Proposed fix:** Re-run recompute() when a compare is cancelled over edited content, or block editing until the diff
  is current.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T030 [finding, medium] Main-thread stall: inline recompute under 20,000 lines runs synchronously on every edit and option toggle

**Outcome:** duplicate of T018 — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareSession.swift:175-177
- **Basis:** measured
- **Detail:** 2 x 9,999 lines with repeated lines took 210-620 ms. Measured, release build.
- **Proposed fix:** Lower the threshold to about 2,000 lines or always go to the background.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T031 [finding, medium] Main-thread stall: within-line highlight costs about 77 ms per changed row for long differing lines

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareSession.swift:313; Sources/Plugins/CompareContent/TextDiff.swift:202
- **Basis:** measured
- **Detail:** About 77 ms per changed row for two 4,096-unit lines with little in common. A screenful of long differing
  lines (minified JSON, base64) is seconds on first draw and stutter while scrolling. Measured, release build.
- **Proposed fix:** Compute off-thread and reload the row, or cap the effort.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T032 [verdict, medium] Myers cost limit inflates diffs for block moves

**Outcome:** duplicate of T003 — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/Myers.swift:77; Sources/Plugins/CompareContent/Myers.swift:178-188;
  Sources/Plugins/CompareContent/TextDiff.swift:134
- **Basis:** CONFIRMED (ran) for block moves; scattered edits not affected
- **Detail:** Limit is max(256, sqrt(size)) from 20,000 elements; splits at furthest forward point; TextDiff passes no
  limit. 30,000 lines: 400-line block moved with 2,000 distinct lines: default 58,216 lines in 892 blocks 0.38 s vs
  shortest 800 in 2 blocks 0.02 s; 3,000-line block moved with 40 distinct lines: 27,104 vs 6,000; 600 inserted and 600
  deleted elsewhere: 5,964 vs 1,200. Not inflated: random scattered edits up to 60,000 lines, rewritten section,
  insertion at front (ratio 1.00-1.01). All results still correct diffs.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T033 [verdict, medium] DirectorySync: unreadable left side claimed to give false rows

**Outcome:** refuted — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncComparison.swift:117-119;
  Sources/Plugins/DirectorySync/SyncComparison.swift:134
- **Basis:** REFUTED (ran)
- **Detail:** A mode-000 or missing left side gives no rows and one read error; an unreadable subfolder is left out.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T034 [finding, medium] Mirror mode has no guard against an empty or unmounted left side

**Outcome:** duplicate of T004 — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncComparison.swift:131-170;
  Sources/Plugins/DirectorySync/SyncSession.swift:362-383
- **Basis:** read
- **Detail:** A root that fails to list is handled correctly (no rows, error shown). A root that lists as empty
  (leftover mount point, empty share) makes every right file .rightOnly, proposed as deleteRight with the box
  pre-checked. Deletion is direct where there is no Trash. Data loss.
- **Proposed fix:** When one root is empty and the other is not in asymmetric mode, ask explicitly, name the directory
  in the delete line, and default the box off.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T035 [finding, medium] Case-colliding names are paired as "left only", risking replacement of a file on a case-insensitive side

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncComparison.swift:250-283
- **Basis:** reproduced
- **Detail:** Left {a.txt, A.txt} against right {a.txt} gives A.txt <-> - as .leftOnly. Copying to a case-insensitive
  right replaces a.txt; the next sync flips back. With three names folding alike, two become one-sided. With Confirm
  overwrites off or after "Overwrite All" it is silent. Data loss.
- **Proposed fix:** Mark a leftover as excluded when its folded name equals a name already used on the other side.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T036 [verdict, medium] Archive eviction race: weaker variant in DirectorySync holds

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift:272; Sources/Plugins/DirectorySync/SyncPlan.swift:358;
  Sources/Plugins/Archives/ArchiveFileSystem.swift:184; Sources/Plugins/Archives/ArchiveFileSystem.swift:197
- **Basis:** CONFIRMED (read)
- **Detail:** Sync writes a new file under its final name; commit succeeds as a no-op; data exists only in the orphan
  until its timer fires; if the app quits first flushAll skips orphans and store.close() deletes the spool. Sync does
  not delete the source.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### T037 [finding, medium] Cancel during a sync copy leaves a stray temporary

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift:278-280, 347
- **Basis:** reproduced
- **Detail:** When the same-volume copy to the temporary completes and the flag is set, transfer throws Cancelled
  outside the do that removes the temporary. Result: [".f.bin.afm-sync", "f.bin"] left in the target.
- **Proposed fix:** Wrap transfer in the cleanup.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T038 [verdict, medium] DirectorySync commit failures never shown

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift:316-330;
  Sources/Plugins/DirectorySync/SyncSession.swift:430-440
- **Basis:** CONFIRMED (read)
- **Detail:** SyncPlan records them in outcome.errors; SyncSession.finished reads only changedDirectories. Errors after
  'Skip All' get no summary either.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T039 [finding, medium] The sync executor ignores timeOffsetHours

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift:385-394
- **Basis:** read
- **Detail:** adjustDate sets the target to the source date (or the source to the target date) with no offset, while
  classify adds the offset. With dT != 0 every copied pair shows as different again at the next compare.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T040 [finding, medium] A listing cut short by cancel is trusted as an empty folder, so a non-empty folder may be removed or trashed

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift:401, 420
- **Basis:** reproduced
- **Detail:** The local list returns [] without throwing once the flag is set. perform(deletion) then went on to remove
  a non-empty folder; only rmdir refusing saved it ("Directory not empty"). With Trash on, trashItem would move the
  whole folder including files the user chose to keep. removeEmptyDirectories has the same pattern. Window is narrow
  (cancel between the step check and the first listing buffer).
- **Proposed fix:** Re-check the flag after every list before acting on the result.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T041 [finding, medium] Main-thread stall: sync list rebuild/plan/sort at 1M rows

**Outcome:** duplicate of T020 — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncSession.swift:209-251
- **Basis:** measured
- **Detail:** rebuild() about 385 ms per Show toggle at 1M rows, plan() about 380 ms, sorting 1M rows of one folder by
  size or date 3.7 s. Measured, release build.
- **Proposed fix:** Sort on extracted keys, off the main thread for large lists.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T042 [finding, medium] Sync outcome is never shown; commit failures are silent

**Outcome:** duplicate of T038 — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncSession.swift:430-440; Sources/Plugins/DirectorySync/SyncPlan.swift:195,
  317-331
- **Basis:** read
- **Detail:** outcome.errors, skipped and wasCancelled are never read. A failed commit on a deferred-write destination
  stops the deletions but tells the user nothing; the result of the final commitWrites() is discarded.
- **Proposed fix:** Show a summary when there were errors or a commit failed.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T043 [finding, medium] clear() resets the sync phase while a comparison or sync job is running

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncSession.swift:97-107, 120-127, 470-481
- **Basis:** read
- **Detail:** adopt() (command is runsDuringJobs: true) and loadSet() (the star menu is always live) call clear(), which
  sets phase = .idle without cancelling running. During a sync job Compare and Synchronize become available again, a
  comparison runs over trees being modified, and a second plan is queued. During a comparison the old one keeps running
  uncancelled; if the user does not start a new one its rows are installed under the newly shown paths; the Synchronize
  dialog delete lines name no directory.
- **Proposed fix:** Refuse adopt/loadSet while synchronizing; in clear() cancel and nil running.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T044 [verdict, medium] Checksum verify skips comment-looking names and reports success on empty/unparsable files

**Outcome:** duplicate of T005 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ChecksumFiles.swift:112; Sources/Plugins/FileTools/ChecksumFiles.swift:18;
  Sources/Plugins/FileTools/ChecksumFiles.swift:137-143; Sources/Plugins/FileTools/ChecksumFiles.swift:364-365
- **Basis:** CONFIRMED (ran)
- **Detail:** Verify skips lines starting with ; or # while Create writes SFV lines as 'name CRC' unescaped. Create
  produced ';notes.txt D0AB110E' and '#1 hit.txt DC186425'; after damaging both files Verify reported 'CRC32: Errors:
  0', OK: 1. An empty .sfv, binary garbage .md5, prose .sha256 and invalid UTF-16 all report 'Errors: 0', OK: 0.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T045 [finding, medium] Cleanup after Overwrite + cancel deletes files that were there before; same-location guards miss case variants, symlinked dirs and hard links

**Outcome:** duplicate of T007 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/SplitCombine.swift:96, 122; Sources/Plugins/FileTools/Transcoding.swift:172, 228;
  Sources/Plugins/FileTools/ToolRun.swift:187; Sources/AFMKernel/FileSystem/FileItem.swift:103
- **Basis:** reproduced
- **Detail:** written holds final URLs, so on failure the cleanup removes the old file that the temp-then-rename scheme
  deliberately kept. Split into a folder holding old data.001/data.002, Overwrite all, cancel: folder ends with only old
  data.002 (test for finished parts; reading for the in-progress part). The "output equals source" guards use
  isSameLocation, a plain string compare; they miss case variants (X.CRC vs X.crc), symlinked directories (/tmp vs
  /private/tmp) and hard links. Combined with the cleanup the source can be deleted after an Overwrite confirmation.
  Data loss.
- **Proposed fix:** Track which outputs replaced existing files and only remove what the run created; compare by
  device/inode for local files.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T046 [finding, low] CompareSession.edit copies the whole lines array on each edit, and 20 undo levels each keep a full copy

**Outcome:** fixed — see `status/tools.md`

- **Where:** CompareContent/CompareSession.swift:432-446
- **Basis:** read (reported as confirmed)
- **Detail:** The undo snapshot shares the array, so each edit copies it. With millions of lines that is about 0.1-0.3 s
  per edit. Reported severity low/medium, scaling, confirmed.
- **Proposed fix:** Store deltas.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### T047 [finding, low] AttributeJob nests concurrentPerform around blocking provider I/O on GCD workers

**Outcome:** fixed — see `status/fileops-p2.md`

- **Where:** FileProperties/AttributeChange.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T048 [finding, low] createChecksums clears the selection without checking the panel still shows the same directory (verify does check)

**Outcome:** fixed — see `status/tools.md`

- **Where:** FileTools/FileToolsPlugin.swift:291; FileTools/FileToolsPlugin.swift:318
- **Basis:** read
- **Detail:** createChecksums clears the selection with no check that the panel still shows the same directory; verify
  does check (:318).
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T049 [finding, low] Checksum completions: createChecksums lacks the directory check that verify has (bug 8); Descriptions have no generation (bug 4)

**Outcome:** fixed — see `status/tools.md`

- **Where:** FileTools/FileToolsPlugin.swift:318; FileTools/FileToolsPlugin.swift:291
- **Basis:** read
- **Detail:**
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T050 [finding, low] BLAKE3 runs concurrentPerform inside nested Parallel.map, oversubscribing CPU

**Outcome:** fixed — see `status/plugins-b-p2.md`

- **Where:** FileTools/Hashes.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T051 [finding, low] Splitter closes its reader twice on error

**Outcome:** duplicate — see `status/plugins-b-p2.md`

- **Where:** FileTools/SplitCombine.swift:120; FileTools/ToolRun.swift:130
- **Basis:** read
- **Detail:** Splitter closes its reader twice on error (SplitCombine.swift:120, after ToolRun.read's defer at
  ToolRun.swift:130).
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T052 [finding, low] Verify completion does report.text and setSelection(names:) O(rows) on main (low to medium for a ~1M-line checksum file)

**Outcome:** fixed — see `status/tools.md`

- **Where:** Plugins/FileTools/FileToolsPlugin.swift:314-318
- **Basis:** read
- **Detail:**
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### T053 [finding, low] Pause does not pause parallel checksum jobs: ToolRun.advance holds reportLock across monitor.report; other threads fail try() and carry on

**Outcome:** duplicate of T021 — see `status/tools.md`

- **Where:** Plugins/FileTools/ToolRun.swift:99-105
- **Basis:** read (reviewer)
- **Detail:** Medium-low; reviewer-reported.
- **Proposed fix:** Every thread passes the gate, outside reportLock.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### T054 [finding, low] Stale Find results: findGeneration is not bumped by recompute, swap, resync or compare, so a result can jump to a row of the old diff (bounds-checked, harmless)

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareSession.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T055 [finding, low] Undo memory: up to 20 snapshots, each edit copying the edited side line array (about 64 MB at 2M lines)

**Outcome:** duplicate of T046 — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareSession.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T056 [finding, low] Close after "Save" can drop newer edits: completion(true) fires even when an edit arrived during the job

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/CompareSession.swift:533
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T057 [finding, low] Within-line ranges can split a surrogate pair or isolate a combining mark (41..<42 in both tests); guarded by upperBound <= length; cosmetic

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/TextDiff.swift
- **Basis:** reproduced
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T058 [finding, low] Compare save is lossy and unchecked: allowLossyConversion turns characters outside Latin-1 into ?; invalid sequences in a BOM-marked file are rewritten as U+FFFD; no check that the file changed on disk since loading; hard links broken by the rename; a file compared with itself is written twice

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/CompareContent/TextDocument.swift:68
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T059 [finding, low] Sort order differs from the system for digit runs above 2^64: localizedStandardCompare wraps; the fast path compares correctly

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/
- **Basis:** measured
- **Detail:** One disagreement in 1.2M fuzzed pairs. Display order only; nothing searches the order.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T060 [finding, low] Streamed (cross-provider) file copies never call copyMetadata

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T061 [finding, low] .name.afm-old is deleted at the start of the next attempt even when a failed restore left it as the only copy of the old file

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncPlan.swift:288
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T062 [finding, low] A cancelled sync comparison is not labelled: rows are valid but partial and Synchronize is enabled

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncSession.swift:184
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T063 [verdict, low] DirectorySync single-item sync errors never shown

**Outcome:** refuted — see `status/tools.md`

- **Where:** Sources/Plugins/DirectorySync/SyncSession.swift:418-423
- **Basis:** REFUTED (read) for single items
- **Detail:** Each failure asks Skip / Skip All / Retry / Cancel.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T064 [finding, low] Names with a line feed produce a checksum file that fails its own verify (notFound); no GNU escaping on write, and the same gap lets a file name inject extra lines

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ChecksumFiles.swift
- **Basis:** reproduced
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T065 [verdict, low] Checksum file with mode 000 reported as OK

**Outcome:** refuted — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ChecksumFiles.swift
- **Basis:** REFUTED (ran) for permission-denied
- **Detail:** A checksum file with mode 000 throws a permission error (the 'unreadable' reading of the claim does not
  hold).
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### T066 [finding, low] Checksum line `<digest> *` yields an entry with an empty name

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ChecksumFiles.swift:133-136
- **Basis:** reproduced
- **Detail:** Reproducer repro/tools/checksum-empty-name.md5.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### T067 [finding, low] BLAKE3 uses the cores poorly on 1 MiB blocks: 706 MB/s against 338 MB/s serial on 16 cores; concurrentPerform fires for subtrees as small as 16 chunks

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Hashes.swift
- **Basis:** measured
- **Detail:**
- **Proposed fix:** Larger read blocks for BLAKE3 would help.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T068 [finding, low] Hashes.swift needs the macOS 26 SDK to compile (SHA3_256 under #available)

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Hashes.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T069 [finding, low] run.contents(of:) silently stops at 64 MiB, so checksum entries beyond it are never verified

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ToolRun.swift:150
- **Basis:** read
- **Detail:** Related to finding 3.
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T070 [finding, low] Pause stops only one hashing thread: the thread holding reportLock blocks in the gate, the others skip via try()

**Outcome:** duplicate of T021 — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/ToolRun.swift:99
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T071 [finding, low] Encode reuses the last part name if the source grew since the panel listed it; the user is asked to overwrite the tool own earlier part

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:169
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T072 [finding, low] Encode traps on a huge "Lines per file" (limit * method.lineLength overflows, e.g. 999999999999999999) and kills the app

**Outcome:** fixed — see `status/tools.md`

- **Where:** Sources/Plugins/FileTools/Transcoding.swift:180
- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T073 [finding, info] var written is written on the job thread and read on main in the completion; only the job-to-completion hop orders them (fragile)

**Outcome:** fixed — see `status/tools.md`

- **Where:** FileTools/FileToolsPlugin.swift:285-288
- **Basis:** read
- **Detail:** Fragile.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T074 [finding, info] A reader and its interrupt token stay open across the main.sync of monitor.ask in SplitCombine and Transcoding

**Outcome:** not a defect — see `status/tools.md`

- **Where:** FileTools/SplitCombine.swift:95; FileTools/Transcoding.swift:495
- **Basis:** read
- **Detail:**
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

## Checked and found sound

### T075 [sound, info] Compare load, large recompute and find are in the background

- **Basis:** read
- **Detail:** Load, large recompute and find are in the background; block(containing:) bisects; the inline cache is
  capped.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### T076 [sound, info] Shared state: ToolRun counters/lines/lastReport under lock with reports serialised by reportLock; ToolRun.overwritesAll, ToolOutput, FolderSink, DecodeMachine job thread only; hasher instances one thread per block; BLAKE3 values buffer disjoint slots; SyncComparison counters/errors NSLock; lastReport in SyncSession.compare only in serialised calls; SyncExecutor fields job thread; CompareLoader.identical NSLock; FileTools.createChecksums written on job thread read in completion. SyncSession and CompareSession are main-thread with stale guards (running === ..., findGeneration, editGeneration) and are NOT sufficient: see findings 8 and 15

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T077 [sound, info] BLAKE3: all 35 official vectors pass, one-shot and streamed, including lengths 3-8 and 127-129; streaming at 1 byte, fixed steps and 50 random chunkings; inputs up to 16 MiB + 1024 identical across parallel, 1 MiB-block and random-chunk paths versus serial

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T078 [sound, info] SHA-3 224/256/384/512 match Python hashlib (empty, abc, 1 MB pattern, rate-boundary lengths); CryptoKit path and Swift fallback agree incl. random chunking; SHA3-224 1 MB matches openssl; rotation counts all 1-62

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T079 [sound, info] CRC32, MD5, SHA-1, SHA-2 match hashlib/zlib (225 digests, 0 bad); Data slices with a non-zero start index handled

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T080 [sound, info] Myers: 400,000 fuzzed cases with limits nil/0/1/2/3/5/8/100 always gave a valid script, shortest when unlimited; debug build with bounds checks never trapped; empty against non-empty is correct

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T081 [sound, info] TextDiff: 32,000 fuzzed cases with anchors, all option combinations and non-ASCII were valid; equal keys always hash equal and every .equal row is re-checked with isSameKey

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T082 [sound, info] Verify logic: no path turns a mismatch into OK; empty digests of uncomputed methods cannot match; cancel throws; unreadable files give readError; result ordering preserved; absolute and ../ names are only read

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T083 [sound, info] Decoders: 300,000 random UUE/XXE lines without a trap; header names cannot leave the target; header modes are ignored (4755 became 644)

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T084 [sound, info] Sync: symlinks never followed or deleted; a failed or cancelled listing of either side drops the folder on both; content read errors give .pending with no action; deletions run after commit, files before folders; canSynchronize and the plan cannot diverge

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T085 [sound, info] Save: symlinks are resolved and the temporary is created with O_EXCL

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T086 [sound, info] myers: segments cover both sequences, equal segments are equal, applying the script to A gives B, shortest result without a limit (checked against LCS reference)

- **Basis:** reproduced
- **Detail:** Cost limits 0-23 and automatic limit on inputs up to about 30k elements; both [Int] and [UInt16] overloads
  run. 9,790 asan / 26,748 rel execs, 0 failures.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T087 [sound, info] textdiff: rows cover both files in order, equal rows pass isSameKey, rebuiltRight gives the right file, blocks match rows, result shortest against LCS on keys

- **Basis:** reproduced
- **Detail:** Anchors (including out-of-range), cost limits and CompareLoader.text width included. 74,049 / 132,924
  execs, 0 failures.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T088 [sound, info] inline: ranges sorted, non-empty, in bounds, unhighlighted remainders equal

- **Basis:** reproduced
- **Detail:** Inputs included surrogate pairs, combining marks, lone surrogates via bridged NSString, lines over 4096
  units, minimumMatch 0-5. 12,290 / 24,061 execs, 0 failures.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T089 [sound, info] loader: TextDocument(data:) detection, decoding, line splitting and data() round trip correct; BinaryDiff matches a naive byte count

- **Basis:** reproduced
- **Detail:** bytesPerLine from -128 to 127. 26,810 / 31,535 execs, 0 failures.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T090 [sound, info] planner: after autoRenamed or skippingConflicts no conflicts remain; simulated steps always find their source, never land on an existing name, and leave every item at its target

- **Basis:** reproduced
- **Detail:** Case folding and NFC/NFD twin names included. 190,768 / 190,955 execs, 0 failures.
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T091 [sound, info] No over-memory cases in any group 7 target; diff and highlight code came through clean

- **Basis:** reproduced
- **Detail:**
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T092 [sound, info] FileTools decode/verify/checksum fuzzing: no crash in 556,778 asan and 416,655 rel executions

- **Basis:** reproduced
- **Detail:** Containment fails in decode and combine (finding 1); one low mismatch (checksum empty name).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### T093 [sound, info] Space and folder sizes completions guarded by model.directory.isSameLocation; location ABA harmless as results are name-keyed

- **Where:** FileProperties/FilePropertiesPlugin.swift:249; FileProperties/FilePropertiesPlugin.swift:275
- **Basis:** read
- **Detail:**
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

### T094 [sound, info] monitor.report call sites are serialized: Actions:560 single job thread; ToolRun.swift:105 by reportLock; SpaceCalculator.swift:53 by meter lock. monitor.ask only at ToolRun.swift:60 via create (:171) on job thread, never from parallel body or main; no in-scope lock held

- **Where:** Viewer/UI/ViewerPane+Actions.swift:560; FileTools/ToolRun.swift:105;
  FileProperties/SpaceCalculator.swift:53; FileTools/ToolRun.swift:60; FileTools/ToolRun.swift:171
- **Basis:** read
- **Detail:** No unserialized concurrent report exists in scope.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open

## Not covered / left behind

### T095 [gap, info] Not covered: sync and rename executors and SyncComparison

- **Basis:** read
- **Detail:** Background; only their main-thread hops were checked.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### T096 [gap, info] Not covered: hotlist entry semantics, Directory Sync planning and Compare save paths; the pure-Swift hash implementations

- **Basis:**
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### T097 [gap, info] BLAKE3 beyond 4 GiB / 2^32 chunks not checked: counter is 64-bit by reading, no reference tool available

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T098 [gap, info] Remote and archive providers behaviour under findings 6, 10 and 12 not reviewed

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T099 [gap, info] AppKit windows were read, not driven: 8M-row tables, sheet/progress interplay and the 1M-row UI measured only at model level

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T100 [gap, info] A real macOS < 26 system not tested: the fallback class was exercised directly on macOS 27

- **Basis:** read
- **Detail:**
- **Source:** reports/17-review-sync-compare-tools-again.md
- **Status:** open

### T101 [gap, info] CompareSession (resync, edit, undo, find) not fuzzed: needs a Kernel and the main queue

- **Basis:** read
- **Detail:**
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T102 [gap, info] CompareLoader.load, identical and replace not fuzzed: file-system plumbing with no parsing beyond what was covered

- **Basis:** read
- **Detail:**
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T103 [gap, info] RenameStore and the file-system parts of RenameRun not fuzzed

- **Basis:** read
- **Detail:**
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T104 [gap, info] Locale and time-zone variants not run: only en_US_POSIX and UTC

- **Basis:** read
- **Detail:**
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T105 [gap, info] The lldb route for line numbers stalled on the trap handler, so lines come from atos

- **Basis:** read
- **Detail:**
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### T106 [gap, info] fileSystems.location(from:relativeTo:) is called on main at FileToolsPlugin.swift:109 and :280; whether it does I/O was not checked

- **Where:** FileTools/FileToolsPlugin.swift:109; FileTools/FileToolsPlugin.swift:280
- **Basis:** read
- **Detail:** Outside the auditor's scope; not checked.
- **Source:** reports/07-viewer-filetools-threading-audit.md
- **Status:** open
