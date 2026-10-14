# Fuzz parsers under sanitizers

Fuzzing is finished for all seven groups: it found one write outside the unpack target, a shell-quoting command injection, seven crashes and three hangs, plus a set of low-severity mismatches. The archive parsers themselves did not crash, hang or over-allocate in about 2.4 million executions.

## Method

libFuzzer is not available with this toolchain (`-sanitize=fuzzer` is unsupported with the Command Line Tools), so I wrote a coverage-guided mutation fuzzer.

- **Builds:** "asan" is `-O` with AddressSanitizer and edge-coverage feedback; "rel" is plain `-O`, seeded with the asan corpus.
- **Limits:** 2 s per input and 2 GB RSS, enforced by a watchdog.
- **Crash handling:** a supervisor restarts the worker, saves the offending input, de-duplicates by top frame and minimises by delta-debugging.
- **Project directory:** not modified.
- **Fuzzing copy:** one same-line patch was made there (`TextRows.swift:225`, to get past viewer finding 13); it is recorded in `results/PATCHES.txt`.

Everything is under `F=/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/fuzz`. Build products are deleted, so rebuild first:

- Build: `$F/build.sh rel fuzz-<bin>`
- Reproduce: `$F/build-rel/release/fuzz-<bin> run <target> <file>`

## Executions

| Group | Targets | asan | rel | Result |
|---|---|---|---|---|
| 1 Archives | ziplist, tarlist, tgzlist, txzlist, zip, tar, tgz, txz, zipmod, bz | 1,214,545 | 1,142,276 | no crash, hang or over-memory; containment fails for a hand-made name (finding 1) |
| 2 Network | ftplist, ftpreply, address, saved, sftpdec, sftpsession | 3,515,177 | 3,047,481 | 1 crash, 1 hang, 1 mismatch |
| 3 FileTools | checksum, verify, decodemem, decode, combine, parts | 556,778 | 416,655 | no crash; containment fails in decode and combine (finding 1); 1 low mismatch |
| 4 Kernel | filemask, sorter, panel, paneldup | 917,259 | 1,053,579 | no trap in my runs; 3 low PanelModel mismatches; a Sorter abort was found via group 5 |
| 5 Misc | descript ×3, tabfile, selection, settings, lenient, pexpand, quote | 883,773 | 726,860 | 4 crashes, quoting injection |
| 6 Viewer | detect, boundaries, rows, search, html | 722,561 | 3,592,721 | 1 trap, 2 search bugs; HTML is linear |
| 7 Diff/rename | myers, textdiff, inline, loader, renamemask, renameregex, planner, nametemplate | 488,763 | 639,799 | 2 crashes, 2 hangs |

The shell-quoting test ran 150,800 expansion checks through real `/bin/zsh -c` and `/bin/sh -c`.

## Critical findings (reachable by opening or browsing untrusted data)

**1. Write outside the target folder (archives, decode, combine).**
- Sites: `Sources/Plugins/Archives/ArchiveTree.swift:82` (`normalized`), `Sources/Plugins/FileTools/Transcoding.swift:520` (`safeName`), `Sources/Plugins/FileTools/SplitCombine.swift:242`.
- Reason: names are split on `Character`. A `/` followed by a combining mark is one Character, so the separator is not seen and a leading `..` survives. The result is one file written into the parent of the target.
- This was found by a hand-made name after a related mismatch pointed at it, not by the mutation runs.
- Unpacking is a user action, so this would be "high" by your rule; I rank it critical because it is the outside-write case you flagged.
- Reproducers and targets:
  - `repro/arch/containment-slash-combining-mark.zip` — `fuzz-arch`, target `zip`
  - `repro/arch/containment-slash-combining-mark.tar` — `fuzz-arch`, target `tar`
  - `repro/tools/decode-containment-slash-combining-mark.bin` — `fuzz-tools`, target `decode`
  - `repro/tools/combine-containment-slash-combining-mark.crc` — `fuzz-tools`, target `combine`
