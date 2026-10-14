# Status: fuzz and stress harnesses (`Tests/Fuzz`, `Tests/Stress`)

Both harnesses build against the project's own sources, all 37 saved reproducers pass on the fixed
code (release and AddressSanitizer), and the stress figures are far better than in report 25. A fresh
fuzz campaign found **four new open defects**: one crash on untrusted input (Decode of a yEnc file),
one viewer row mismatch, one residual descript.ion rewrite case and one slow wildcard search.

Nothing under `Sources/`, the root `Package.swift` or the three test targets was edited.

Conditions that affect every number below: the machine (16 cores, 128 GB) was never quiet. Other
agents built and tested throughout; the load average was 10 to 73 during my runs and is given per
run. Stress runs were made one at a time (a lock), on a release build with `-enable-testing`,
headless (window never shown), as in report 25.

## 1. What changed in the harnesses

**Build (goal 1).** `Tests/Fuzz/pkg` and `Tests/Stress/harness` each hold two symbolic links,
`Sources -> ../../../Sources` and `TestSupport -> ../../../Tests/TestSupport`; SwiftPM accepts
them and both packages build (7 fuzz drivers in release and with ASan, 6 stress harnesses in
release). No source is copied. The stress manifest no longer declares the project's test targets.
The one generated file is `pkg/Fuzz/fuzz-viewer/HTMLReference.swift`: `build.sh` takes it over from
`Tests/PluginTests/ViewerAdoptHTMLReference.swift` (minus `import Testing`) before each build, so
the slow HTML reference cannot fall behind the product again.

**Paths.** No script holds an absolute path. Build output, logs, corpus and findings go to
`Tests/Fuzz/out/` and `Tests/Stress/out/` (git-ignorable, deletable); data goes below the system's
temporary folder (`$TMPDIR/afm-fuzz…`, `$TMPDIR/afm-stress`) and is removed after each run.
`StressJobs` lost its hard-coded default root. `results/PATCHES.txt` now says that no product patch
is applied or needed.

**Scripts.**
- Fuzz: `build.sh`, `replay.sh` (quick check), `campaign.sh` (timed campaign); `run_arch.sh`,
  `run_seq.sh`, `run_rel.sh` are gone (replaced by `campaign.sh`). `repro/MANIFEST.tsv` lists every
  reproducer with its target and original finding.
- Stress: `build.sh`, `run.sh <scenario>`, `quick.sh` (quick check), `bin/run.py` (lock, time limit,
  new memory limit that kills a run above a given RSS), `bin/summary.py` (the table columns of
  report 25 from a log), `bin/gen_million.py` (the million-file directory; no generator had been
  kept), `bin/sanitizers.sh` and `bin/sigpipe.sh` (Part A of report 25 against the project root).
  Removed: the one-off scripts `my-runs*.sh`, `panel-runs.sh`, `million3.sh`, `isolate.sh`,
  `partA*.sh`, the prebuilt `sigpipe/libtrap.dylib` (now built into `out/`) and `control/` (a
  manifest whose test source had not been copied in, so it could not build).

**Drivers (goal 2).** Every target compiled against the changed APIs without an edit, but several
no longer tested what runs or stated old behaviour. Changed oracles:

