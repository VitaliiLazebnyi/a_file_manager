# FindFiles + Viewer stress

Scope: scenario 6 (FindFiles) and scenario 7 (Viewer model) only. Both ran to completion at full scale with no crash,
hang, deadlock, wrong result or thread leak. The one severe result is memory: searching inside a large file in the
viewer drove peak RSS to 44–97 GB.

All full-scale runs went through the fixed flock lock, release build with `-enable-testing`, main thread at
user-interactive QoS. Load was not quiet: 26 → 13 for the find run and 11–24 for the viewer runs, mostly from the
harness itself using all cores. My first find run overlapped another run under the old lock; I killed it and it is not
used here.

## Scenario 6 — FindFiles

Driven two ways: `FileSearch.run` directly, and the real `FindFilesWindowController` headless (`prepare` / `startSearch`
/ `cancelSearch`, never shown), so the window's own batching was used and no mock was needed. Ground truth came from
independent readdir plus byte scan. The headless table was never drawn, so on-screen cost would be higher.

Data: tree of 100,002 files in 2,000 folders (903 MB, including two 256 MB files); the shared flat directory of
1,000,000 files plus 200 folders.

| Search                                        | Results   | Engine total / first result | Via window total / first rows | Stalls >8 ms / >100 ms / >1 s (window phase) | Max stall                             |
| --------------------------------------------- | --------- | --------------------------- | ----------------------------- | -------------------------------------------- | ------------------------------------- |
| tree, name `*.txt`                            | 80,000    | 0.33 s / 3–9 ms             | 0.34 s / 0.11 s               | 3 / 1 / 0 (harness)                          | 451 ms (harness)                      |
| tree, text                                    | 1,129     | 3.0–3.2 s / 0.65–0.72 s     | 4.5 s / 2.2 s                 | 9 / 0 / 0                                    | 32 ms                                 |
| million, name `*7.png`                        | 16,667    | 5.2–5.7 s / 5.15–5.65 s     | 5.4 s / 5.4 s                 | 1 / 0 / 0                                    | 10 ms                                 |
| million, text `xxxx`                          | 99,750    | 42.7–53.4 s / 42.0–52.9 s   | 42.0 s / 42.0 s               | 118 / 0 / 0                                  | 59 ms                                 |
| million, everything                           | 1,000,200 | 13.0–13.3 s / 12.8–13.1 s   | 13.4 s / 13.0 s               | 5 / 1 / 0                                    | 589 ms                                |
| 100 searches cancelled at random, via window  | —         | 751 s                       | —                             | 457 / 9 / 2                                  | 2140 ms (harness); product max 543 ms |
| 100 engine runs cancelled from another thread | —         | 588 s                       | —                             | 61 / 0 / 0                                   | 23 ms                                 |

- **Correctness:** every uncancelled search was complete and duplicate-free, two runs gave the same order, and 8
  concurrent searches of the tree were all complete. Cancelled searches listed only a duplicate-free subset of the
  truth. Searches after the torture were still complete.
- **Cancellation:** 88 window cancels ended in median 20 ms, p95 489 ms, max 549 ms; 12 finished before the cancel.
  Engine `run` returned in median 12.5 ms, p95 492 ms, max 558 ms. None hung.
