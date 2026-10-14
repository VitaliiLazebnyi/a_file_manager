# Fuzz target group 6 (viewer)

Task: fuzz target group 6 (Viewer model) with the driver in `Fuzz/fuzz-viewer`.

One trap and three wrong-result findings in search turned up; no hangs, no over-memory cases, and HTML is linear. Paths
below are relative to `$F` =
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/fuzz`.

## Executions

Sanitizer build is ASan with coverage guidance (`build-asan/release/fuzz-viewer`); volume build is plain `-O`
(`build-rel/release/fuzz-viewer`).

| target                                                               | ASan execs | release execs | crashes | hangs / over-memory | property mismatches         |
| -------------------------------------------------------------------- | ---------- | ------------- | ------- | ------------------- | --------------------------- |
| detect (detection, whole vs piecewise decode)                        | 106,109    | 640,318       | 0       | 0                   | 0                           |
| boundaries (`CharacterBoundaries` vs decode from start)              | 435,117    | 1,032,918     | 0       | 0                   | 0                           |
| rows (`TextDocument` / `TextRowIndex`, text, binary and hex layouts) | 37,747     | 300,541       | 1       | 0                   | 0                           |
| search (raw vs decoded, chunked vs whole)                            | 25,172     | 574,186       | 0       | 0                   | 3 signatures, 2 root causes |
| html (`HTMLText.plainText` vs the tests' reference)                  | 118,416    | 1,044,758     | 0       | 0                   | 0                           |

## Finding 1: arithmetic overflow trap in the row index

- **Severity:** critical by the rule (viewing a file), but only for an extreme file.
- **Site:** `Sources/Plugins/Viewer/Model/TextRows.swift:225`, `TextRowIndex.Segment.thin(spanning:)`:
  `while bytes / Int64(count) * Int64(step) < Int64(TextRowIndex.minimumCheckpointDistance) { step *= 2 }`
- **Reason:** a segment owns every row of the lines that begin in it, wherever they end. When it holds more checkpoints
  (one per 64 rows) than it is bytes long, `bytes / count == 0`, the loop never ends, and `step *= 2` overflows `Int`.
- **Concrete values:** columns 1, segmentSize 1, one 66-byte line gives 2 checkpoints for a 1-byte segment.
- **Reachability in the app:** with the 4 MiB segment it needs a single line of more than 268,435,456 rows. That is
  roughly a 27 GB file without line ends at 100 columns, or 2.7 GB in a 10-column window with wrap on.
- **Reproducer:** `repro/viewer/rows-thin-overflow.bin` (75 bytes); command
  `build-rel/release/fuzz-viewer run rows repro/viewer/rows-thin-overflow.bin`. I confirmed it on the unpatched release
  binary (SIGTRAP, "arithmetic overflow" at line 225).
- **Patch on the copy:** line 225 in `pkg/Sources` now has a `step < 1 << 40` guard so fuzzing could continue; it is
  recorded in `results/PATCHES.txt`. Revert that line to reproduce.
- **Suggested fix:** use `max(1, bytes / Int64(count))`, or derive the step directly from
  `count * minimumCheckpointDistance / max(1, bytes)`.

## Finding 2: backwards search returns the match at the start position

- **Severity:** high (needs the user to search); wrong result, no crash.
- **Site:** `Sources/Plugins/Viewer/Model/ViewerSearch.swift:225` (`.text` case of `search`); the range is
  `first ..< end + length - 1`.
- **Reason:** the range assumes a match is as long as the needle. Without case, "ss" matches the single unit "ß", so a
  match beginning exactly at `end` (the excluded start position) fits and is returned.
- **Counterexample:** text "Straße", pattern "ss", case-insensitive, backwards from 4 returns 4..<6; nothing should be
  found before 4.
- **User effect:** `TextPagerView.swift:508` starts a backwards search at `selection.lowerBound`, so Find Previous would
  return the same hit every time. I did not run the UI to confirm this.
- **Variant:** with the start inside a character, the returned match begins after the start
  (`repro/viewer/search-backwards-returns-match-after-start-midcharacter.bin`).
- **Reproducer:**
  `FZ_STRICT=1 build-rel/release/fuzz-viewer run search repro/viewer/search-backwards-returns-match-at-start.bin` (23
  bytes). Without `FZ_STRICT` the driver tolerates this known case.
- **Suggested fix:** after `range(of:)`, reject any hit with `found.location >= end` and keep searching before it; do
  not size the range by the needle's length.

## Finding 3: search result depends on path and chunk size when ignorable characters are involved

- **Severity:** low; inconsistent result, no crash. Both mismatch signatures (raw vs decoded, chunked vs whole) share
  this cause.
- **Site:** `ViewerSearch.swift:227`, `text.range(of: needle, options: [.literal, .caseInsensitive])`.
- **Reason:** once the text is not plain ASCII, Foundation's case-insensitive search ignores control and other ignorable
  characters (U+0000–0008, U+001B, U+200B and similar; not tab) on both sides. I checked this with a standalone NSString
  test. The raw byte path compares exactly, so the answer depends on which path a chunk takes.
- **Chunk-size dependence:** such matches differ in length from the needle, so the `range.length >= length` and
  `end + length - 1` arithmetic also makes the answer depend on chunk size.
- **Counterexamples:**
  - Pattern "\u{1B}9" in bytes `39 AE` (UTF-8): raw path nil, decoded path 0..<1. Reproducer:
    `run search repro/viewer/search-raw-vs-decoded-ignorable-characters.bin` (11 bytes).
  - Pattern "0\u{03}" in 72 bytes: chunked nil, whole 59..<60. Reproducer:
    `run search repro/viewer/search-chunked-vs-whole-ignorable-characters.bin` (81 bytes).
- **Suggested fix:** verify each NSString hit against the needle (folded units and length), or do the case-folded unit
  comparison yourself.

I believe all three are product bugs, not reference flaws. In findings 2 and 3 both sides of each comparison are the
product's own paths.

## HTML time

Linear. Slowest shapes in the release build, per 1024 UTF-16 units:

- `<a href="x">` repeated: 20–27 µs
- `&` repeated: 19 µs
- `<li>x`: 6–12 µs
- `&#x41`: 7 µs
- every other shape tried: under 3 µs

