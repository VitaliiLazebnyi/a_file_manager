# Fuzz target group 5 (misc)

Task: fuzz target group 5 (descript.ion, tab files, selection files, settings import and lenient decoders, ParameterExpansion, shell-quoting property). Result: 4 distinct crashes (one critical, in the kernel Sorter), one confirmed command injection in the shell quoting, and a handful of lower-severity mismatches.

Paths below use `F=/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/fuzz`.
- Driver: `$F/pkg/Fuzz/fuzz-misc/main.swift`
- Reproducers: `$F/repro/misc/`
- Log: `$F/results/misc.log`
- Reproduce any finding: `$F/build-rel/release/fuzz-misc run <target> <file>` (build with `$F/build.sh rel fuzz-misc`)

No patches were made to the source copy. All reproducers were re-verified on the plain release binary. `$F/runs/misc-*` is deleted; build dirs are untouched.

## Executions

Coverage-guided ASan build (-O), 60 s each, then plain release, 25 s each.

| Target | ASan | Release | Result |
|---|---|---|---|
| descript | 92,623 | 36,508 | no crash; rewrite property fails (D1, D2) |
| descript-line | 34,836 | 25,553 | no crash; line misread (D2) |
| descript-store | 92,752 | 35,735 | no crash; same causes as descript |
| tabfile | 67,570 | 65,156 | nothing |
| selection | 112,826 | 69,181 | 2 crashes (C1, C4) |
| settings (real `ConfigurationCenter.importSettings`) | 93,893 | 84,059 | 1 crash (C3) |
| lenient | 276,848 | 361,089 | 1 crash (C3) |
| pexpand | 111,425 | 49,579 | 1 crash (C2) |
| quote (release only, real `/bin/zsh -c` and `/bin/sh -c`) | — | 1,268 inputs | 150,800 expansion checks across both shells; 3 mismatch classes (Q1–Q3) plus one deviation the test tolerates (Q4) |

No hangs and no over-memory cases in the code under test. The one "rss" stop in settings was my harness leaking a test bench per input.

## Crashes

**C1 — critical (outside my group; found through the selection target).** `Sources/AFMKernel/Panels/Sorting.swift:54`, `Sorter.compareNames` calling `localizedCaseInsensitiveCompare`.
- Reason: CoreFoundation's `_CFCompareStringsWithLocale` frees/reallocs a stack buffer on macOS 27.0.1 (26A434) for certain name pairs, e.g. (128×U+0015 + U+FFFD + "a" + 66×"0") against "U+FFFD". The process aborts ("pointer being freed was not allocated"; ASan reports bad-free).
- Reach: listing a folder that holds such names sorts them.
- Reproducer: `sorter-cfcompare-abort.bin`, target `selection`. Standalone, no project code: `cf/cfcompare.swift` crashes with its defaults; `cf/cf2.swift` with `./cf2 128x15,1xFFFD,1x61,66x30 1xFFFD`. Compile either with `swiftc -O`.
- Fix: don't hand raw names to the localized compare; strip control characters for the collation key or compare precomputed sort keys, keeping the exact-bytes tie-break.

**C2 — high.** `Sources/Plugins/Configuration/ParameterExpansion.swift:364`, `from + length` overflows.
- Reason: `%N:~6,9223372036854775807` gives from = 6, length = Int.max.
- Reach: the parameters of a user command or Start-menu entry (also via an imported settings file), when the command is run.
- Reproducer: `pexpand-substring-length-overflow.bin`, target `pexpand`.
- Fix: `length >= all.count - from ? all.count : from + length`.

**C3 — high.** `Sources/Plugins/Places/DirectoryHistory.swift:98`, `counts[..., default: 0] += 1`.
- Reason: a stored count of Int.max, e.g. `"places.history.frequent":{"counts":{"<url>":9223372036854775807}}`.
- Reach: after importing such a settings file, the app traps every time that folder is visited (at every start if it is the start folder).
- Reproducers: `settings-import-frequent-count-overflow.json`, target `settings` (through the real import path); `frequentfolders-count-overflow.bin`, target `lenient`.
- Fix: clamp counts on decode, or use a saturating add.