- **Threads:** baseline 19, 8–29 right after each round, 9 within 0.5 s of the last search.
- **Memory:** peak RSS 11.6 GB for the whole run, harness data included. A tree-only run showed no growth: malloc in use
  was about 690 MB while the search threads lived and 143 MB 5 s later, flat over 20 further text searches. A shorter
  million run ended at 1.1 GB in use (harness truth sets plus the window's kept result sets).
- **CPU:** the whole run used 1,415 s user and 6,439 s system; the million text search took 209–389 CPU-seconds for
  43–53 s wall.
- **Stall attribution:** the two stalls over 1 s and several others are my own result checking on the main thread, per
  their stacks. Product frames appear in six stalls of 448–589 ms (below) and two AppKit layout passes of 120 and 248 ms
  while every core was busy.

## Scenario 7 — Viewer

Driven through the real `TextPagerView` (headless) on `CachedByteSource(ProviderByteSource.open(...))`, as `ViewerPane`
does for a local file. On top of that, 6 threads called `rows` / `row(containing:)` / `row(ofLine:)` with random cancels
and 2 threads ran `ViewerSearch.find`, which the `TextDocument` contract allows. Files were freshly written, so the page
cache was warm.

| File                                                | First rows | Index time                       | Rows / lines    | Relayout (wider / wrap 40 / no wrap) | Whole-file search | Stalls >8 ms / >100 ms / >1 s | Max stall        | Threads base → storm peak → end | Peak RSS |
| --------------------------------------------------- | ---------- | -------------------------------- | --------------- | ------------------------------------ | ----------------- | ----------------------------- | ---------------- | ------------------------------- | -------- |
| 4 GiB dense text                                    | 17 ms      | 0.61 s                           | 53.4 M / 53.4 M | 1.92 / 1.72 / 0.64 s                 | 1.04 s            | 44 / 0 / 0                    | 58 ms            | 7 → 70 → 9                      | 96.9 GB  |
| 4 GiB sparse (2 MiB text per 8 MiB)                 | 11 ms      | 0.85 s                           | 37.9 M / 13.3 M | 1.36 / 1.12 / 0.85 s                 | 0.84 s            | 23 / 0 / 0                    | 45 ms            | 7 → 67 → 9                      | 79.7 GB  |
| single 2 GiB line                                   | 24 ms      | 3.37 s (7.5 CPU-s, not parallel) | 16.6 M / 1      | 3.83 / 4.15 / 2.99 s                 | 0.38 s            | 30 / 1 / 0                    | 202 ms           | 7 → 65 → 8                      | 43.9 GB  |
| 1 GiB of `\n`                                       | 14 ms      | 0.15 s                           | 1.07 G / 1.07 G | ≤1 ms each (256/256 segments reused) | 0.13 s            | 3 / 0 / 0                     | 29 ms            | 9 → 64 → 8                      | 42.9 GB  |
| truncate/remove during indexing, 12 rounds on 1 GiB | —          | ended within 1.5 s each          | —               | —                                    | —                 | 16 / 12 / 0 (all 12 harness)  | 309 ms (harness) | 9 → 42 → 11                     | 26.5 GB  |

- **Row fetches after indexing:** mean 0.15–0.26 ms, max 5.6–27 ms; on the single line mean 3.2 ms, max 8 ms. Round-trip
  checks (`rows` → `row(containing:)` → `row(ofLine:)`, last row ends at end of file) passed on all four files.
- **Storm:** 40 relayouts during indexing with readers, searchers and Esc all ended with the last layout indexed and the
  same rows and lines as the first.
- **Search cancel:** the search returned at most 3.7 ms after the cancel.
- **Relayout reuse** could not show on the dense file: my generator put one over-long line in every MiB, so every
  segment legitimately needed rescanning.

## Findings, by severity

1. **High — memory explodes when searching inside a large file.**
   - Footprint after 30 searches cancelled at random: 7.9 → 85.5 GB (dense 4 GiB), 7.8 → 66.2 GB (sparse), 4.1 → 37.6 GB
     (2 GiB line), 2.4 → 15.2 GB (1 GiB newlines).
   - One uncancelled forward search of the 4 GiB file added 1.5 GB; the backward one added another 2.4 GB.
   - Isolation on a 64 MB file, 100 searches back to back: +60.8 MB per search at default parallelism against +1.0 MB
     with `parallelism: 1` (calling thread only). Malloc in use was 6.07 GB while the pool threads were alive and 13 MB
     5 s after they exited.
   - The footprint was not returned afterwards (3.9–5.5 GB still charged; `malloc_zone_pressure_relief` freed 0).
   - Inferred cause: autoreleased `NSData` from `FileHandle.read(upToCount:)`
     (`Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:343`) piles up in the long-lived `AFM.Parallel` workers,
     which never drain a pool (`Sources/AFMKernel/Support/Parallel.swift:195` `perform`, `:221` thread loop). `Sources/`
     contains no `autoreleasepool` at all. The call site is `Sources/Plugins/Viewer/Model/ViewerSearch.swift:163`.
   - Fix: wrap each piece in `autoreleasepool { }` in `ParallelPool.perform`, and likewise in `FileSearch.JobStack.work`
     (`FileSearch.swift:484`) and the index scan (`TextRows.swift:331`/`:344`); or read with `pread` into owned buffers.
   - The same pattern at smaller scale: footprint equals file size after indexing (3.9 GB for 4 GiB, 3.1 GB for 2 GiB,
     1.3 GB for 1 GiB), and a tree text search holds about 690 MB until its threads end.

2. **Medium — 448–589 ms main-thread stalls in the Find window with about 1 M hits.**
   - `append(_:)` (`FindFilesWindowController.swift:352`) took 498–589 ms: all hits of one folder arrive as a single
     batch, because `walk` (`:280`) only flushes in `onDirectory`.
   - `finish(items:groups:)` (`:361`) took 448–543 ms: it rebuilds `rows` from `resultItems`, counts directories and
     frees the old rows, all on the main thread.
   - Fix: flush by count as well as time (a few thousand per main-queue block), and in `finish` keep the rows already
     shown, with the directory count carried along from the search thread.

3. **Medium — no result appears until a whole folder is done.**
   - In the 1 M-file folder the first hit came after 5.2–5.7 s for a name search (13 s for "everything") and after 42–53
     s for a text search; the window showed only "[Searching...]" until then.
   - `Walk.deliver` (`FileSearch.swift:365`) waits for `node.pending == 0`, meaning the folder is fully listed and every
     candidate tested.
   - Fix: deliver the already-tested prefix of a folder's candidates while the rest are pending, and stream the listing
     in batches.

4. **Low/Medium — one 202 ms main-thread stall on the index lock.**
   - The main thread waited in `TextPagerView.isIndexing` (`TextPagerView.swift:260`) → `TextRowIndex.isComplete`
     (`TextRows.swift:284`, `NSLock` at `:272`).
   - It happened once, on the single-line file, with about 65 threads contending in the storm; not seen on the other
     files or without the hammer.
   - Inferred: lock-holder preemption. Fix: `os_unfair_lock` or atomics for the counters the main thread reads.

5. **Low — a file truncated during indexing is reported as complete with no error.**
   - The document ended with `isIndexComplete == true`, `indexedThrough == length` and `readError == nil` but fewer rows
     (e.g. 3.09 M instead of 13.35 M); `rows(from:)` then returned empty for known rows 704,854 times without an error.
   - Removal of the file is reported correctly through `readError`. No crash or hang in any of the 12 rounds.
   - Short reads are treated as end of text (`ByteSource.swift:139–153`, `TextRows.swift:561`). Fix: record an error
     when a read inside `0..<length` comes back short.

6. **Low — cancel-to-finished reaches about 0.55 s** when a search of the 1 M folder is cancelled (p95 489 ms), in the
   engine itself. Inferred: freeing the million-item candidate list.

7. **Observation — a pager stopped with `stopReading()` reports `isIndexing == true` forever** (the document is
   cancelled, never completed). My first smoke run waited on this indefinitely; it looks like the design, but anything
   that waits for indexing to end must handle it.

## Not run / limits

- `heap` and `leaks` on the live process hung, so the leaking object's type is inferred from in-process malloc
  statistics and the `parallelism: 1` control.
- Remote, spill-to-disk and double-byte code-page paths were not exercised (local UTF-8 only).
- Spotlight and duplicate search modes were not run.
- Each scenario was run once at full scale.

## Reproduce

With S =
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/stress`:

```text
cd $S/harness && swift build -c release -Xswiftc -enable-testing --scratch-path $S/b-harness --product StressFind    # and StressViewer
$S/b-harness/release/StressFind gen $S/data/findtree
python3 $S/bin/run.py --timeout 2400 --log $S/results/find-full-1.log -- /usr/bin/time -l $S/b-harness/release/StressFind run $S/data/findtree $S/data/million $S/results 100 1
$S/b-harness/release/StressViewer gen $S/data/viewer
python3 $S/bin/run.py --timeout 1500 --log $S/results/viewer-dense4g.log -- /usr/bin/time -l $S/b-harness/release/StressViewer run $S/data/viewer/dense4g.txt $S/results 1
$S/b-harness/release/StressViewer truncate $S/data/viewer $S/results 12
$S/b-harness/release/StressViewer leak <any 64 MB text file> $S/results
```

Sources are `$S/harness/Stress/StressFind/main.swift` and `$S/harness/Stress/StressViewer/main.swift`. Logs are in
`$S/results/`: `find-full-1.log`, `find-tree-memory.log`, `find-million-memory.log`,
`viewer-{dense4g,sparse4g,line2g,newlines1g,truncate,leak-isolation,smoke64m}.log` and
`viewer-smoke64m-stuck.sample.txt`.

## Cleanup

`$S/data/findtree` and `$S/data/viewer` are removed (`du` reports "No such file or directory" for both), and none of my
processes are left. `$S/data/million` and `$S/data/panel` are not mine and were left untouched.
