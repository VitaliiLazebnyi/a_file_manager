# Review 2 — tests

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent rulings on a finding and sit next to it by file. Status is filled in by the fix round.


## Findings and verdicts

### X001 [finding, low] An ASan + UBSan full-suite run had 1 timing assertion failure.
**Outcome:** fixed in part — see `status/shell-p2.md`


- **Basis:** measured
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X002 [finding, low] Every TSan full-suite run (4) had failures; none was a race report.
**Outcome:** fixed in part — see `status/shell-p2.md`


- **Basis:** measured
- **Detail:** Failures: archive flush tests, perf and timing assertions, one SIGPIPE; TSan Kernel+Shell 10 runs: 8 clean, 2 with one failing test; PluginTests-only 6 runs: 3 clean, 3 with timing failures.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X003 [finding, low] Test aWideFolderResolvesNamesQuickly (0.5 s performance assertion) failed once under TSan and once under ASan.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** ConfigPlacesFixPlacesTests.swift:104
- **Basis:** measured
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X004 [finding, low] Test aStaleFreeSpaceFigure... failed once; it asserts free space moved by less than 1 GB while other agents wrote multi-GB files.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** KernelApiLocalTests.swift:252
- **Basis:** measured
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X005 [finding, low] Test columnValuesAreComputedInTheBackgroundOnSeveralCores failed in 1 of 10 Kernel + Shell TSan runs.
**Outcome:** fixed — see `status/shell-p2.md`


- **Where:** PanelPartsTests.swift:369; ColumnValueStore.swift
- **Basis:** measured
- **Detail:** Work is dispatched at utility QoS (ColumnValueStore.work()).
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X006 [finding, low] Test aFolderThatFailsWhileAnotherReadingOvertook... failed in 3 of 17 TSan runs (polls for a 0.4 s isOpening window).
**Outcome:** fixed — see `status/shell-p2.md`


- **Where:** RememberedListingTests.swift:138
- **Basis:** measured
- **Detail:** Timing-dependent test.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X007 [finding, low] One-off SIGPIPE death (signal 13) of the PluginTests process, writer unknown.
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Sources/Plugins/Network/SFTPChannel.swift:314; Sources/Plugins/Archives/Codecs.swift:325
- **Basis:** measured
- **Detail:** Once in the fourth full TSan run about 1,100 tests in; six re-runs with an injected SIGPIPE backtrace trap did not recur. The product sets F_SETNOSIGPIPE on its two pipe writers and uses NWConnection for sockets.
- **Proposed fix:** signal(SIGPIPE, SIG_IGN) at program start as a safety net.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X008 [finding, low] Archive flush tests time out waiting 60 s for the flush under TSan (changesAreWrittenShortlyAfterTheLastOne, pendingChangesKeepAnArchiveAliveUntilTheyAreWritten).
**Outcome:** fixed — see `status/plugins-b-p2.md`


- **Where:** Tests ArchivesFileSystemTests.swift:253; ArchivesFixTests.swift:407; Sources/Plugins/Archives/OpenArchive.swift:714
- **Basis:** measured
- **Detail:** Expired in 6 of the 9 completed TSan runs that included PluginTests; passed 3 of 3 in isolation under TSan and 10 of 10 in normal builds. Flush timer runs at utility QoS. Expectation failures, not sanitizer findings.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open


## Checked and found sound

### X009 [sound, info] Threading model held up: zero sanitizer reports, no deadlock, no data loss.

- **Basis:** measured
- **Detail:** TSan full suite 4 runs, Kernel+Shell 10, PluginTests 6, ASan+UBSan 1: 0 sanitizer reports; no run hung or hit its timeout. Normal full suite 10 of 10 passed (84-123 s). Positive controls (deliberate race and heap overflow) were reported with the same options.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open


## Not covered / left behind

### X010 [gap, info] The existing test suite was not run.

