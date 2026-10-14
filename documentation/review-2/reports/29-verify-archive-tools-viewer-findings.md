# Verify archive, tools, viewer findings

Of the 21 claims, 12 are confirmed and 7 are confirmed only in part (1, 3, 12, 13, 15, 17, 21). Claims 4 and 10 are reproduced at the mechanism level only, and nothing is refuted outright.

**Method.** I ran throwaway tests against a scratch copy of the project; the project directory was not touched and the GUI app was never launched. The scratch copy is deleted. The only source change in the copy was one hook between `build` and `install` in `OpenArchive.flush`, used for claim 6. The trapping tests left `swiftpm-testing-helper-2026-10-13-22*.ips` crash reports in `~/Library/Logs/DiagnosticReports`, and may have left a few `afm-tests-*` folders in the temp directory.

Paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources`.

## Viewer

**1. `Segment.thin` — CONFIRMED as a trap; the "never terminates" part is REFUTED. Reproduced.**
- **Evidence:** `Plugins/Viewer/Model/TextRows.swift:223-225`. When a segment has more checkpoints than bytes, `bytes / count` is 0, so `0 * step < 4096` holds forever and `step *= 2` overflows after 62 doublings. The crash report shows "arithmetic overflow" at line 225.
- **Trigger:** one line that starts in a 4 MiB segment and produces more than 4,194,304 checkpoints, i.e. more than about 268 million rows. The reported sizes check out arithmetically: a 300 MB line at width 1, or a 10 GB line under about 37 columns.
- **Reach:** width 1 is settable (`ViewerSettings.swift:78` allows 1…16384). With width left at the window's, the floor is 20 columns (`TextPagerView.swift:296`).
- **Runs:** direct call with 5 checkpoints over 4 bytes traps; `TextRowIndex.build` with 64-byte segments and a 12,288-byte line at width 1 traps. Controls just under the limit return.
- **Consequence:** the app crashes at the end of indexing.

**2. `CharacterBoundaries` on a shrunk file — CONFIRMED. Reproduced.**
- **Evidence:** `Plugins/Viewer/Model/CharacterBoundaries.swift:105-106` and `:65-66` with `:78`. Both index `data` up to the length that was requested, not the length that came back.
- **Trigger:** a text in code page 932/936/949/950, the file truncated after loading, then a search that reaches a chunk past the first (`ViewerSearch.swift:274`).
- **Runs:** with a source that reports 200,000 bytes but returns 50,000, `characterStart` traps at line 106 and `ViewerSearch.find` traps at line 78. Control with the full file returns 150000.
- **Consequence:** crash. Other encodings never reach this code.

**3. Save As onto the viewed file — PARTLY CONFIRMED. Reproduced at source level.**
- **Evidence:** `Plugins/Viewer/UI/ViewerPane+Actions.swift:551`. `createFile(atPath:contents:nil)` replaces the file with an empty one before any read, but it does so with a new inode.
- **Normal case:** `ProviderByteSource` usually holds an idle reader on the old inode (`ByteSource.swift:166-172`). With that reader open, a 5,000,000-byte file was saved onto itself intact.
- **Failing case:** after `source.close()`, the same save left 0 bytes and no error, because `guard !block.isEmpty else { break }` (line 557) returns success.
- **Unproven:** the natural trigger, where all idle readers are checked out by a running parallel index build so the save opens a fresh reader on the empty file. That is from reading only.

**4. Measuring loop cannot be cancelled — CONFIRMED by reading; reproduced in one run only.**
- **Evidence:** `Plugins/Viewer/Model/ByteSource.swift:119-124` has no flag check inside the loop. It relies on `reader.interrupt()`, and the local reader does not implement it (`Plugins/LocalFileSystem/LocalFileSystem.swift:338-349`; the default at `AFMKernel/FileSystem/FileSystemProvider.swift:111-113` does nothing).
- **Why symlinks hit it:** `LocalFileSystem.item(at:)` uses `lstat` and reports size 0 for anything that is not a regular file (`:327`). Measured: a symlink to a 5,000-byte file has size 0.
- **Run:** opening a symlink to `/dev/zero` and cancelling at 0.3 s was still reading at 5.3 s. This run had no control with a regular file or a larger timeout, so it shows the loop outliving the cancel, not how long it would run.
- **Consequence:** from the code, a symlink to a large file is read to the end before anything shows, and an endless device is never finished.

## Archives

**5. `flushAll` single pass — CONFIRMED. Reproduced.**
- **Evidence:** `Plugins/Archives/ArchiveFileSystem.swift:182-188` iterates a dictionary once. Flushing the inner archive uploads into the outer one (`OpenArchive.swift:1356-1384`), which makes the outer pending again. `ArchivesPlugin.stop()` (`:96-111`) calls it once and then `store.close()`.
- **Run:** with a 600 KB inner archive, the change was lost in 5 of the 10 runs. With a tiny inner archive it was lost in 0 of 10, because the immediate-write path covers it.
- **Consequence:** an edit inside a nested ZIP is dropped at quit with no message. The project's own test calls `flushAll()` twice.
- **Not run:** the server-side variant; it is the same upload path.

**6. Deletion during a flush — CONFIRMED for one case, REFUTED for the other. Reproduced with the hook.**
- **Evidence:** `OpenArchive.swift:789-799` (`take` counts a removal only when `record.isInArchive`), `:1115-1134`, `:1287-1304`.
- **Lost:** a member the running flush is writing for the first time. After a further `flushAll` the file still listed `t/new.txt`, with the member gone from memory and nothing pending. It reappears on reopening.
- **Not lost:** deleting a member that was already in the archive during a flush was persisted by the next flush.

**7. Pack into a server-side or nested ZIP — CONFIRMED. Reproduced.**
- **Evidence:** `Plugins/Archives/Packer.swift:488-514`, reached from `:304-305`.
- **Encrypt ignored:** packing with `password = "pw"` into `mem:/store/s.zip` gave members readable with `unzip -p` and no password. The local control was encrypted.
- **Old member removed first:** cancelling while a replacement source was being read left the server ZIP empty. The catch block removes the path and flushes.
- **Further, from reading:** `open.write(path)` and `blocks(of:)` at `:498-499` sit outside the `do`. A source that fails to open leaves the old member removed and the writer never closed.

**8. No fsync; symlinked archive replaced — CONFIRMED. Symlink reproduced; fsync from reading only.**
- **Evidence:** there is no `fsync`, `F_FULLFSYNC` or `synchronize` call anywhere in `Plugins/Archives`. The renames are at `OpenArchive.swift:1273` and `Packer.swift:358, 423`. No path is resolved through symlinks.
- **Run:** after an in-archive edit through `link.zip → real/real.zip`, `link.zip` was a regular file holding the change and `real.zip` was unchanged. Packing into the link did the same.
- **Not reproduced:** the power-loss consequence.

**9. Deep member path — CONFIRMED as quadratic memory. Reproduced at small scale.**
- **Evidence:** `Plugins/Archives/ArchiveTree.swift:132-157` creates one implicit entry per ancestor, each with its own full-path string. There is no depth limit.
- **Measured:** depth 2000 → +6 MB, 4000 → +14 MB, 8000 → +56 MB. A real 32 KB ZIP with one member 8000 folders deep cost +77 MB on open.
- **Extrapolated, not run:** a 65,535-byte ZIP name allows about 32,767 levels, roughly 1 GB per such member. TAR long names are not bounded by the format at all (`Tar.swift:253-260`).

## FindFiles / Selection / MultiRename

**10. No time limit on user regular expressions — CONFIRMED as a mechanism; each run stopped at 25 characters and about 1.3 s.**
- **Selection:** `Plugins/Selection/SelectionMask.swift:103`; the plugin states it runs on the main thread (`SelectionPlugin.swift:167`). Mask `<(a+)+$` on a name of 19/21/23/25 characters took 0.02/0.08/0.32/1.31 s, about four times per two characters.
- **Multi-Rename:** `Plugins/MultiRename/RenameRules.swift:163-166`, run inside the job at `MultiRenameSession.swift:356-358`. Same curve (1.27 s at 25 characters). Jobs run one after another (`AFMShell/Interaction/ProgressJobService.swift:69-108`), and the cancel flag is only checked between items.
- **FindFiles:** `Plugins/FindFiles/TextPattern.swift:344`; the flag is checked once per 1 MB block (`:348`). Cancelled at 0.20 s, the call returned at 1.20 s.
- **Not reproduced:** an actual frozen window, a blocked job queue, or threads still spinning long after cancel. Those follow from the curve.

**11. Long Find text overflows the stack — CONFIRMED, and at a lower threshold than reported. Reproduced.**
- **Evidence:** `Plugins/FindFiles/TextPattern.swift:121-132` recurses once per matched character. Search workers are plain `Thread`s with the default 512 KB stack (`FileSearch.swift:461`).
- **Runs:** `TextPattern.swift` compiled alone with `-O`: 5,000 characters found, 6,000 and above crash with a bus error. In a debug build 2,000 already crashes.
- **Conditions:** case-insensitive (the default) or whole-words, and a file that contains the text or a long prefix of it. Case-sensitive goes through `memmem` and is fine at 20,000.

**12. Multi-Rename — first half CONFIRMED at the preview level; Undo half REFUTED as a defect.**
- **Nested folders:** `Plugins/MultiRename/RenameRun.swift:17-19` strips the path from an item name only for `file:` URLs, and `:132-139` treats a slash in the new name as a subfolder. Branch view names items by path on every file system (`Plugins/VirtualFolders/BranchWalker.swift:146-149`).
- **Run:** item `mem:///root/sub/a.txt` named `sub/a.txt`, replacing a→b, gave status ready and target `mem:///root/sub/sub/b.txt`. The local control gave `a.txt`. I did not run the rename itself.
- **Undo:** the history is a deliberate 20-run stack (`RenameStore.swift:132-162`), each Undo asks first with the list of pairs (`MultiRenameSession.swift:440-444`), and the spec says `MultiRenameUndoHistoryLen` "sets how many operations can be undone". The button is disabled while a run is in progress.

