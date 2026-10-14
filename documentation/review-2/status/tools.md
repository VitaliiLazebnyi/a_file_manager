# Status: tools (Directory Sync, Compare by content, File tools)

Files changed: `Sources/Plugins/FileTools/{ToolRun,ChecksumFiles,Transcoding,SplitCombine,FileToolsPlugin,Hashes}.swift`,
`Sources/Plugins/CompareContent/{Myers,TextDiff,TextDocument,CompareLoader,CompareSession,CompareContentPlugin,CompareWindowController}.swift`,
`Sources/Plugins/DirectorySync/{SyncComparison,SyncPlan,SyncSession,SyncWindowController}.swift`.
Tests: see below. Cross-requests: `documentation/review-2/cross-requests/tools.md`.

| ID | Status | Note |
|---|---|---|
| T001 | fixed | FileToolsPlugin: the job returns the distinct folders (with keys); the completion passes at most those a panel shows when there are more than 256 |
| T002 | fixed | FileToolsPlugin/ChecksumFiles: mask built once (`checksumFileTest`), regex is static, operand sorting and the clipboard read now run in the job |
| T003 | fixed | Myers.swift: limit by budget (256...8192 rounds), patience anchors (lines unique on both sides) when a search is cut off, best of forward/backward walk otherwise |
| T004 | fixed | SyncSession/SyncComparison: `sourceLooksEmpty` (mirror, left lists empty, right not); warning; deletion box unticked and names the folder |
| T005 | fixed | ChecksumFiles: `parseLines` reports unreadable lines; empty/unparsable file and unreadable line are `.unreadable` rows (errors) |
| T006 | fixed | SFV entries starting with `;`/`#` parse as entries (comment only if it cannot be an entry); Create writes `./name` |
| T007 | fixed | ToolRun: deferred outputs + `transaction` (commit at the end, undo only what this run created); Split/Encode/Combine/Decode use it |
| T008 | fixed | Transcoding: missing `end` reported in `DecodeMachine.problems`; output kept, warning shown |
| T009 | duplicate of T008 | |
| T010 | fixed | `--` is a boundary only after mail headers or when the line cannot be Base64 |
| T011 | duplicate of T010 | |
| T012 | fixed | UUE/XXE: `sum -r/size` trailer checked (size, sum), skipped/short lines counted; reported |
| T013 | duplicate of T012 | |
| T014 | fixed | yEnc size, part length and crc32/pcrc32 checked; missing `=yend` reported |
| T015 | duplicate of T014 | |
| T016 | fixed | `needsMoreParts`: plain Base64 continues into a sibling only if it breaks off inside a group or ends on a full line |
| T017 | duplicate of T016 | |
| T018 | fixed | CompareSession.recompute: inline only below 2,000 lines and width 1,000; everything else in the background |
| T019 | fixed | cells show at most 4,096 characters (and are not editable when cut); `TextDiff.inline` takes a prefix before converting to UTF-16 |
| T020 | fixed | SyncSession: layout (filter, group, sort by extracted keys, summary) is a pure function, done on its own thread from 20,000 rows; plan built in the background; `selectedRows` lazy |
| T021 | fixed | ToolRun.advance: every thread waits for its turn on `reportLock` (outside it nothing), so Pause stops all hashing threads |
| T022 | duplicate of T018 | |
| T023 | duplicate of T020 | |
| T024 | needs other area | Viewer/FileProperties cancellation: not in my directories |
| T025 | fixed | `ToolRun.isSameFile` / `CompareLoader.isSameFile` (device+inode) used by Split, Encode, Combine, Compare save; kernel `isSameLocation` untouched (cross-request 2) |
| T026 | fixed | `CompareContentPlugin.shouldTerminate()` (Save/Don't Save/Cancel) and `stop()` asks Save/Don't Save; the shell must call `shouldTerminate` to be able to cancel the quit (cross-request 1) |
| T027 | fixed | LocalFileSystem (localfs agent) now creates 0600 and widens at close; Compare/Sync/FileTools all write through `provider.write`; no 0644 path left in my area |
| T028 | fixed | CompareLoader.replace: old file moved aside (never deleted), put back on failure, temporary kept if both fail |
| T029 | fixed | compare cancelled over edited content re-runs `recompute()`; edits need `diffIsCurrent`; `copy` checks every index (no dedicated test: needs a superseded background job) |
| T030 | duplicate of T018 | |
| T031 | fixed | `TextDiff.inline` effort bounded (costLimit 300) |
| T032 | duplicate of T003 | |
| T033 | refuted | verdict: refuted, no change |
| T034 | duplicate of T004 | |
| T035 | fixed | `Pair.collides`: a name alone on its side whose folded form is in use on the other side is an excluded row |
| T036 | fixed | SyncExecutor: new files on `deferredWrites` file systems go through temporary + rename like replacements |
| T037 | fixed | copy and move are one `do`; temporary removed on any exit (incl. cancel after the copy) |
| T038 | fixed | `SyncSession.report`: summary of errors, failed commit, stopped run |
| T039 | fixed | `SyncPlan.Copy.targetModified` (offset applied), `SyncPlan(rows:timeOffsetHours:)`; adjustDate/streamed copy use it |
| T040 | fixed | cancel checked after every listing before deleting or trashing a folder; same in `removeEmptyDirectories` |
| T041 | duplicate of T020 | sort by extracted (key, index) pairs |
| T042 | duplicate of T038 | |
| T043 | fixed | `clear()` cancels and drops a running comparison; `adopt`/`loadSet` refused while synchronizing |
| T044 | duplicate of T005 | with T006 |
| T045 | duplicate of T007 | with T025 |
| T046 | fixed | undo = splices (removed lines + count), edit in place after releasing `content` |
| T047 | needs other area | FileProperties/AttributeChange |
| T048 | fixed | selection cleared only if the panel still shows the folder |
| T049 | fixed | same as T048; the Descriptions part is FileProperties (other area) |
| T050 | not fixed | BLAKE3 internals left as instructed (hash implementations verified); 4 MiB read blocks for BLAKE3 reduce the splitting |
| T051 | fixed | reader closed once (only if never handed to `read`) |
| T052 | fixed | report text and failed names made in the job |
| T053 | duplicate of T021 | |
| T054 | fixed | `findGeneration` bumped in recompute, compare, swap, background |
| T055 | duplicate of T046 | |
| T056 | fixed | save completion is true only if nothing unsaved is left |
| T057 | fixed | `TextDiff.widened`: ranges cover whole composed character sequences |
| T058 | fixed | refuses characters Latin-1 cannot hold and files loaded with invalid sequences; refuses a file changed on disk; hard-linked files written in place; both sides one file refused |
| T059 | fixed | the byte-wise name order defers to the system for digit runs over 18 digits |
| T060 | fixed | streamed copy calls `copyMetadata` (best effort) |
| T061 | fixed | `.afm-old` gets a free name; a failed restore reports where the old file is |
| T062 | fixed | status says "Cancelled: the list is incomplete"; Synchronize disabled for it |
| T063 | refuted | verdict: refuted for single items; the Skip All summary is under T038 |
| T064 | fixed | GNU escaping on write (`\`, LF, CR); SFV refuses names with a line break; parser splits lines only on CR/LF |
| T065 | refuted | verdict: mode 000 throws; now a `.unreadable` row for that file and the others are still checked |
| T066 | fixed | `<digest> *` is an unreadable line |
| T067 | fixed | 4 MiB blocks for BLAKE3 (`ToolRun.read(blockSize:)`) |
| T068 | fixed | Hashes.swift: CryptoKit SHA-3 only `#if swift(>=6.2)` |
| T069 | fixed | `contents(of:)` limit 256 MiB and an error beyond it |
| T070 | duplicate of T021 | |
| T071 | fixed | Encode: more parts than planned is an error, not a reused name |
| T072 | fixed | overflow-safe capacity |
| T073 | fixed | `run` gives the result to `refreshing`; no shared var |
| T074 | not a defect | the source is opened first on purpose (an unreadable source must cost no output); the interrupt token is made only while reading |

Sound and gap entries (T075-T106): no change needed; T106 (`location(from:)` on main) not checked.

## Decisions
- Damaged or incomplete Decode input: the files are kept and a warning lists the problems (not an error, nothing deleted).
- Overwrite in Split/Encode/Combine/Decode/Create checksums: replacements happen together at the end; new files are written directly and removed again on failure.
- Mirror against an empty source: deletion box unticked (warning at compare and a note in the dialog); the user can tick it.
- Time tolerance: none (sub-second rounding only) when both sides are local APFS/HFS+; the set tolerance for everything else.
- Synchronize is disabled for a cancelled (partial) comparison.
- Decoded names longer than 255 bytes are cut at a code point; SFV with a line break in a name is refused at Create.
- Compare save refuses (error) instead of changing bytes: unrepresentable characters, invalid sequences, file changed on disk.
- Unsaved edits at quit: Save / Don't Save (Cancel once the shell asks `shouldTerminate`).

## Tests
Added: `Tests/PluginTests/Review2ToolsFileToolsTests.swift`, `Review2ToolsCompareTests.swift`, `Review2ToolsSyncTests.swift`.
Changed: `DirectorySyncCommandTests.swift` (delete lines name the folder), `ToolsAdoptTests.swift` (temporary name and streamed metadata on deferred-write file systems).
Run: the tree as of now could not build the whole PluginTests target (other areas were broken at the time: Network tests, Archives), so the three plugins and
my test files were built in a copy of the current tree (all Sources, my test files): filter FileTools, CompareContent, DirectorySync, SyncTools, ToolsAdopt, Review2: 226 tests in 28 suites, 0 failures.
The three plugin targets also build in the real tree.

## Not done
- T024, T047 (Viewer/FileProperties) and the Descriptions generation of T049: other areas.
- Cancelling the quit (T026) needs the shell/kernel hook (cross-request 1).
- BLAKE3 nested parallelism (T050) left as is.
- No test for T029 (superseded background compare) and the cancel-listing case of T040 is only covered when the flag is already set.