- **Basis:** 
- **Detail:** 
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### X011 [gap, info] Left behind: driver pkg/Fuzz/fuzz-diff/main.swift, 7 reproducers in repro/diff/, log results/diff.log; run directories deleted, build directories untouched.

- **Basis:** read
- **Detail:** 
- **Source:** reports/20-fuzz-target-group-7-diff-rename.md
- **Status:** open

### X012 [gap, info] Housekeeping: min leaves empty fzrun-* and .fzrun-* directories next to its OUT file when runs are killed; the author removed theirs. Left behind: driver pkg/Fuzz/fuzz-viewer/main.swift and HTMLReference.swift (plus scale FILE mode), 5 reproducers in repro/viewer/, log results/viewer.log, results/PATCHES.txt.

- **Basis:** read
- **Detail:** 
- **Source:** reports/21-fuzz-target-group-6-viewer.md
- **Status:** open

### X013 [gap, info] leaks(1) on the archive harness sat at 0 % CPU for 13 minutes and was killed; no-leak statement rests on footprint only.

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X014 [gap, info] Trash deletes not exercised.

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X015 [gap, info] Cross-volume moves not exercised.

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X016 [gap, info] Moves into a real ZIP via FileJob not exercised; the deferred-writes case used the MemoryFileSystem wrapper as specified.

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X017 [gap, info] FileJob at 50 seeds x 100k files (about 40 minutes) not run; run as 50 x 20k and 4 + 8 seeds at 100k.

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X018 [gap, info] The first 100k run is valid for invariants only: its four stalls over 100 ms (max 128 ms) came from the harness statting 2,000 paths on the main thread and overlapped other runs; harness fixed and re-run.

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X019 [gap, info] Machine was never quiet (other agents building and running).

- **Basis:** read
- **Detail:** 
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### X020 [gap, info] Relayout reuse could not be shown on the dense file: the generator put one over-long line in every MiB so every segment needed rescanning.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X021 [gap, info] heap and leaks on the live process hung, so the leaking object's type is inferred from in-process malloc statistics and the parallelism: 1 control.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X022 [gap, info] Remote, spill-to-disk and double-byte code-page viewer paths not exercised (local UTF-8 only).

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X023 [gap, info] Spotlight and duplicate search modes not run.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X024 [gap, info] Each scenario run once at full scale.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X025 [gap, info] Find/viewer tables were headless and never drawn, so on-screen cost would be higher.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X026 [gap, info] Machine load not quiet (26->13 for find, 11-24 for viewer, partly from the harness itself); a first find run overlapped another under the old lock and was discarded.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X027 [gap, info] The machine was never quiet: other agents ran a fuzzing campaign plus unrelated processes, load average 8-45 on 16 cores throughout; no quiet-machine measurement.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X028 [gap, info] Headless runs: window never shown; on-screen cost may differ.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X029 [gap, info] Release build with -enable-testing, so MainThread.assert checks were off; debug-build runs of the harnesses not done.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X030 [gap, info] Early measurement lock race: overlapped runs were repeated with flock; tables use the repeats.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X031 [gap, info] With default symbolization TSan blocks forever on atos here, so 'no report' in the first three full runs and ten Kernel+Shell runs rests on no hang and no abort at exit; fourth full run used symbolize=0.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X032 [gap, info] No real dead network mount: the stalled provider wraps MemoryFileSystem and records a stalled call on the main thread instead of blocking, so a real freeze was not induced.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X033 [gap, info] FileJob at 50 seeds x 100k files (about 40 minutes) not run; run as 50 x 20k and 4 x 100k. Trash, cross-volume moves and moves into a real ZIP not exercised.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X034 [gap, info] leaks and heap hung on live processes, so the leak type in finding 1 is inferred.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X035 [gap, info] Scenario 1 reload step capped at 90 s (a 1M-entry reload takes 4-6 s, so 200 distinct reloads do not fit).

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X036 [gap, info] Scenarios 6 and 7 run once each at full scale; Find and Viewer tables never drawn; remote, spill-to-disk and double-byte viewer paths not exercised.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X037 [gap, info] Scenarios 4-7 results were relayed from forked agents and not re-verified by this report's author.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X038 [gap, info] Clean-up: data and build directories removed; 19 MB left in the stress folder; project directory not modified.