- Fix: split and compare on UTF-8 bytes, as `RemoteEntry.isSafeName` already does, and verify the final URL lies below the target.
- Same class without a write: `RemotePath.normalized`, `Sources/Plugins/Network/ServerAddress.swift:65` (`repro/net/remotepath-slash-joins-combining-mark.bin`, `fuzz-net`, target `address`).

**2. Process abort when sorting a listing.**
- Site: `Sources/AFMKernel/Panels/Sorting.swift:54`, `localizedCaseInsensitiveCompare`.
- Reason: CoreFoundation's locale compare frees a stack buffer for certain name pairs (128×U+0015 + U+FFFD + "a" + 66×"0" against U+FFFD) on this macOS build.
- Reproducer: `repro/misc/sorter-cfcompare-abort.bin` (`fuzz-misc`, target `selection`); standalone demo in `repro/misc/cf/`.
- Fix: don't hand raw names to the localized compare; strip control characters or compare precomputed sort keys.

**3. Hang listing an FTP folder.**
- Site: `Sources/Plugins/Network/FTPListParser.swift:126-130`, the regexes used by `unix()`.
- Reason: a LIST line with a long digit run backtracks. 250 / 500 / 1000 / 2000 digits take 15 / 56 / 217 / 991 ms, so a 16 KB line takes about a minute.
- Reproducer: `repro/net/ftplist-regex-backtracking.txt` (`fuzz-net`, target `ftplist`, add `--timeout 0.5`).
- Fix: cap the line length and bound the digit runs (`\d{1,20}`).

## High findings (need a further user action)

