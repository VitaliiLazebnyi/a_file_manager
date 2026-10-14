# Review sync, compare, tools again

# Second-round review: DirectorySync, CompareContent, FileTools

All 19 files in scope were read in full. The hash code is clean against every vector I ran; the serious problems are in the diff heuristic, checksum verification, the decoders, and the sync/save edge paths. No project file was modified; experiments live under `/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/sync/` (`h/`, `bench/`, `ord/`, `pkg/`).

Paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/`. "Confirmed (test)" means I ran it; "confirmed (reading)" means the code path is unambiguous but was not executed.

## Findings

### High

**1. The cost-limited Myers split produces grossly wrong diffs on large files** — correctness — `CompareContent/Myers.swift:77, 178-188` — confirmed (test)
- **What:** when a split hits `limit` (256 for typical sizes), only the furthest point of the forward walk is used. If the files are shifted by more than `limit` lines that also occur on the other side, each split lands on a random diagonal and the rest of the file is consumed as "different".
- **Trigger:** files of 20,000+ lines after filtering, with a large moved or deleted block plus scattered edits. Seeded runs, 20/20 seeds each:
  - 30k-line source-like file, 300 edits, 2,000-line block deleted: 25,894 changed lines shown, shortest script is 2,548.
  - 400-line block moved plus 100 edits: 46,806 shown, shortest is 994.
  - 500 edits plus a 500-line block deleted (random values): 47,224 shown, shortest is 1,458 (17/20 seeds).
- The script is always valid (every row accounted for), but it shows nearly identical files as almost entirely different.
- **Fix:** at the limit, choose the split from whichever walk progressed further, or the diagonal with the longest recent snake as GNU diff does. Better, anchor on lines unique to both sides (patience/histogram) before falling back to Myers.

**2. SFV entries whose name starts with `;` or `#` are never verified** — correctness — `FileTools/ChecksumFiles.swift:18, 112` — confirmed (test)
- **What:** Create writes `#notes.txt 1A2B3C4D`; Verify treats the line as a comment.
- **Trigger:** I created an `.sfv` for `#notes.txt`, `;x.txt`, `ok.txt`, damaged the first two, and verified. Result: `CRC32: Errors: 0`, one row.
- **Fix:** do not treat `#` as a comment in SFV; write `./name` for names starting with `;`; or refuse such names in the SFV format.

**3. Unreadable checksum lines and empty checksum files report "Errors: 0"** — correctness — `FileTools/ChecksumFiles.swift:103, 137-143, 364` — confirmed (test)
- **What:** a line with a damaged digest (one hex digit short), an empty file, or a file of junk each yield zero rows and `Checksums: Errors: 0`.
- **Trigger:** `short.sha256`, `empty.md5`, `junk.md5` all gave zero rows and no error.
- **Fix:** count non-comment lines that do not parse as errors ("cannot read line N"), and treat a checksum file with no entries as a failure.
- **Related, low, confirmed (reading):** `run.contents(of:)` silently stops at 64 MiB (`ToolRun.swift:150`), so entries beyond it are never verified.

**4. Decode silently produces truncated or oversized files and reports success** — data-loss/correctness — `FileTools/Transcoding.swift` — confirmed (test), all five cases
- **URL-safe Base64 is cut at `--`** (line 387): the alphabet accepts `-` and `_`, but a line or 64 K piece starting with `--` is taken for a MIME boundary. A file starting `----` decoded to 0 bytes; a one-line file whose second 64 K piece starts with `--` decoded to 49,152 of 98,604 bytes. For random data that is about 1 in 4,096 per piece. Fix: only treat `--` as a boundary when the body came from MIME headers.
- **Unrelated numbered siblings are appended** (lines 557-565): `photo1.b64` and `photo2.b64`, both plain `base64` output without padding, decoded to one 6,000-byte file (photo1 + photo2). A crafted file can pull numbered siblings into the output the same way. Fix: only continue into further parts for bodies that began with a header, or when the first part ends on a full line.
- **Damaged UUE/XXE lines are dropped** (line 420): 855 of 900 bytes written, no error. The `sum -r/size` trailer the encoder writes is never checked.
- **A missing `end` is accepted** (line 312): a multi-part set with a missing last part yields a short file and success.
- **yEnc `size=` and `crc32=` are never checked** (line 422): a truncated body with a wrong CRC decoded to 9 of 16 bytes, no error.
- **Fix for the last three:** report "incomplete or damaged" and keep or flag the output.

### Medium