Each stays flat from 2 KB to 64 KB (×1 to ×32) across 17 shapes, including unterminated `<script>`, `<style`, `<!--`,
`<a href="` and `<svg><a>`. The 200 ms/KB the ASan stats recorded once did not reproduce (the same input takes 0.002 ms
in release).

## Limits of this run

- **Tiny sizes in the driver:** segment and chunk sizes go down to 1 byte, which is what exposed finding 1. The 150–250
  ms executions for 3.7 KB inputs in rows and search occurred with those 1-byte sizes, not the app's 4 MiB / 1 MiB.
- **Search coverage after the findings:** only the finding-2 case is tolerated in the driver. The finding-3 mismatches
  still stop a worker each time they occur, so search exploration past them was limited.
- **Not fuzzed:**
  - `ProviderByteSource`, `CachedByteSource` and `DiskBlockCache` (only `DataByteSource` was used)
  - cancellation mid-build
  - user-typed regular expressions (only a fixed list of harmless ones, so time measured is the search's own)
  - the UI layer and the RTF/PDF/image paths

## Left behind

- Driver: `pkg/Fuzz/fuzz-viewer/main.swift` and `HTMLReference.swift` (a copy of the tests' reference); there is also a
  `fuzz-viewer scale FILE` mode for the HTML scaling probe.
- Reproducers: `repro/viewer/` (5 files).
- Log: `results/viewer.log`; patch record: `results/PATCHES.txt`.
- All `runs/viewer-*` directories are removed; build directories are untouched.

Note for the parent: `min` leaves empty `fzrun-*` and `.fzrun-*` directories next to its OUT file when runs are killed.
I removed mine from `repro/viewer`.