- **Basis:** read
- **Detail:** 
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### X039 [gap, info] Cleanup: findtree and viewer data removed; $S/data/million and $S/data/panel belong to someone else and were left untouched.

- **Basis:** read
- **Detail:** 
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### X040 [gap, info] Verifier run side effects

- **Basis:** read
- **Detail:** Trapping tests left swiftpm-testing-helper-2026-10-13-22*.ips crash reports in ~/Library/Logs/DiagnosticReports and may have left a few afm-tests-* folders in the temp directory. Only source change in the scratch copy was one hook between build and install in OpenArchive.flush (claim 6). GUI app never launched.
- **Source:** reports/29-verify-archive-tools-viewer-findings.md
- **Status:** open

### X041 [gap, info] bzip2 barely fuzzed

- **Basis:** read
- **Detail:** 1,103 executions only, because each input starts /usr/bin/bzip2.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X042 [gap, info] Foreign formats (7z, rar, ...) skipped

- **Basis:** read
- **Detail:** They go through bsdtar.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X043 [gap, info] Sorter thinly fuzzed

- **Basis:** read
- **Detail:** About 2,400 executions in the driver; the 8,000-item parallel path and the reference sort make each input slow.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X044 [gap, info] FTP session not fuzzed end to end

- **Basis:** read
- **Detail:** Only the pure parsers ran; an in-process fake server would be needed.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X045 [gap, info] SFTP session depth unconfirmed

- **Basis:** read
- **Detail:** The high rate for a process-per-input target (172,155 executions) suggests many inputs ended at connect; depth not confirmed.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X046 [gap, info] Absolute-path and symlink-to-absolute escapes not fuzzed

- **Basis:** read
- **Detail:** Only relative ways out were seeded.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X047 [gap, info] Group 5: imported command steps that open windows were parsed but not performed

- **Basis:** read
- **Detail:** 
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X048 [gap, info] Group 6: ProviderByteSource, disk block cache, user-typed regexes and RTF/PDF/image paths not run

- **Basis:** read
- **Detail:** 
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X049 [gap, info] Group 7: CompareSession and file-system parts of RenameRun not run

- **Basis:** read
- **Detail:** 
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X050 [gap, info] libFuzzer unavailable; custom coverage-guided mutation fuzzer used

- **Basis:** read
- **Detail:** -sanitize=fuzzer is unsupported with the Command Line Tools; asan and rel builds, 2 s per input and 2 GB RSS watchdog. One same-line patch in the fuzzing copy (TextRows.swift:225) recorded in results/PATCHES.txt.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X051 [gap, info] Left behind: fuzz drivers, scripts, seeds, reproducers, logs under scratchpad review2/fuzz

- **Basis:** read
- **Detail:** Build products deleted; rebuild with $F/build.sh rel fuzz-<bin>; drivers in pkg/Fuzz, reproducers in repro/{arch,net,tools,kernel,misc,viewer,diff}, logs summary.log, misc.log, viewer.log, diff.log, PATCHES.txt.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### X052 [gap, info] Scaling measurement limits

- **Basis:** measured
- **Detail:** Machine at load average 25-39 on 16 cores so figures are main-thread CPU time unless marked wall. AppKit parts (menu, type-select, outline) ran headless with no window, so they are lower bounds. App never launched; benchmark copy deleted.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### X053 [gap, info] Tests/ was not read.

- **Where:** Tests/
- **Basis:** read
- **Detail:** 
- **Source:** reports/13-review-appkit-shell-second-round.md
- **Status:** open