**13. Numeric traps — CONFIRMED. One reproduced, one from reading.**
- **`SearchCriteria.swift:38`:** `-7 * count`. `Age(Int.max, .weeks).cutoff` trapped. Reaching it needs about 19 digits in "older than N weeks".
- **`SearchForm.swift:364`:** `String(Int64(size))` for a whole-number Double at or above 2^63, or infinity. Reached when a saved search with size `1e19` or `inf` is loaded (`:315`, `:429`). Not run. `SizeRule.bytes` itself is clamped (`SearchCriteria.swift:85-89`).

## Sync / Compare / FileTools

**14. Myers cost limit — CONFIRMED for block moves; scattered edits are not affected. Reproduced.**
- **Evidence:** `Plugins/CompareContent/Myers.swift:77` sets the limit to `max(256, √size)` from 20,000 elements; `:178-188` splits at the furthest forward point. `TextDiff.swift:134` passes no limit.
- **Inflated (30,000 lines):**

| Scenario | Default diff | Shortest diff |
|---|---|---|
| 400-line block moved, 2,000 distinct lines | 58,216 lines in 892 blocks, 0.38 s | 800 in 2 blocks, 0.02 s |
| 3,000-line block moved, 40 distinct lines | 27,104 | 6,000 |
| 600 inserted and 600 deleted elsewhere | 5,964 | 1,200 |

