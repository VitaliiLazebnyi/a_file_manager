# Fuzz harness

Coverage-guided fuzzing of everything in A File Manager that reads untrusted bytes or names: archives, network listings
and saved connections, checksum/decode/combine files, file masks, sorting and the panel model, descript.ion, tab and
selection files, settings import, parameter expansion and shell lines, the viewer's text model and search, diff and
rename masks.

It is a separate SwiftPM package (`pkg/`) that builds the project's own sources: `pkg/Sources` and `pkg/TestSupport` are
symbolic links to `../../../Sources` and `../../../Tests/TestSupport`. Nothing is copied and no product file is patched
(`results/PATCHES.txt`).

libFuzzer is not available with the Command Line Tools, so the fuzzer is its own (`pkg/Fuzz/FuzzCore`, `FuzzC`):
mutation with edge-coverage feedback, a watchdog (2 s and 2 GB per input by default), a supervisor that restarts the
worker after a crash, saves the input, groups findings by signature and can minimise them.

## Quick check (about 2 minutes, most of it the first build)

```text
Tests/Fuzz/replay.sh            # release build, every saved reproducer
Tests/Fuzz/replay.sh asan       # the same under AddressSanitizer
Tests/Fuzz/replay.sh rel quote  # only reproducers whose path contains "quote"
```

Prints `PASS` or `FAIL <signature>` per reproducer and exits 0 when none fails. The reproducers and what each one was
are listed in `repro/MANIFEST.tsv`; files under `repro/new/` named `<group>-<target>--<anything>.bin` are replayed too.
The replay itself takes under 10 seconds.

At the time of writing it ends with "replayed 41, failing 4": the 37 reproducers of the first campaign pass, and the
four under `repro/new/` are open defects (N1 to N4 in `documentation/review-2/status/harnesses.md`). They are meant to
fail until the product is fixed.

## Build

```text
Tests/Fuzz/build.sh rel             # all seven drivers, -O            -> out/build-rel/release/fuzz-<group>
Tests/Fuzz/build.sh asan            # -O, AddressSanitizer, coverage   -> out/build-asan/release/fuzz-<group>
Tests/Fuzz/build.sh asan fuzz-misc  # one driver
```

A first build takes 3 to 5 minutes per kind on 16 cores (`FUZZ_JOBS` sets the compile jobs, default 6); each kind needs
about 1 GB under `out/`.

## A timed campaign

```text
Tests/Fuzz/campaign.sh                       # 600 s per group, 3 groups at a time, ASan: about 30 minutes
Tests/Fuzz/campaign.sh 60 3 asan             # one minute per group: about 3 minutes
Tests/Fuzz/campaign.sh 600 2 rel misc diff   # only these groups, release build
```

The time of a group is shared equally between its targets. At the end a table shows executions, edges and findings per
target; the exit status is 0 when there is no finding. Each worker may use up to 2 GB of memory; three groups at a time
use three to six cores (the `sorter`, `zippack` and archive targets use more for moments).

One target by hand:

```text
B=Tests/Fuzz/out/build-asan/release
$B/fuzz-misc list
$B/fuzz-misc fuzz quote --out Tests/Fuzz/out/runs-asan/misc-quote --time 300 [--timeout 2] [--rss 2048] [--seeds DIR]
$B/fuzz-misc run quote-demo FILE... [--timeout S]      # one input; exit 0 = no failure
$B/fuzz-misc min pexpand FILE OUT [--timeout S]        # minimise, keeping the signature
```

A finding is saved as `out/runs-<kind>/<group>-<target>/findings/<signature>/<hash>.bin` with the worker's log beside
it. To keep one: minimise it, save it as `repro/new/<group>-<target>--<what>.bin` and it becomes part of `replay.sh`.

## Groups and targets