**4. Shell-quoting command injection.**
- Site: `Sources/Plugins/Configuration/ParameterExpansion.swift:63-70`, `ShellWords.escaped`.
- Reason: it compares whole Characters, so a `"`, `\`, `$` or backtick carrying a combining mark is not escaped. A file name of that shape ran an injected command in zsh.
- Contexts: bare parameters, inside double quotes, `%|VAR|` and `%VAR%`; single quotes held.
- Reproducer: `repro/misc/quote-injection-combining-mark.bin` (`fuzz-misc`, target `quote-demo`).
- Fix: escape per scalar or byte, or always emit single-quoted words.

**5. Unicode trailing spaces trimmed from an expanded name.** `ParameterExpansion.swift:139`: a name ending in U+00A0 or U+3000 arrives without it, so it may name a different file. Reproducers: `repro/misc/quote-trailing-nbsp-trimmed.bin` and `quote-trailing-ideographic-space-trimmed.bin`.

**6. Crash on a saved connection with a negative port.** `Sources/Plugins/Network/ServerAddress.swift:48`, `components.port = port`; URLComponents traps. Reached through an imported or damaged settings file. Reproducer: `repro/net/saved-connection-port-trap.json` (`fuzz-net`, target `saved`). Fix: validate 1…65535 on decode.

**7. Crash in parameter expansion.** `ParameterExpansion.swift:364`, `from + length` overflows for `%N:~6,9223372036854775807`. Reproducer: `repro/misc/pexpand-substring-length-overflow.bin` (target `pexpand`).

**8. Crash after settings import.** `Sources/Plugins/Places/DirectoryHistory.swift:98`, `+= 1` on a stored count of Int.max; traps every time that folder is visited. Reproducer: `repro/misc/settings-import-frequent-count-overflow.json` (target `settings`).

**9. Abort saving a selection as ANSI.** `Sources/Plugins/Selection/SelectionFile.swift:19`: Foundation raises an uncaught exception for a name such as U+3000 U+0300. Reproducer: `repro/misc/selection-save-ansi-nsexception.bin` (target `selection`).

**10. Two crashes in name templates (New folder / New file).** `Sources/Plugins/FileOperations/NameTemplate.swift:352` (`last - start + 1`) and `:343` (`start + length - 1`) overflow on typed ranges near Int.max / Int.min. Reproducers: `repro/diff/nametemplate-slice-overflow.bin` and `nametemplate-slice-length-overflow.bin` (`fuzz-diff`, target `nametemplate`). Fix: limit the digits read, as `RenameMask` does.

**11. Hang in Multi-Rename.** `Sources/Plugins/MultiRename/RenameRules.swift:163-166`.
- Reason: a plain wildcard search with many `*` against a 250-letter name becomes a backtracking regex and ran over 60 s. The user regex `(a*)*b` does the same. The preview cannot cancel it.
- Reproducers: `repro/diff/renamemask-wildcard-backtracking.bin` (target `renamemask`, `--timeout 60`) and `renameregex-catastrophic.bin` (target `renameregex`).

**12. Backwards viewer search returns the match at the start position.** `Sources/Plugins/Viewer/Model/ViewerSearch.swift:225`. The range assumes a match is as long as the needle ("ss" matches "ß"), so Find Previous would repeat the same hit. Reproducer: `FZ_STRICT=1 … fuzz-viewer run search repro/viewer/search-backwards-returns-match-at-start.bin`.

**13. Viewer row-index overflow.** `Sources/Plugins/Viewer/Model/TextRows.swift:225`: `step *= 2` overflows when a segment holds more checkpoints than bytes. This is critical by your rule (viewing a file), but with the app's 4 MiB segment it needs a single line of over 268 million rows. Reproducer: `repro/viewer/rows-thin-overflow.bin` (target `rows`).

## Low-severity mismatches

- **Viewer search:** the result depends on path and chunk size when ignorable characters are involved (`ViewerSearch.swift:227`); two reproducers in `repro/viewer/`.
- **descript.ion:** comments are misread or lost after an edit, through a byte-order-mark collision (`Descript.swift:55-57`) and Character-based parsing (`:71-76`); six reproducers in `repro/misc/`.
- **PanelModel:** three reproducers in `repro/kernel/` (`fuzz-kernel`, target `panel`):
  - `selection: Set<String>` merges NFC/NFD twin names (`PanelModel.swift:97-102`).
  - A mark without a shown row after `setSort`; root cause not analysed.
  - Shown versus listed computed size differs after `setComputedSizes` (`:712-720`); root cause not analysed.
- **Identical names:** with byte-identical duplicate names in one listing, totals and selection counts disagree. No minimised reproducer was kept for this.
- **Checksum file:** the line `<digest> *` yields an entry with an empty name (`ChecksumFiles.swift:133-136`); `repro/tools/checksum-empty-name.md5`.
- **NameTemplate:** empty names from the list branch, and a `DateFormatter` built per name (about 13 s for `<0-99999>[d]`).
- **Process arguments:** they arrive in decomposed form, and `./` is prefixed inside the user's quotes.
- **FileMask:** the slowest pattern/name pair took 180 ms under ASan; there was no hang.

## Not fuzzed, or thin

- **bzip2:** 1,103 executions only, because each input starts `/usr/bin/bzip2`.
- **Foreign formats (7z, rar, …):** skipped, since they go through `bsdtar`.
- **Sorter:** about 2,400 executions in my driver; the 8,000-item parallel path and the reference sort make each input slow.
- **FTP session end to end:** only the pure parsers ran; an in-process fake server would be needed.
- **SFTP session:** the high rate for a process-per-input target (172,155 executions) suggests many inputs ended at connect. I did not confirm how deep it reached.
- **Absolute-path and symlink-to-absolute escapes:** only relative ways out were seeded.
- **Group 5:** imported command steps that open windows were parsed but not performed.
- **Group 6:** `ProviderByteSource`, the disk block cache, user-typed regexes and the RTF/PDF/image paths were not run.
- **Group 7:** `CompareSession` and the file-system parts of `RenameRun` were not run.

## Left behind

- Drivers: `$F/pkg/Fuzz/` (`FuzzCore`, `FuzzC`, `fuzz-arch`, `fuzz-net`, `fuzz-tools`, `fuzz-kernel`, `fuzz-misc`, `fuzz-viewer`, `fuzz-diff`), with `$F/pkg/Package.swift`
- Scripts: `$F/build.sh`, `run_arch.sh`, `run_seq.sh`, `run_rel.sh`, `seeds/make_seeds.sh`
- Seeds: `$F/seeds/`
- Reproducers: `$F/repro/{arch,net,tools,kernel,misc,viewer,diff}/`
- Logs: `$F/results/summary.log` (groups 1–4), `misc.log`, `viewer.log`, `diff.log`, `PATCHES.txt`