- **Not inflated:** random scattered edits up to 60,000 lines, a rewritten section, an insertion at the front (ratio 1.00–1.01).
- All results were still correct diffs.

**15. Checksum files — CONFIRMED, except the permission-denied reading of "unreadable". Reproduced.**
- **Evidence:** `Plugins/FileTools/ChecksumFiles.swift:112` skips lines starting with `;` or `#`, while `:18` writes SFV lines as `name CRC` unescaped.
- **Run:** Create produced `;notes.txt D0AB110E` and `#1 hit.txt DC186425`. After damaging both files, Verify reported "CRC32: Errors: 0", OK: 1.
- **Empty and unparsable files:** an empty `.sfv`, binary garbage `.md5`, prose `.sha256` and invalid UTF-16 all report "Errors: 0", OK: 0 (`:137-143`, `:364-365`).
- **Refuted part:** a checksum file with mode 000 throws a permission error.

**16. Decode silently truncates or concatenates — CONFIRMED on all five points. Reproduced.**
- **URL-safe Base64 with `--`:** a line starting `--` ends the file (`Plugins/FileTools/Transcoding.swift:387`, while `-` is a valid digit at `:276-278`). Decoded 57 of 171 bytes, no error; the standard alphabet gave 171.
- **Unpadded numbered neighbours:** decoding `IMG_0001.b64` alone wrote "first file!!SECOND, unrelated!", pulling in `IMG_0002.b64` (`:557-565`; `startsFreshFile` at `:536-548` only recognises headers). The padded control stopped correctly.
- **Dropped UUE line:** 405 of 450 bytes, no error (`:420`).
- **Missing `end`:** 315 of 450 bytes, accepted (`:312`, `finish()` closes whatever is open).
- **yEnc:** a body with `=yend size=999999 crc32=deadbeef` was accepted (`:422`).