**5. Unsaved Compare edits are lost on quit** — data-loss — `CompareContent/CompareContentPlugin.swift:73-76` — confirmed (reading)
- `stop()` calls `close()`, which bypasses `windowShouldClose`. `AFMShell/App/Shell.swift:103` only asks the job service, so Cmd+Q with edited files discards them silently.
- **Fix:** have the plugin veto or prompt on termination.

**6. Save fallback can delete both the original and the new content** — data-loss — `CompareContent/CompareLoader.swift:223-232` — plausible
- **What:** if `move(replacing: true)` fails, the code does `remove(url)` then `move(temporary, to: url)`. If that second move fails, the outer `catch` removes the temporary as well.
- **Trigger:** a provider that cannot rename over an existing file (typical SFTP/FTP) plus a dropped connection or error between the two steps.
- **Fix:** move the original aside as `SyncExecutor` does, and never delete the temporary once the original is gone.

**7. Private files are world-readable while being saved or copied** — security — `CompareContent/CompareLoader.swift:216-221`, `DirectorySync/SyncPlan.swift:358-370`, `LocalFileSystem/LocalFileSystem.swift:359` — confirmed (reading)
- The local `write` opens with `0o644`; permissions are applied only in `close(attributes:)`. Saving a `0600` file writes its full content to `.name.afm-save` readable by others first. The same holds for streamed sync copies.
- **Fix:** create with `0600` and widen at close.

**8. `clear()` resets the phase while a comparison or sync job is running** — threading/re-entrancy — `DirectorySync/SyncSession.swift:97-107, 120-127, 470-481` — confirmed (reading)
- **What:** `adopt()` (the command is `runsDuringJobs: true`) and `loadSet()` (the ★ menu is always live) call `clear()`, which sets `phase = .idle` without cancelling `running`.
- **During a sync job:** Compare and Synchronize become available again, a comparison runs over trees being modified, and a second plan is queued.
- **During a comparison:** the old one keeps running uncancelled. If the user does not start a new one, its rows are installed under the newly shown paths; the Synchronize dialog's delete lines name no directory.
- **Fix:** refuse `adopt`/`loadSet` while synchronizing; in `clear()` cancel and nil `running`.

**9. Mirror mode has no guard against an empty or unmounted left side** — data-loss — `DirectorySync/SyncComparison.swift:131-170`, `SyncSession.swift:362-383` — confirmed (reading)
- A root that fails to list is handled correctly (no rows, error shown). A root that lists as empty (a leftover mount point, an empty share) makes every right file `.rightOnly`, proposed as `deleteRight` with the box pre-checked. Deletion is direct where there is no Trash.
- **Fix:** when one root is empty and the other is not in asymmetric mode, ask explicitly, name the directory in the delete line, and default the box off.

**10. Sync outcome is never shown; commit failures are silent** — data-loss/correctness — `DirectorySync/SyncSession.swift:430-440`, `SyncPlan.swift:195, 317-331` — confirmed (reading)
- `outcome.errors`, `skipped` and `wasCancelled` are never read. A failed `commit` on a deferred-write destination stops the deletions but tells the user nothing; the result of the final `commitWrites()` is discarded.
- **Fix:** show a summary when there were errors or a commit failed.

**11. Cancel during a sync copy leaves a stray temporary** — leak — `DirectorySync/SyncPlan.swift:278-280, 347` — confirmed (test)
- When the same-volume copy to the temporary completes and the flag is set, `transfer` throws `Cancelled` outside the `do` that removes the temporary. Result: `[".f.bin.afm-sync", "f.bin"]` left in the target.
- **Fix:** wrap `transfer` in the cleanup.

**12. A listing cut short by cancel is trusted as "empty folder"** — data-loss — `DirectorySync/SyncPlan.swift:401, 420` — confirmed (test, mechanism)
- The local `list` returns `[]` without throwing once the flag is set. `perform(deletion)` then went on to remove a non-empty folder; only `rmdir` refusing saved it ("Directory not empty"). With Trash on, `trashItem` would move the whole folder, including files the user chose to keep. `removeEmptyDirectories` has the same pattern.
- The window is narrow (cancel between the step check and the first listing buffer).
- **Fix:** re-check the flag after every `list` before acting on the result.

**13. Case-colliding names are paired as "left only"** — data-loss — `DirectorySync/SyncComparison.swift:250-283` — confirmed (test)
- Left `{a.txt, A.txt}` against right `{a.txt}` gives `A.txt <-> -` as `.leftOnly`. Copying it to a case-insensitive right replaces `a.txt`; the next sync flips back. With three names folding alike, two become one-sided.
- With Confirm overwrites off or after "Overwrite All" it is silent.
- **Fix:** mark a leftover as excluded when its folded name equals a name already used on the other side.