| Driver | Change |
|---|---|
| `fuzz-misc` `quote`, `quote-demo` | Rewritten for the new contract (values are arguments, never text). The driver builds `ShellLine.script`, starts real `/bin/zsh` and `/bin/sh` through `ChildProcess.spawn` and requires: no file appears in the folder of the run (names carry payloads that would `touch` one), every argument arrives byte for byte (builtin `printf` and, once per set, `/usr/bin/printf`; only a leading `-` of a word of its own becomes `./-`), the shell's text is the same for hostile and tame names, and 15 templates with a placeholder in an unsafe place are refused. 28 templates per set of names. Positive control `FZ_QUOTE_CONTROL=1` (values pasted as text) fails with `quote-command-ran`, so the check is not blind. A precomposed `è` arrives as `C3 A8` (it used to arrive decomposed). |
| `fuzz-misc` `settings` | The import form is answered (every part ticked; sometimes accepted as proposed or cancelled) and the import is repeated. The built-in seed was refused as a whole by the new checks (`extra.key` of an unknown kind); it now passes, and the refused form is a second seed. |
| `fuzz-misc` `pexpand` | Also builds the script, the prompt and its read-back; checks that every value has a reference. |
| `fuzz-misc` `descript*`, `fuzz-viewer` `search`, `fuzz-diff` `nametemplate` | The tolerances for findings of the first campaign (`FZ_DESCRIPT_ALL`, `FZ_STRICT`, `FZ_EMPTY_NAMES`) are gone: the checks are always on. |
| `fuzz-kernel` `sorter` | The order is a strict order by construction: checked directly (asymmetry, transitivity, names equal only when the same) with the system's collator and with the fallback keys; the no-collator sort is compared with its own definition (`areInOrder(…collator: .unavailable)`), as cross-request kernel 15 asked. |
| `fuzz-kernel` `panel`, `paneldup` | Marks belong to entries: `selectionCount` = marked rows, `selectedNames` one per marked entry in list order, `selection` a set with at most that many members, `isSelected(_:)`, `operands()`, `hasOperands`, `hasOperandFile` and the totals agree with the marked rows, also for identical names. |
| `fuzz-kernel` `filemask` | New differential check against a slow reference of the documented rules (case and accent form do not count, `?` is one scalar, `[` and `\` are ordinary, `*.` rule, separators). |
| `fuzz-arch` | Listed names are never `.`, `..`, empty or hold `/` or NUL; links planted in the target before the second unpack must not be written through; new target `zippack` (password pack is AES-256 AE-2 by default, legacy only on request, no contents or password in the clear, right password reads back, wrong one does not); AES seed added. |
| `fuzz-net`, `fuzz-tools` | Name and path checks compare bytes, not Characters (a `/` with a combining mark was invisible to the old checks); decoded names at most 255 bytes. |
| `fuzz-diff` `inline` | Marks cover whole composed characters now, so one side may mark more: the unmarked rest of each side must occur in order in the other line, and no mark may cut a character. |
| `fuzz-viewer` `html` | Reference taken from the project (see above). |

Three of my own first oracle versions were wrong in the way the product used to be (Character-based
`hasPrefix`/`contains` next to a combining mark); the campaign showed it and they compare bytes now.

Stress harness adaptations: `million` waits for marks that are now worked out in the background;
`StallFS` no longer stalls `capabilities(for:)` (the protocol says it answers at once; it is still
counted); `parallel` has a step for the main-thread rule (`Parallel.isHoldingUpMainThread`) and
checks pool threads by name instead of a bare thread count (as do `jobs` and `archives` now: a
bare count failed one small archives run with 10 threads against 7, all of them the system's);
`StressViewer` got `dense <file> <MiB>`.

**Quick checks (goal 6).** `Tests/Fuzz/replay.sh`: under 10 s once built (the first build takes 3 to
5 minutes). `Tests/Stress/quick.sh`: seven small scenarios, 6 minutes at a load of 10 to 30 once
built; its last full run ended with all seven passing after the thread check was corrected.
`Tests/Fuzz/README.md` and `Tests/Stress/README.md` give commands, times, disk, memory and output places.

## 2. Regression replay (goal 3)

`Tests/Fuzz/replay.sh` and `replay.sh asan`: 37 of 37 reproducers pass in both builds, with the
updated (stricter) oracles. "Fixed" below means the input still reaches the code in question and no
longer fails.

| Reproducer | Target | Finding (report 30 unless noted) | Now |
|---|---|---|---|
| `arch/containment-slash-combining-mark.zip`, `.tar` | arch zip, tar | 1 write outside the target | fixed |
| `tools/decode-containment-slash-combining-mark.bin` | tools decode | 1 | fixed |
| `tools/combine-containment-slash-combining-mark.crc` | tools combine | 1 | fixed |
| `net/remotepath-slash-joins-combining-mark.bin` | net address | 1 (no write) | fixed (check now by bytes) |
| `misc/sorter-cfcompare-abort.bin` | misc selection | 2 abort when sorting | fixed in the product; the standalone demo `repro/misc/cf/cfcompare.swift` still aborts on this macOS, so the system bug is still there and the product no longer reaches it |
| `net/ftplist-regex-backtracking.txt` | net ftplist (0.5 s limit) | 3 hang | fixed (2 ms) |
| `misc/quote-injection-combining-mark.bin` | misc quote-demo | 4 command injection | fixed: through real zsh and sh nothing runs and the name arrives byte for byte; the control run creates `PWNED` |
| `misc/quote-trailing-nbsp-trimmed.bin`, `…ideographic-space…` | misc quote-demo | 5 trailing space trimmed | fixed (`61 C2 A0` arrives) |
| `net/saved-connection-port-trap.json` | net saved | 6 crash | fixed |
| `misc/pexpand-substring-length-overflow.bin` | misc pexpand | 7 crash | fixed |
| `misc/settings-import-frequent-count-overflow.json` | misc settings | 8 crash after import | fixed: the form is shown, the file is imported, the folders are visited, no trap |
| `misc/frequentfolders-count-overflow.bin` | misc lenient | 8 | fixed |
| `misc/selection-save-ansi-nsexception.bin` | misc selection | 9 abort | fixed |
| `diff/nametemplate-slice-overflow.bin`, `…slice-length-overflow.bin` | diff nametemplate | 10 crashes | fixed |
| `diff/renamemask-wildcard-backtracking.bin` | diff renamemask | 11 hang (over 60 s) | fixed for this input (3 ms); see new finding N4 for another one |
| `diff/renameregex-catastrophic.bin` | diff renameregex | 11 hang | fixed (0.2 s: the regex budget) |
| `viewer/search-backwards-returns-match-at-start.bin`, `…after-start-midcharacter.bin` | viewer search | 12 | fixed (tolerance removed) |
| `viewer/rows-thin-overflow.bin` | viewer rows | 13 overflow | fixed, without the old patch |
| `viewer/search-raw-vs-decoded…`, `…chunked-vs-whole…` | viewer search | low (21) | fixed |
| `misc/descript-*.bin` (6) | misc descript, descript-line, descript-store | low (22) | fixed for these six; a relative still fails (N3) |
| `tools/checksum-empty-name.md5` | tools checksum | low | fixed |
| `diff/nametemplate-slow-range.bin` | diff nametemplate | low, 13 s | fixed (0.44 s release, 0.77 s ASan) |
| `diff/nametemplate-empty-name.bin` | diff nametemplate | low (20) | fixed (check always on) |
| `kernel/panel-selectioncount-vs-marked.bin` | kernel panel | low, mark without a row | fixed |
| `kernel/panel-computed-size-shown-vs-listed.bin` | kernel panel | low | fixed |
| `kernel/panel-selection-set-loses-twin-names.bin` | kernel panel | low, NFC/NFD twins | no longer applicable as a defect: `selection` is documented as a set of names that read the same (K046); it failed the old check and passes the new one (`selectedNames` has one per marked entry) |
| `diff/note-unrealistic-count.bin` | diff renamemask | note only | no longer applicable: never a product bug (count = Int.min, which the program cannot pass); passes |
| `misc/quote-mismatch-argument-decomposed.txt`, `misc/quote-mismatches/*.txt` | – | text reports | not inputs. Their subject (arguments arriving decomposed, mismatches per quoting context) is covered by the byte-exact check, which passes |

Nothing saved from the first campaign still reproduces.

## 3. Fresh fuzz campaign (goal 4)

`campaign.sh 600 3 asan`: 10 minutes per group, 3 groups at a time, ASan build with coverage
feedback, seeds from `Tests/Fuzz/seeds`. Load average 46 at the start, 10 at the end. After the
oracle corrections a second run of 4 minutes per group for kernel, misc, net, diff and viewer.

| Group | Executions, first run | Second run |
|---|---|---|
| arch (11 targets) | 281,623 | – |
| net (6) | 1,502,430 | 1,299,646 |
| tools (6) | 485,824 | – |
| kernel (4) | 163,966 | 189,950 |
| misc (9) | 1,168,878 | 1,001,277 |
| viewer (5) | 1,073,337 | 1,218,820 |
| diff (8) | 815,859 | 352,843 |

The shell check ran 124,040 + 188,160 argument cases through `/bin/zsh` and `/bin/sh` with no
command run and no argument changed. No ASan report (no memory error) in any target; no finding
in the archive group, including containment, link planting and the AES default.

### New findings (open; reproducers under `Tests/Fuzz/repro/new/`, replayed by `replay.sh`)

**N1. Crash decoding a yEnc file (trap).** High by the rule of report 30 (a user action on an
untrusted file).
- Input (48 bytes): `=ybegin ` LF `=ypart begin=-9223372036854775808 end=0`.
- Site: `Sources/Plugins/FileTools/Transcoding.swift:598`, `yPartLength = end - begin + 1` in
  `DecodeMachine.feed`: `end - begin` overflows `Int64` (also for other pairs far apart).
- Stack: `DecodeMachine.feed(ArraySlice<UInt8>)` ← driver; signal 5 in release and ASan builds.
  Found by `decodemem` (19 times) and through the real command path `Decoder.decode` (`decode`).
- Reproduce: `fuzz-tools run decodemem repro/new/tools-decodemem--ypart-range-overflow.bin`.
- Not seen in the first campaign; the part-length check appears to be new code.

**N2. Viewer: the fast row scan and the decoding scan give different rows.** Low to medium.
- Input (7 content bytes): `00 00 0A 0A 0A 0A 0A` as UTF-8, 1 column, no wrap, segment and chunk
  size 1: the raw scan (the program's default, `rawScan: true`) makes 7 rows, the decoding scan 6.
  Larger inputs of the same kind were found 18 and 20 times (`\r\r\n`, invalid UTF-8, control bytes).
- Check: `rows-raw-differs-from-decoded` in `fuzz-viewer`, target `rows`; first campaign: never
  failed in 722,561 executions of the group, so this came with the fix round (the row scan was
  changed for wide characters and the short-line fast path).
- Not established: which of the two is right against the whole-file reference (the check stops at
  the first difference), and whether it shows with the program's sizes (4 MiB segments, 1 MiB
  chunks), where it would need the pattern at a chunk boundary.
- Reproduce: `fuzz-viewer run rows repro/new/viewer-rows--raw-scan-row-count-differs-from-decoded.bin`.

**N3. descript.ion: a rewrite changes a name made of the bytes of a byte-order mark.** Low.
- Input (9 bytes): `20 F8 0A EF BB BF EF BB BF`. Not valid UTF-8, so it is read as Latin-1: one
  entry named `ï»¿ï»¿`. Written again and read again, the name is `U+FEFF U+FEFF`: the file that is
  written back is valid UTF-8 (the line with `F8` is gone) and is read as such.
- Check: `descript-rewrite-changes-entries`, target `descript` (39 and 28 times). This is the
  family the first campaign's driver left out unless `FZ_DESCRIPT_ALL` was set; the six saved
  reproducers pass, this relative does not.
- Also seen, not counted as a defect and now left out of the check: a comment that itself ends
  with the text of the multi-line marker (`U+0004 Â`) is empty after a rewrite; the format cannot
  tell the two apart.

**N4. Multi-Rename: a long plain wildcard search takes seconds per name.** Low.
- Input: 4,096 bytes (name mask of 3,028 bytes, plain Search text of 1,050 bytes with `|` and `*`):
  4.6 s for one name in the release build.
- Stack when interrupted: `WildcardMatcher.fits` ← `WildcardMatcher.firstOccurrence` ←
  `WildcardMatcher.matches(in:firstOnly:)` ← `SearchReplace.replacing(in:cancelled:)` ←
  `RenameEngine.newName`; time goes to `Unicode.Scalar.Properties.lowercaseMapping` per comparison.
- The regex budget (0.1 s per name) does not cover the plain wildcard matcher. The old
  reproducer (over 60 s) takes 3 ms, so this is the same class much reduced; the call takes a
  `cancelled` closure.
- Reproduce: `fuzz-diff run renamemask repro/new/diff-renamemask--long-wildcard-search-takes-seconds.bin`
  (fails the default 2 s limit).

Because these four are open, `replay.sh` currently ends with "replayed 41, failing 4" and exit status 1.

### Seen, not counted as defects

- `nametemplate`: a typed range of about 70,000 names with a date code takes 1.6 to 2.0 s in release
  (the old 100,000-name case took 13 s); it crosses the 2 s limit under ASan on a loaded machine.
- `myers`: inputs repeated to about 200,000 elements without a cost limit take 0.5 to 0.75 s in
  release and over 2 s under ASan at load 40.
- Oracle errors of mine that the first run showed and the second run confirmed gone:
  `inline-rest-differs` (58), `html-differs-from-reference` (330), `address-password-shown` (1),
  `pexpand-script-value-without-reference` (3), `descript-store-other-comment-changed` (2), a
  `sorter` timeout from a second slow reference sort (4). `selftest` (a target that crashes on
  purpose) ran in the first campaign by a mistake in the script and is excluded now.

## 4. Stress reruns (goal 5)

Free disk before: 1,464 GB; no scenario was skipped for space. Sizes are those of report 25 unless
"reduced" is said. "Before" is the figure of report 25 (load 8 to 45 then).

| # | What ran | | Wall | Peak RSS | Max main-thread stall | >8 ms / >100 ms / >1 s | Threads before → after | Load during run |
|---|---|---|---|---|---|---|---|---|
| a (1) | 1,000,200-entry directory in a panel, full script | before | 166 s | 3.2 GB | 1,266 ms (select by mask) | 677 / 119 / 2 ¹ | 19 → 9 | 13–19 |
| | | now | 115 s (+96 s to make the files) | 1.8 GB | 270 ms (start-up); in the list 209 ms (cursor to a random row) | 764 / 15 / 1 ¹ | 24 → 20 | 14–22 |
| b (2) | Provider that stops answering, 23 actions + 100 refreshes | before | 49 s | 263 MB | 158 ms | 99 / 4 / 0 | 19 → 12 | 11–17 |
| | | now | 24 s | 186 MB | 451 ms (start-up), 182 ms in the idle second after it; while the provider is silent 112 ms | 35 / 3 / 0 | 30 → 20 | 50 |
| c (3) | `Parallel.map` torture | before | 39 s | 19 MB | 15 ms | 1 / 0 / 0 ² | 6 → 7 (peak 65) | 12–14 |
| | | now | 40 s | 23 MB | 17 ms | 4 / 0 / 0 ² | 6 → 8 (peak 252) | 21–28 |
| d (8) | 5,000 changes/s for 20 s, 20,000-file folder | before | 29 s | 206 MB | 278 ms | flood phase 225 / 27 / 0 | 19 → 9 | 17–21 |
| | | now | 29 s | 163 MB | 38 ms | flood phase 21 / 0 / 0 | 27 → 18 | 16–18 |
| d (8) | same, 2,000-file folder | before | 27 s | 206 MB | 222 ms | flood phase 244 / 19 / 0 | 19 → 9 | 17–21 |
| | | now | 28 s | 124 MB | 7 ms | flood phase 0 / 0 / 0 | 27 → 18 | 13–16 |
| e (7) | Viewer, 4 GiB dense file, whole script | before | 47 s | 96.9 GB | 58 ms on this file (202 ms over the five files) | 44 / 0 / 0 | 7 → 9 (peak 48) | 17–24 |
| | | now | 46 s | 463 MB | 102 ms | 69 / 1 / 0 | 12 → 10 (peak 48) | 30–38 |
| e (7) | Viewer, 64 MiB file: memory per whole-file search | before | – | +60.8 MB per search (5.5 GB after 100) | – | – | – | 44 |
| | | now | 32 s + 18 s | +0.3 to 0.5 MB per search over the first 100 (32 to 46 MB in all), then +0.002 MB; peak RSS 218 MB | 20 ms | 6 / 0 / 0 | 11 → 9 | 12–14 |
| f (4) | FileJob, reduced: 3 seeds × 20,000 files + 6 deferred-write runs (before: 50 seeds × 20k) | before | 611 s | 157 MB | 15 ms | job phases 7 / 0 / 0 | 8 → 8–9 (peak 40) | 8–21 |
| | | now | 73 s | 129 MB | 39 ms | whole run 73 / 0 / 0 | 9 → 8 (peak 38) | 29–38 |
| f (5) | ZIP, reduced: 50,064 members, 30 s concurrent stage (before: 200,064 members, 60–90 s) | before | 108 s | 985 MB | 17 ms concurrent, 49 ms open | 23 / 0 / 0 | 7 → 8 | 8–38 |
| | | now | 42 s | 522 MB | 11 ms concurrent, 17 ms open | concurrent stage 2 / 0 / 0 | 8 → 8 | 29–32 |
| g (6) | FindFiles, reduced: 100,000-file tree only, 20 + 20 cancels (before: tree + 1M directory, 2 × 100) | before | ~1,400 s | 11.6 GB | 589 ms (product) | cancel phase 457 / 9 / 2 | 19 → 9 | 13–26 |
| | | now | 129 s | 637 MB | 645 ms in the cancel phase, of which 119 ms main-thread CPU (no core: load up to 73) | window cancel phase 118 / 6 / 0, engine cancel phase 35 / 1 / 0 | 10 → 9 | 30–73 |

¹ Then and now one stall over 1 s (4.4 s then, 5.3 s now) is the harness listing the directory on the
main thread for its final comparison, not the program. Without it: no stall over 1 s now.
² Without the phase in which the harness waits 8 s for the child that is meant to hang.
Thread counts include two or three of the system's queue threads that come and go.

All harness checks passed in the final runs (`FAILURES: 0`, no invariant violation in jobs and
archives, every uncancelled search complete). Scenario (a) and (b) were run twice: the first run
of each failed on a stale harness expectation (marks sampled before the background work ended;
`capabilities(for:)` counted as a blocking call) and was repeated after the harness was corrected.

### What the figures say, per finding of report 25

- **1 (viewer search memory): fixed.** 4 GiB file: peak 463 MB instead of 97 GB; footprint after
  30 cancelled searches 162 MB instead of 85.5 GB. The run has a 32 GB limit that would have killed it.
- **2 (dead share stops every folder): fixed.** After 100 refreshes of the dead share 6 calls are
  blocked (was 82 threads) and the local 300-file folder opens in 0.02 to 0.1 s (did not open in
  20 s). No stalled call reached the main thread; `capabilities(for:)` is asked about 400 times
  on the main thread by validation, which the protocol allows (it answers from memory).
- **3 (watcher flood saturates the main thread): fixed.** 37 to 39 list updates in 20 s, main
  thread inside stalls for 0.26 s of 20 s (was 18 s of 20 s); the list matched the folder afterwards.
- **4 (cursor moves cost 9 to 110 ms): still open.** 1,000 Page Downs with 333k marked: 12.2 s,
  287 stalls over 8 ms and 8 over 100 ms (was 20 ms per move); 1,000 random rows: 12.3 s, 313 over
  8 ms. The stack is still `PanelViewController.tableView(_:viewFor:row:)` →
  `FileListColumn.fill`. The model call is 0.2 ms. Headless, as before.
- **5 (marking blocks 0.3 to 1.3 s): fixed.** Select all 11 ms, invert 10 to 17 ms, mask
  (333,336 hits) 0.41 s in the background with a longest main-thread stall of 65 ms.
- **6 (Print's enabled closure): fixed.** All 333 commands with 333k marked: 9 ms (was 136 to 178 ms).
- **7 (releasing a million-item list): fixed.** Leaving the folder 67 to 96 ms (was 515 to 574 ms);
  200 quiet reloads with churn became 3 to 4 readings with a longest stall of 25 ms (was 18 to 19
  readings of 500 to 670 ms each).
- **8 (Find window with a million hits):** not rerun at that size (see below).
- **11 (`Parallel.map` and the main thread):** the rule is documented and can be asked: inside a
  map called on the main thread `Parallel.isHoldingUpMainThread` was true in all 256 bodies (242
  on helper threads), false in a map called from a background thread and false outside. Breaking
  the rule still hangs (helper bodies) or traps (all bodies) in a release build; the assertion is
  debug-only. 256 bodies that sleep 100 ms now take 0.64 s (was 1.67 s): the pool adds threads
  for waiting pieces, peak 252 threads. No `AFM.Parallel` worker is left 8 s after the last map;
  the one `AFM.Parallel.watch` thread was still there 10 s later.

New observation, not in report 25: the main-thread stall at start-up of the headless shell is
236 to 592 ms in these runs (start-up phases; 147 ms in report 25's scenario 2 log). Load was 11 to
50 and main-thread CPU was 205 to 259 ms of it, so part is work and part is waiting for a core. Not
analysed.

## 5. Not run, and why

- **No quiet-machine measurement:** other agents kept the load at 10 to 73.
- **Scenarios f and g at full size** (50 seeds, 200,064 members, FindFiles on the million
  directory with 2 × 100 cancels): reduced as the task allowed; the commands are in
  `Tests/Stress/README.md`. Finding 8 of report 25 (Find window, a million hits) was therefore not re-measured.
- **Viewer: sparse 4 GiB, 2 GiB single line, 1 GiB of newlines, truncation rounds** (`run.sh
  viewerfull`): not run; only the dense 4 GiB file and the 64 MiB file.
- **Part A of report 25** (TSan/ASan runs of the project's test suite, the SIGPIPE hunt): not
  rerun; the scripts were rewritten for relative paths (`bin/sanitizers.sh`, `bin/sigpipe.sh`) and
  checked for syntax only.
- **ThreadSanitizer builds of the fuzz drivers and debug builds of the stress harnesses** (which
  would arm `MainThread.assert` and `assertMayWaitForMainThread`): not done.
- **Fuzzing limits unchanged from report 30:** bzip2 (181 executions) and foreign formats go
  through system tools; FTP/SFTP only at parser and packet level; no real dead mount.
- **N2** was not tried with the program's segment and chunk sizes.

## 6. Clean-up

All generated data (`$TMPDIR/afm-stress`, `$TMPDIR/afm-fuzz*`), both `out/` folders (build output,
corpus, logs) and my scratch files are removed; no process of mine is running. Not removed: the
program's own scratch folders `$TMPDIR/afm-archives-<pid>-…` (70 at the end). Some are from my
stress runs, some from other agents' test runs that were going on, and I could not tell them apart;
the Archives plugin sweeps leftovers at its next start. What remains in the
project: the two harness folders with sources, scripts, READMEs, seeds (one AES seed added),
reproducers (4 new under `repro/new/`), and the logs of the first campaign under `results/` and
`logs/`.