**17. DirectorySync — PARTLY CONFIRMED.**
- **Unreadable left: REFUTED. Reproduced.** A mode-000 or missing left side gives no rows and one read error; an unreadable subfolder is left out (`Plugins/DirectorySync/SyncComparison.swift:117-119`, `:134`).
- **Empty left: CONFIRMED as behaviour. Reproduced.** In asymmetric mode all four right-side files came out `rightOnly → deleteRight` (`SyncModel.swift:139`), and the delete checkbox is pre-ticked (`SyncSession.swift:377`). This is what mirror mode means; there is no guard for an empty or unmounted source.
- **Sync errors never shown: REFUTED for single items, from reading.** Each failure asks Skip / Skip All / Retry / Cancel (`SyncSession.swift:418-423`).
- **Commit failures never shown: CONFIRMED, from reading.** `SyncPlan.swift:316-330` records them in `outcome.errors`, and `SyncSession.finished` (`:430-440`) reads only `changedDirectories`. Errors after "Skip All" get no summary either.

**18. Cancel after Overwrite deletes pre-existing files — CONFIRMED. Reproduced.**
- **Evidence:** `Plugins/FileTools/Transcoding.swift:172` and `:228`, `SplitCombine.swift:96` and `:122`. The list of written files holds the final name, which is still the old file while the new one is in a temporary (`ToolRun.swift:186-191`). Cleanup deletes every name in the list.
- **Run:** with existing `data.b64` and `data.001`, answering Overwrite and cancelling during the read left the folder empty for both Encode and Split.
- **Timing matters:** a cancel that lands before the writer opens leaves the old file alone.

## Shell

**19. Read-ahead loop — CONFIRMED. Reproduced at small scale.**
- **Evidence:** `AFMShell/Panel/ReadAhead.swift:133-140` restarts the dwell after every reading, and `:105` skips only when the cache has the folder. The cache refuses folders over `maxEntries` (`AFMKernel/Panels/ListingCache.swift:142-145`, 300,000 at `:31`).
- **Run:** with the limit set to 30, a 20-entry remote folder was listed once in 4 s; a 50-entry one was listed 9 times and never remembered.
- **Consequence:** a remote folder over 300,000 entries is listed in full again and again for as long as the cursor rests on it.

**20. Reload posts `.locationChanged`; rename cancelled by redraw — CONFIRMED. Events and rename reproduced; the Quick View dismissal from reading.**
- **Events:** a quiet reload of an unchanged folder, and `reloadChangedPanels`, each posted `locationChanged` (`AFMShell/Panel/PanelViewController.swift:857`, `Window/PanelCoordinator.swift:190-193`).
- **Quick View:** it dismisses on that event for the covered panel (`Plugins/Viewer/UI/QuickViewPanel.swift:46-48`). `MainWindowController.swift:224-227` reloads all panels whenever the app becomes active, so switching away and back closes it.
- **Rename:** `redraw()` cancels unconditionally (`PanelViewController.swift:427-429`). Quiet reloads are held back (`:814`) and the rename survived one. It was cancelled by `kernel.panels.refresh`, which reloads non-quietly (`AFMKernel/Panels/PanelHandle.swift:71-77`), and by a sort change. A selection change did not cancel it.

**21. Mutually calling user commands — PARTLY CONFIRMED. Reproduced.**
- **Direct case REFUTED:** `em_a = "em_sayA,em_b"`, `em_b = "em_sayB,em_a"` stops with "a calls itself" (`Plugins/Configuration/CommandRunner.swift:111-114`).
- **With a wait in between CONFIRMED:** the guard's `active` list is popped whenever `perform` returns for a `cm_wait` or a waited program (`:158-159`, `:163-167`, `:194-199`). `em_c = "em_sayC,cm_wait 20,em_d"` and the mirror ran 42 lines after 1 s and 83 after 2 s. It is an endless loop, not stack recursion.
- **Not run:** the same through a waited external program with real launches.

## New defects noticed

- **Save As reports success on a short read.** `ViewerPane+Actions.swift:557` breaks on an empty block and returns nil, so any read that ends early produces a truncated copy with no error. Seen in the claim 3 run.
- **Every local symlink has size 0** (`LocalFileSystem.swift:327`), so the viewer reads the whole target once just to measure it before showing anything.
- **Packer leaks an open archive writer** when the source cannot be opened (`Packer.swift:498-499`). From reading only.