| Driver        | Targets                                                                                                                          | What is checked besides crashes, hangs and memory                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fuzz-arch`   | ziplist, tarlist, tgzlist, txzlist, zip, tar, tgz, txz, bz, zipmod, zippack                                                      | Nothing is written outside the unpack target, also through links that stand there already; no listed name is `.`, `..`, empty or holds `/` or a zero byte; a rewritten ZIP keeps its members; a ZIP packed with a password is AES-256 (AE-2) unless the old encryption is asked for, holds neither contents nor password in the clear, reads back with the right password and not with a wrong one                                     |
| `fuzz-net`    | ftplist, ftpreply, address, saved, sftpdec, sftpsession                                                                          | Entry names are one path component (by bytes); normalised remote paths hold no `..`; ports are 1…65535; a shown address hides the password                                                                                                                                                                                                                                                                                             |
| `fuzz-tools`  | checksum, verify, decodemem, decode, combine, parts                                                                              | Decode and Combine write only into the target; safe names by bytes, at most 255 bytes; part series end                                                                                                                                                                                                                                                                                                                                 |
| `fuzz-kernel` | filemask, sorter, panel, paneldup                                                                                                | `FileMask` against a slow reference of its documented rules (case and accent form do not count, `?` is one scalar, brackets are ordinary); the sort is a strict order (collation key, then bytes) and sort, merge, resort and `SortedFileList` agree with it, with and without the system's collator; marks belong to entries: `selectionCount`, `selectedNames`, `isSelected`, `operands()` and the totals agree with the marked rows |
| `fuzz-misc`   | descript, descript-line, descript-store, tabfile, selection, settings, lenient, pexpand, quote (and quote-demo for single names) | Comments survive a rewrite; a settings import (every part ticked) never traps and exports again; **shell lines**: see below                                                                                                                                                                                                                                                                                                            |
| `fuzz-viewer` | detect, boundaries, rows, search, html                                                                                           | Row index against a reference; raw, decoded, chunked and whole searches agree; a backwards search never returns the match at its start                                                                                                                                                                                                                                                                                                 |
| `fuzz-diff`   | myers, textdiff, inline, loader, renamemask, renameregex, planner, nametemplate                                                  | A diff turns one text into the other; rename masks and regexes end in time; no empty names from a template                                                                                                                                                                                                                                                                                                                             |

### The shell-line check (`quote`, `quote-demo`)

For hostile names (shell metacharacters, combining marks after quotes and backslashes, line breaks, payloads that would
`touch` a file) in 28 templates (`%N`, `"%N"`, `'%N'`, `%P%N`, `%S`, `%|VAR|`, the Command field's `%VAR%` …) the driver
builds what the program builds (`ShellLine.script`), starts real `/bin/zsh` and `/bin/sh` the way the program does
(`ChildProcess.spawn`, values as arguments) and requires:

1. nothing of a name ran: no file appears in the folder of the run;
2. `printf` (the builtin and, once per set, `/usr/bin/printf` as a program of its own) receives the name byte for byte;
   only a name that begins with `-` and is a word of its own arrives as `./-name`;
3. the text the shell reads is the same whatever the names are;
4. templates with a placeholder in an unsafe place (backticks, `$'…'`, a comment, arithmetic …) are refused.

`FZ_QUOTE_CONTROL=1` is a positive control: it pastes the values into the line as text; the check must then fail
(`quote-command-ran`). `-f` keeps zsh from reading the user's start files.

`FZ_VERBOSE=1` with `run settings FILE` prints what the import said and stored.

## Seeds

`seeds/{zip,tar,tgz,txz,bz}` hold archive seeds made by the system tools, by Python (hostile names) and by the program's
own packer; the other targets carry their seeds in the driver. To make them again: `seeds/make_seeds.sh`, then
`out/build-rel/release/fuzz-arch mkseeds Tests/Fuzz/seeds`.

## Where things go

| What                                   | Where                                                           |
| -------------------------------------- | --------------------------------------------------------------- |
| Build output, build logs               | `Tests/Fuzz/out/build-rel`, `out/build-asan`, `out/build-*.log` |
| Replay logs                            | `out/replay-rel/`, `out/replay-asan/`                           |
| Campaign corpus, findings, summaries   | `out/runs-<kind>/<group>-<target>/`                             |
| Files the targets write while running  | `$TMPDIR/afm-fuzz…` (or `$FZ_WORK`), removed when a run ends    |
| Reproducers kept                       | `repro/` (`MANIFEST.tsv`, `new/`)                               |
| Logs of the first campaign (report 30) | `results/`                                                      |

`out/` can be deleted at any time (`rm -rf Tests/Fuzz/out`) and should be ignored by version control.

## Limits

- bzip2 and foreign formats go through system tools (a process per input): few executions.
- The FTP and SFTP sessions are fuzzed at the parser and packet level, not over a socket.
- `repro/misc/cf/` is a standalone demonstration of the CoreFoundation abort behind the old sorting crash (no project
  code); `repro/misc/quote-mismatches/` are text reports of the first campaign, not inputs.