**14. Cleanup after Overwrite + cancel deletes files that were there before** — data-loss — `FileTools/SplitCombine.swift:96, 122`, `Transcoding.swift:172, 228`, `ToolRun.swift:187` — confirmed (test for finished parts; reading for the in-progress part)
- `written` holds final URLs, so on failure the cleanup removes the old file that the temp-then-rename scheme deliberately kept. Split into a folder holding old `data.001`/`data.002`, Overwrite all, cancel: folder ends with only old `data.002`.
- The "output equals source" guards use `isSameLocation`, a plain string compare (`AFMKernel/FileSystem/FileItem.swift:103`). They miss case variants (`X.CRC` vs `X.crc`), symlinked directories (`/tmp` vs `/private/tmp`) and hard links. Combined with the cleanup above, the source can be deleted after an Overwrite confirmation.
- **Fix:** track which outputs replaced existing files and only remove what the run created; compare by device/inode for local files.

**15. A cancelled Compare can leave a stale diff in phase `.ready`** — crash/correctness — `CompareContent/CompareSession.swift:132-141, 433-447, 465-482` — plausible
- **Trigger:** edit a file of 20,000+ lines (content becomes new documents plus the old diff, background recompute starts), press Compare (supersedes the recompute), press Esc. "What was shown before stays" leaves new documents with old row indexes.
- `copy(rows:)` then indexes `source.lines[$0]` and `target.lines[range]` unchecked: it traps, or copies the wrong lines, which can then be saved.
- **Fix:** re-run `recompute()` when a compare is cancelled over edited content, or block editing until the diff is current.

**16. Main-thread stalls** — freeze — confirmed (measured, release build)
- **Within-line highlight** (`CompareSession.swift:313`, `TextDiff.swift:202`): about 77 ms per changed row for two 4,096-unit lines with little in common. A screenful of long differing lines (minified JSON, base64) is seconds on first draw and stutter while scrolling. Fix: compute off-thread and reload the row, or cap the effort.
- **Inline recompute** (`CompareSession.swift:175-177`): under 20,000 lines the diff runs synchronously on every edit and option toggle. 2 × 9,999 lines with repeated lines took 210–620 ms. Fix: lower the threshold to about 2,000 lines or always go to the background.
- **Sync list** (`SyncSession.swift:209-251`): `rebuild()` takes about 385 ms per Show toggle at 1M rows, `plan()` about 380 ms, and sorting 1M rows of one folder by size or date 3.7 s. Fix: sort on extracted keys, off the main thread for large lists.

**17. The executor ignores `timeOffsetHours`** — correctness — `DirectorySync/SyncPlan.swift:385-394` — confirmed (reading)
- `adjustDate` sets the target to the source's date (or the source to the target's) with no offset, while `classify` adds the offset. With dT ≠ 0 every copied pair shows as different again at the next compare.

### Low

- **Encode traps on a huge "Lines per file"** (`Transcoding.swift:180`): `limit * method.lineLength` overflows for values like `999999999999999999` and kills the app. Confirmed (reading).
- **Encode reuses the last part name if the source grew** since the panel listed it (`Transcoding.swift:169`): the user is asked to overwrite the tool's own earlier part.
- **Names with a line feed** produce a checksum file that fails its own verify (`notFound`); no GNU escaping on write. Confirmed (test). The same gap lets a file name inject extra lines.
- **Save is lossy and unchecked:** `allowLossyConversion` turns characters outside Latin-1 into `?` (`TextDocument.swift:68`); invalid sequences in a BOM-marked file are rewritten as U+FFFD; there is no check that the file changed on disk since loading; hard links are broken by the rename; a file compared with itself is written twice.
- **Close after "Save" can drop newer edits:** `completion(true)` fires even when an edit arrived during the job (`CompareSession.swift:533`).
- **Stale Find results:** `findGeneration` is not bumped by `recompute`, `swap`, `resync` or `compare`, so a result can jump to a row of the old diff (bounds-checked, harmless).
- **Sort order differs from the system for digit runs above 2^64:** `localizedStandardCompare` wraps; the fast path compares correctly. One disagreement in 1.2M fuzzed pairs. Display order only; nothing searches the order.
- **A cancelled comparison is not labelled** (`SyncSession.swift:184`): rows are valid but partial, and Synchronize is enabled.
- **`.name.afm-old` is deleted at the start of the next attempt** (`SyncPlan.swift:288`), even when a failed restore left it as the only copy of the old file.
- **Streamed (cross-provider) file copies never call `copyMetadata`.**
- **BLAKE3 uses the cores poorly on 1 MiB blocks:** 706 MB/s against 338 MB/s serial on 16 cores. `concurrentPerform` fires for subtrees as small as 16 chunks. Larger read blocks for BLAKE3 would help.
- **Pause stops only one hashing thread:** the thread holding `reportLock` blocks in the gate, the others skip via `try()` (`ToolRun.swift:99`).
- **Undo memory:** up to 20 snapshots, each edit copying the edited side's line array (about 64 MB at 2M lines).
- **Within-line ranges can split a surrogate pair or isolate a combining mark** (`41..<42` in both tests). Guarded by `upperBound <= length`; cosmetic.
- **`Hashes.swift` needs the macOS 26 SDK to compile** (`SHA3_256` under `#available`).

