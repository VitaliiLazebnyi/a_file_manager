# Fuzz target group 7 (diff/rename)

Task: fuzz target group 7 (Myers/TextDiff, within-line highlights, compare loader, RenameMask/RenameRules/RenamePlanner, NameTemplate) with the driver in `Fuzz/fuzz-diff`.

Group 7 has two crashes and two hangs, all needing a user action; the diff and highlight code came through clean. Both crashes were found by reading `NameTemplate.slice` and confirmed with hand-made inputs — the guided run did not reach them, because `<0-99999>` ranges kept it slow.

Paths below are relative to `F=/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/fuzz`. File:line refers to the project sources (the copy is identical; no patches were made).

## Runs

"asan" is `-O` with AddressSanitizer and edge-coverage feedback; "rel" is plain `-O`, started from the asan corpus.

| target | asan execs | rel execs | crashes | hangs | property failures |
|---|---|---|---|---|---|
| myers | 9,790 | 26,748 | 0 | 0 | 0 |
| textdiff | 74,049 | 132,924 | 0 | 0 | 0 |
| inline | 12,290 | 24,061 | 0 | 0 | 0 |
| loader | 26,810 | 31,535 | 0 | 0 | 0 |
| renamemask | 80,611 | 106,430 | 0 | 1 | 0 |
| renameregex | 84,459 | 74,841 | 0 | 1 | 0 |
| planner | 190,768 | 190,955 | 0 | 0 | 0 |
| nametemplate | 9,986 | 52,305 | 2 | 0 | 1 (low) |

No over-memory cases in any target.

What the clean targets checked:
- **myers:** segments cover both sequences, equal segments really are equal, and applying the script to A gives B, with cost limits 0–23 and the automatic limit on inputs up to about 30k elements. Without a limit the result is the shortest, checked against an LCS reference. Both the `[Int]` and `[UInt16]` overloads were run.
- **textdiff:** rows cover both files in order, equal rows pass `isSameKey`, `rebuiltRight` gives the right file, blocks match the rows, and the result is the shortest against LCS on keys. Anchors (including out-of-range ones), cost limits and `CompareLoader.text` width were included.
- **inline:** ranges are sorted, non-empty and in bounds, and the unhighlighted remainders of the two lines are equal. Inputs included surrogate pairs, combining marks, lone surrogates via bridged `NSString`, lines over 4096 units and `minimumMatch` 0–5.
- **loader:** `TextDocument(data:)` detection, decoding and line splitting, plus the `data()` round trip for bytes valid in the detected encoding. `BinaryDiff` was checked against a naive byte count, with `bytesPerLine` from -128 to 127.
- **planner:** after `autoRenamed` or `skippingConflicts` no conflicts remain, and the steps executed on a simulated name set always find their source, never land on an existing name, and leave every item at its target. Case folding and NFC/NFD twin names were included.

## Findings

1. **Crash, high (user types it in New folder F7 / New file Shift+F4).** `Sources/Plugins/FileOperations/NameTemplate.swift:352`, `width = last - start + 1`.
   - Reason: typed `<[N9223372036854775807--9223372036854775807]` gives start = Int.max-1 and last = count - Int.max, so the subtraction overflows. `NameTemplate.names` runs inside the job, so the trap kills the app.
   - Reproducer: `repro/diff/nametemplate-slice-overflow.bin`
   - Command: `$F/build-rel/release/fuzz-diff run nametemplate $F/repro/diff/nametemplate-slice-overflow.bin`

2. **Crash, high (same entry point).** `NameTemplate.swift:343`, `end = start + length - 1`.
   - Reason: typed `<[N1,-9223372036854775808]` gives length = Int.min, because `min($0, maxWidth)` keeps negative values. The line is inferred from the code; the symboliser only resolved the frame to `slice`.
   - Reproducer: `repro/diff/nametemplate-slice-length-overflow.bin`, same command form.
   - Fix for both: limit the digits read (as `RenameMask.Scanner.number` does with 9), or clamp positions and lengths to 0…255, reject negative lengths, and use overflow-reporting arithmetic.

3. **Hang, high (user search text plus a long file name in the Multi-Rename list).** `Sources/Plugins/MultiRename/RenameRules.swift:166` (`matches(in:)`) and `:163` (`firstMatch`); the pattern comes from `wildcardPattern`.
   - Reason: the plain, non-regex search `*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b` against a 250-letter name of `a`s becomes `^.*?a.*?a…b` and backtracks without end. It ran over 60 s for one name and was stopped. The preview cannot cancel it, since `isCancelled` is only asked between names.
   - Reproducer: `repro/diff/renamemask-wildcard-backtracking.bin`
   - Command: `$F/build-rel/release/fuzz-diff run renamemask $F/repro/diff/renamemask-wildcard-backtracking.bin --timeout 60`
   - The same happens with the user regex `(a*)*b` on 32 `a`s: `repro/diff/renameregex-catastrophic.bin`, target `renameregex`.
   - Fix: match wildcards with a linear matcher instead of a regex, and run user regexes through `enumerateMatches` with a deadline or the cancel flag, showing `<Error!>` on timeout.

4. **Slow but bounded, low.** `NameTemplate.swift:284-289` builds a `DateFormatter` for every `[d]`/`[t]` of every name.
   - Reason: `<0-99999>[d]` took 26.7 s in the driver, which expands it twice (`names` plus `rangePreview`), so about 13 s per `names()` call on the job thread.
   - Reproducer: `repro/diff/nametemplate-slow-range.bin` (run with `--timeout 100`).
   - Fix: one formatter per expansion.

5. **Property mismatch, low.** `NameTemplate.names` returns empty names from the list branch (lines 66–78), while the range branch (line 65) filters them out.
   - Minimal counterexample: `<[T2+1D]` returns `[""]`.
   - Reproducer: `repro/diff/nametemplate-empty-name.bin`, target `nametemplate`, with `FZ_EMPTY_NAMES=1` set.
   - Fix: filter empty names in the list branch too.

Not a product bug: `RenameMask.swift:499` (`context.count - 1`) traps only for count = Int.min, which the app never passes (it is `entries.count`). That came from an unrealistic first version of the driver; the input is kept as `repro/diff/note-unrealistic-count.bin`.

## Not fuzzed

- `CompareSession` (resync, edit, undo, find): it needs a Kernel and the main queue.
- `CompareLoader.load`, `identical` and `replace`: file-system plumbing with no parsing beyond what was covered.
- `RenameStore` and the file-system parts of `RenameRun`.
- Locale and time-zone variants: only en_US_POSIX and UTC were run.
- The lldb route for line numbers: it stalled on the trap handler, so lines come from `atos`.

## Left behind

- Driver: `pkg/Fuzz/fuzz-diff/main.swift`
- Reproducers: `repro/diff/` (7 small files)
- Log: `results/diff.log`
- Run directories `runs/diff-*` are deleted; the build directories are untouched.