**C4 — high.** `Sources/Plugins/Selection/SelectionFile.swift:19`, `text.data(using: .windowsCP1252, allowLossyConversion: true)`.
- Reason: Foundation raises an uncaught `NSInternalInconsistencyException` ("didn't convert all characters") for a marked name such as U+3000 U+0300; the process aborts.
- Reach: Save Selection To File (ANSI) with such a name marked.
- Reproducer: `selection-save-ansi-nsexception.bin`, target `selection`.
- Fix: convert per character with a `?` fallback instead of the lossy NSString call.

## Shell-quoting property

Results were identical in zsh and sh.

**Q1 — security, high.** `ParameterExpansion.swift:63-70`, `ShellWords.escaped` compares whole Characters, so a `"`, `\`, `$` or backtick carrying a combining mark is not escaped.
- Contexts affected: bare `%N` / `%P%N` / `%S` / `%T%N`, inside the user's double quotes, `%|VAR|`, and the Command field's `%VAR%` (`CommandLanguage.swift:106-107`). The single-quote context held in every case.
- Minimal counterexample: name `a"<U+0301>;touch PWNED;"<U+0301>` with parameters `%N` expands to `"a"́;touch PWNED;"́"`, and zsh runs `touch PWNED` (confirmed: the file was created).
- Reproducer: `quote-injection-combining-mark.bin`, target `quote-demo`.
- Fix: escape per unicode scalar or byte, or always emit single-quoted words with `'` → `'\''`.
- Same cause, by reading only: `name.hasPrefix("-")` at line 263 misses `-` plus a combining mark, so such a name gets no `./` prefix.

**Q2 — medium.** `ParameterExpansion.swift:139` trims `.whitespaces` from the finished text, which includes Unicode spaces that are never quoted.
- Minimal counterexample: name `a<U+00A0>` (also `report<U+3000>`) with `%N` yields argument `a` — potentially a different file.
- Reproducers: `quote-trailing-nbsp-trimmed.bin`, `quote-trailing-ideographic-space-trimmed.bin`, target `quote-demo`.
- Fix: trim only ASCII space and tab, or quote any Unicode whitespace.

**Q3 — low.** Foundation `Process` (`CommandRunner.swift:247`) passes arguments in decomposed form: name "ò" (C3 B2) arrives as 6F CC 80. Harmless on APFS; a different name on volumes that distinguish the two forms. See `quote-mismatch-argument-decomposed.txt`.

**Q4 — low; the test accepts it, so it is not counted as a mismatch.** `ParameterExpansion.swift:258`: `atWordStart` is true after any space, even inside the user's quotes, so `"pre %N post"` with name `-x` gives `pre ./-x post`.

Shortest mismatch per context and shell: `$F/repro/misc/quote-mismatches/`.

## descript.ion mismatches (low: comments misread or lost, no crash)

Run these with `FZ_DESCRIPT_ALL=1`; the driver otherwise filters them out so it can look for other failures.

**D1.** `Sources/Plugins/FileProperties/Descript.swift:55-57` together with `data()`.
- Reason: leading empty lines are dropped on rewrite, so a first name starting with bytes FF FE, FE FF or EF BB BF becomes a byte-order mark.
- Effect: after any comment edit the file reads differently, or not at all — all comments disappear and later edits are refused as "unreadable".
- Minimal: `0A FF FE`.
- Reproducers: `descript-rewrite-bom-collision.bin` (target `descript`); `descript-store-bom-name-lost.bin` and `descript-store-file-unreadable-after-edit.bin` (target `descript-store`).

**D2.** `Descript.swift:71-76` parses by Character.
- Reason: a separator space or quote that forms one character with its neighbour is not seen (a name ending in U+0600, a comment starting with a combining mark, `"<U+0301>"`).
- Minimal: `E3 83 D8 80 62`.
- Reproducers: `descript-line-misread-prepend-char.bin` and `descript-quoted-line-misread-combining-mark.bin` (target `descript-line`); `descript-rewrite-prepend-char.bin` (target `descript`).

Fix for both: parse and write on scalars or bytes, and never let a mark-free file begin with BOM bytes.

## Not fuzzed

- Imported `cm_` / `em_` / `afm_` / `cd` command steps were parsed (`CommandLanguage.steps`) but not performed, because some open windows; `cm_wait` timers were not run.
- Raw invalid-UTF-8 bytes cannot exist in a Swift String, so names were arbitrary Unicode scalars (including every U+0001–U+00FF) rather than raw bytes.
- The tab-file target replicates `FolderTabsPlugin.restore` / `replace` (private there) on real `PanelTabs` rather than calling the plugin command.