## Shared mutable state

| State | Protection | Sufficient? |
|---|---|---|
| `ToolRun` counters, `lines`, `lastReport` | `lock`; reports serialised by `reportLock` | Yes |
| `ToolRun.overwritesAll`, `ToolOutput`, `FolderSink`, `DecodeMachine` | job thread only | Yes |
| Hasher instances | one thread per block (`Parallel.map` over hashers, sequenced by its return) | Yes |
| BLAKE3 `values` buffer in `subtree` | disjoint slots per iteration | Yes |
| `SyncComparison.counters`, `errors` | `NSLock`; `report` called under it | Yes |
| `lastReport` in `SyncSession.compare` | only touched inside those serialised calls | Yes |
| `SyncExecutor` fields | job thread; callbacks via `monitor.ask` | Yes |
| `SyncSession`, `CompareSession` | main thread; stale guards `running === …`, `findGeneration`, `editGeneration` | No: see 8 and 15 |
| `CompareLoader.identical` `next`/`differs`/`failure` | `NSLock` | Yes |
| `FileTools.createChecksums` `written` | written on job thread, read in completion | Yes |

## Checked and found sound

- **BLAKE3:** all 35 official vectors pass, one-shot and streamed. That covers every length you listed plus 3–8 and 127–129. Streaming was 1 byte at a time (≤ 8193), fixed steps of 63/64/65/1023/1024/1025/2048/3000/4096/5000, and 50 random chunkings each. Inputs up to 16 MiB + 1024 gave identical results for the parallel, 1 MiB-block and random-chunk paths against the serial path.
- **SHA-3:** 224/256/384/512 for "", "abc", a 1 MB pattern and rate-boundary lengths (71–73, 103–105, 135–137, 143–145) all match Python `hashlib`. The CryptoKit path and the Swift fallback agree, including under random chunking; SHA3-224 of the 1 MB pattern also matches `openssl`. Rotation counts are all 1–62.
- **CRC32, MD5, SHA-1, SHA-2:** match `hashlib`/zlib (225 digests, 0 bad); Data slices with a non-zero start index are handled.
- **Myers:** 400,000 fuzzed cases with limits nil/0/1/2/3/5/8/100 always gave a valid script, and the shortest one when unlimited. A debug build with bounds checks never trapped; table sizing is `rounds ≤ reach`. Empty against non-empty is correct.
- **TextDiff:** 32,000 fuzzed cases with anchors, all option combinations and non-ASCII (é composed/decomposed, Kelvin sign, ß, İ) were valid. Equal keys always hash equal, and every `.equal` row is re-checked with `isSameKey`.
- **Verify logic:** no path turns a mismatch into OK. Empty digests of uncomputed methods cannot match, cancel throws, unreadable files give `readError`, result ordering is preserved. Absolute and `../` names are only read.
- **Decoders:** 300,000 random UUE/XXE lines without a trap. Header names cannot leave the target (`../../../escape.bin` and `/tmp/…` both landed in the target folder); header modes are ignored (4755 became 644).
- **Sync:** symlinks are never followed or deleted; a failed or cancelled listing of either side drops the folder on both; content read errors give `.pending` with no action; deletions run after commit, files before folders; `canSynchronize` and the plan cannot diverge.
- **Save:** symlinks are resolved, and the temporary is created with `O_EXCL`.

## Not reviewed or not run

- BLAKE3 beyond 4 GiB / 2^32 chunks: the counter is 64-bit by reading, but no reference tool was available to check.
- Remote and archive providers' behaviour under findings 6, 10 and 12.
- The AppKit windows were read, not driven: 8M-row tables, the sheet/progress interplay and the 1M-row UI are measured only at model level.
- A real macOS < 26 system: the fallback class was exercised directly on macOS 27.
