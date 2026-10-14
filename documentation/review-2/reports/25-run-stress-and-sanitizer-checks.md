# Run stress and sanitizer checks

## Dynamic stress and responsiveness results for A File Manager

The threading model held up: zero sanitizer reports, no deadlock, no data loss. The UI-never-freezes requirement is not
met. The main thread saturates under a watcher flood, stalls 0.3–1.3 s on million-item operations, and a dead share can
stop all folder loading.

### Conditions that affect every number

- **The machine was never quiet.** Other agents ran a fuzzing campaign (`review2/fuzz`, several workers) plus unrelated
  processes, so load average was 8–45 on 16 cores throughout. The watchdog also records the main thread's own CPU time
  during each stall; where stall and CPU agree, the main thread was working, not starved.
- **Headless.** The shell was built as in ShellTests: real kernel, 21 plugins, real `Shell`, window never shown, main
  run loop pumped for real, main thread at user-interactive QoS. On-screen cost may differ.
- **Release build** with `-enable-testing`, so the `MainThread.assert` checks were off in the harnesses.
- **Early lock race.** My first measurement lock let runs overlap; I replaced it with `flock`. Overlapped runs were
  repeated, and the tables below use the repeats.
- Scenarios 4–7 were run by two forked agents; I relay their results and did not re-verify them.

### Part A — sanitizers and repeat runs (copy of the project, own scratch paths)

| Run                                          | Count                        | Sanitizer reports | Outcome                                               |
| -------------------------------------------- | ---------------------------- | ----------------- | ----------------------------------------------------- |
| TSan, full suite                             | 4 (3 + 1 with `symbolize=0`) | 0                 | every run had failures; none is a race report (below) |
| TSan, Kernel + Shell                         | 10                           | 0                 | 8 clean, 2 with one failing test each                 |
| TSan, PluginTests only (hunting the SIGPIPE) | 6                            | 0                 | 3 clean, 3 with timing failures                       |
| ASan + UBSan, full suite                     | 1                            | 0                 | 1 timing assertion failed                             |
| Normal, full suite                           | 10                           | —                 | 10 of 10 passed (84–123 s)                            |

No run hung or hit its timeout.

Positive controls: a deliberate race and a deliberate heap overflow in a tiny package were both reported with the same
options. With default symbolization, TSan blocks forever on `atos` in this environment. So "no report" in the first
three full runs and the ten Kernel + Shell runs rests on "no hang and no abort at exit"; the fourth full run used
`symbolize=0`.

Failures seen (all are expectation failures, not sanitizer findings):

- **Archive flush tests** — `changesAreWrittenShortlyAfterTheLastOne` (`ArchivesFileSystemTests.swift:253`) and
  `pendingChangesKeepAnArchiveAliveUntilTheyAreWritten` (`ArchivesFixTests.swift:407`). The 60 s wait for the flush
  expired in 6 of the 9 completed TSan runs that included PluginTests. They passed 3 of 3 in isolation under TSan and 10
  of 10 in normal builds. The flush timer runs at utility QoS (`OpenArchive.swift:714`).
- **`columnValuesAreComputedInTheBackgroundOnSeveralCores`** (`PanelPartsTests.swift:369`) — 1 of 10 Kernel + Shell
  runs. The work is dispatched at utility QoS (`ColumnValueStore.swift`, `work()`).
- **`aFolderThatFailsWhileAnotherReadingOvertook…`** (`RememberedListingTests.swift:138`) — 3 of 17 runs under TSan. The
  test has to observe a 0.4 s `isOpening` window by polling.
- **`aWideFolderResolvesNamesQuickly`** (`ConfigPlacesFixPlacesTests.swift:104`) — a 0.5 s performance assertion; failed
  once under TSan and once under ASan.
- **`aStaleFreeSpaceFigure…`** (`KernelApiLocalTests.swift:252`) — once; it asserts free space moved by less than 1 GB,
  while other agents were writing multi-GB files.
- **PluginTests process died with signal 13 (SIGPIPE)** once, in the fourth full TSan run, about 1,100 tests in. I
  re-ran PluginTests six times under TSan with an injected SIGPIPE backtrace trap and it did not recur, so the writer is
  unidentified. The product sets `F_SETNOSIGPIPE` on its two pipe writers (`SFTPChannel.swift:314`, `Codecs.swift:325`)
  and uses `NWConnection` for sockets.

### Part B — results per scenario

Stall = main thread answered a 2 ms ping later than 8 ms.

| #   | What ran                                                                            | Wall         | Peak RSS                        | Max stall                    | >8 ms / >100 ms / >1 s                                                                | Threads before → after | Load  |
| --- | ----------------------------------------------------------------------------------- | ------------ | ------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------- | ---------------------- | ----- |
| 1   | 1,000,200-entry real directory in a panel, full script                              | 166 s        | 3.2 GB                          | 1,266 ms (select by mask)    | 677 / 119 / 2 ¹                                                                       | 19 → 9                 | 13–19 |
| 2   | Provider that stops answering, 23 actions + 100 refreshes                           | 49 s         | 263 MB                          | 158 ms                       | 99 / 4 / 0                                                                            | 19 → 12                | 11–17 |
| 3   | `Parallel.map` torture                                                              | 39 s         | 19 MB                           | 15 ms                        | 1 / 0 / 0 (excluding the phase where the harness itself waits on the child processes) | 6 → 7 (peak 65)        | 12–14 |
| 4   | FileJob: 50 seeds × 20k files; 4 seeds × 100k files                                 | 611 s; 275 s | 157 MB; 409 MB                  | 15 ms; 33 ms                 | job phases 7/0/0; 16/0/0                                                              | 8 → 8–9 (peak 40)      | 8–21  |
| 5   | ZIP with 200,064 members, 60–90 s concurrent stage; deep ZIP                        | 108 s; 2.8 s | 985 MB; 96 MB                   | 17 ms concurrent, 49 ms open | 23 / 0 / 0                                                                            | 7 → 8                  | 8–38  |
| 6   | FindFiles on the 100k tree and the 1M directory, 2 × 100 cancels                    | ~1,400 s     | 11.6 GB (harness data included) | 589 ms (product)             | cancel phase 457 / 9 / 2 (both >1 s are harness)                                      | 19 → 9                 | 13–26 |
| 7   | Viewer: 4 GiB dense, 4 GiB sparse, 2 GiB single line, 1 GiB of newlines, truncation | 5 runs       | 43–97 GB                        | 202 ms                       | per file 3–44 / 0–1 / 0                                                               | 7–9 → 8–11 (peak 70)   | 11–24 |
| 8   | 5,000 changes/s for 20 s in a watched folder (20,000 and 2,000 files)               | 29 s; 27 s   | 206 MB                          | 278 ms; 222 ms               | flood phase 225/27/0; 244/19/0                                                        | 19 → 9                 | 17–21 |

¹ One of the two >1 s stalls in scenario 1 (4.4 s) is the harness listing the directory on the main thread, not the app.

#### Scenario 1 detail (second run; main CPU ≈ stall time unless noted)

- **Load:** first rows after 0.13 s (5,000 rows), complete after 4.2 s; worst stall 98 ms.
- **Sort** (name, extension, size, time, reversed) via the ViewOptions commands: 0.30–0.32 s each, one stall of 103–110
  ms each when the sorted list is taken over.
- **Quick filter**, one key at a time: 0.13–0.25 s per key, one stall of 77–109 ms per key.
- **Marking:** select all 351 ms, invert 281–404 ms, select group by mask (333,336 hits) 1,266 ms — all synchronous on
  the main thread.
- **Cursor:** the model call itself takes 0.1–0.3 ms. The run-loop turn after it costs much more:

  | Move                         | Main-thread cost per move                |
  | ---------------------------- | ---------------------------------------- |
  | Page Down, nothing marked    | 9 ms                                     |
  | Page Down, 333k marked       | 20 ms (52–61 turns over 100 ms in 1,000) |
  | Random row, 333k marked      | 12 ms                                    |
  | Insert (mark and move down)  | 8 ms                                     |
  | One row down, nothing marked | 3.6 ms                                   |

  A `sample` during the 1,000 Page Downs shows about 93 % of main-thread time in the Core Animation flush:
  `NSTableView layout` → `updateVisibleRowViews` → `tableView(_:viewFor:row:)`, plus layer display.

- **Validation with 333k marked:** the bar tick (`validateBars`) costs 0.05 ms. Asking all 332 commands costs 136–178
  ms, of which `cm_PrintFile` is 158 ms and `cm_ShowOnlySelected` 19 ms. Validating the Files menu costs 129 ms.
- **Leaving the folder:** 515–574 ms stall; the stack is the release of the 1M-item array on the main thread. Shut-down
  shows the same 503 ms.
- **Coming back:** remembered rows after 0.15 s, fresh listing after 4.3 s, five stalls of about 117 ms.
- **200 quiet reloads with churn and the live watcher:** the 200 requests collapsed into 18–19 actual list updates in 90
  s. Each update stalled the main thread 500–670 ms inside `PanelModel.update(with:)`, again releasing the old array.
  Afterwards the list matched the folder.

#### Scenario 2 detail

- No provider call that actually blocked reached the main thread; the 55–80 ms stalls per navigation are AppKit list
  rebuilds.
- Calls that did reach the main thread while the provider was silent (recorded with stacks, not held):
  - `capabilities(for:)` 379 times, from `ButtonBarView.validate` through a FileOperations enabled-closure;
  - `watch` twice, from `PanelCoordinator.updateWatchers` via `tabsChanged`.
- After leaving the share, 8 calls stayed blocked (7 in `volume(of:)`, 1 in `places()`) until the provider was released;
  all ended then.
- After 100 refreshes of the dead share, 82 threads were blocked and **a local 300-file folder in the other panel did
  not open within 20 s**. The main thread stayed responsive (max 30 ms). Reproduced in both runs.

#### Scenario 3 detail

- 10,016 small maps from 32 threads, nested depth 4 × width 16 (65,536 leaves), four such trees with 2,711
  `DispatchQueue.main.sync` hops while the main thread ran 2,051 maps of its own, and bursts around the 2 s thread
  retirement: all correct, ordered, no deadlock.
- Main thread inside `Parallel.map` with helper bodies calling `DispatchQueue.main.sync`: deadlock (sample saved). With
  every body calling it: crash, signal 5. The doc comment on `Parallel.map` does not forbid this.
- 256 bodies that each sleep 100 ms took 1.67 s, the same as 16 threads would; the pool did not add threads for the
  waiting bodies.

#### Scenarios 4–7, relayed from the forks

- **FileJob:** no file lost, no partial file under a final name, no `.afm-*.tmp` left, progress monotonic, every
  cancelled job ended within milliseconds. Against a `.deferredWrites` destination with 0–100 % commit failures (581
  good, 32 failed commits), no source was removed without a successful commit.
- **Archives:** 804,155 and 742,286 concurrent reads matched reference bytes and CRC; the archive passed `unzip -tq`,
  `zipinfo` and the app's own reader after each of 56 commits; cancelled reads ended a median 0.1 ms after the cancel
  (max 120 ms).
- **FindFiles:** every uncancelled search was complete and duplicate-free; cancels ended in a median 20 ms, max 549 ms.
- **Viewer:** first rows in 11–24 ms on every file; index time 0.15–3.4 s; no crash in 12 truncate/remove rounds.

### Findings, by severity

1. **High — searching inside a large file in the viewer drives memory to 44–97 GB.**
   - Footprint after 30 cancelled searches of the 4 GiB file went from 7.9 to 85.5 GB.
   - On a 64 MB file each search added 60.8 MB at default parallelism against 1.0 MB with `parallelism: 1`; it was freed
     5 s after the pool threads exited.
   - Inferred cause: autoreleased `NSData` from `FileHandle.read(upToCount:)` (`LocalFileSystem.swift:343`) accumulating
     in the long-lived `AFM.Parallel` workers. `Sources/` contains no `autoreleasepool`.
   - Fix: wrap each piece in `autoreleasepool` in `ParallelPool.perform` (`Parallel.swift:195`), and likewise in
     `FileSearch.swift:484` and `TextRows.swift:331`.

2. **High — a dead share can stop every folder from loading.**
   - `PanelLoader.stream` calls `provider.volume(of:)` before listing (`Listing.swift:80–81`). It takes no cancellation
     flag, so each refresh or navigation leaves one more thread blocked.
   - 82 blocked threads were enough that a local folder never opened in 20 s.
   - `LocalFileSystem.volume(of:)` (`LocalFileSystem.swift:753`) uses `resourceValues` and `statfs`; I did not test a
     real dead mount, so that this reproduces there is inferred.
   - Fix: run provider questions on a bounded queue per provider (or one in-flight `volume(of:)` per location), give
     `volume(of:)` a cancellation flag, and never queue a second read behind one that has not answered.

3. **High — a busy watched folder saturates the main thread.**
   - At 5,000 changes/s the panel applied 227–246 list updates in 20 s, each about 80 ms of main-thread CPU; the main
     thread spent 18.1–18.3 of 20 s inside stalls.
   - It is the same for a 2,000-file folder, so the cost is per update, not per item.
   - `rereadIfDirty` (`PanelViewController.swift:865`) starts the next read as soon as one ends, and every update calls
     `tableView.reloadData()` (`PanelViewController+Lists.swift:81`).
   - Fix: enforce a minimum interval between quiet reloads, growing with the cost of the last one; update only changed
     rows.

4. **High — every list change and cursor jump costs 9–110 ms on the main thread in the Full view.**
   - `FileListColumn.makeCell()` (`FileListColumn.swift:140`) still appeared in stall stacks seconds into a run, so
     cells were being created rather than reused in this headless setup. Whether an on-screen window reuses them needs
     checking in Instruments.
   - Fix: draw rows directly, as the grid view does, or use frame-based cells without Auto Layout.

5. **Medium — marking in a huge folder blocks the main thread 0.3–1.3 s.**
   - `PanelModel.selectAll` / `invertSelection` (`PanelModel.swift:640–642`) and `Selections.apply`
     (`SelectionPlugin.swift:240–258`) work on the whole list synchronously.
   - Fix: compute the new mark set in the background above the same 20,000-item threshold used for sort and filter, then
     swap it in.

6. **Medium — an enabled-closure builds the whole operand list.**
   - `SystemToolsPlugin.swift:54` calls `model().operands().filter…` to decide whether Print is enabled: 158 ms with
     333k marked, paid whenever the Files menu validates.
   - Fix: use `hasOperandFile` or a cached count.

7. **Medium — releasing a million-item list on the main thread costs about 0.5 s.**
   - Seen when leaving the folder, on every quiet reload (`PanelModel.update(with:)`, `PanelModel.swift:392`) and at
     shut-down.
   - Fix: hand the old arrays to a background queue to release; consider not storing a `URL` per item.

8. **Medium — Find window with about a million hits stalls 448–589 ms.**
   - `append(_:)` (`FindFilesWindowController.swift:352`) takes a whole folder's hits in one batch; `finish` (`:361`)
     rebuilds the rows on the main thread.
   - No hit appears until a folder is fully done: first hit after 5.2–5.7 s for a name search and 42–53 s for a text
     search in the 1M directory (`FileSearch.swift:365`).
   - Fix: flush by count as well as time, and deliver the tested prefix of a folder.

9. **Medium — utility-QoS work does not run for a minute or more when the cores are saturated.**
   - Evidence is the archive flush and column-value tests above; that QoS starvation is the cause is inferred. The
     alternative for the archive tests is the `min(60, 20 × lastRewriteDuration)` idle delay at `OpenArchive.swift:727`.
   - Fix: raise the flush timer's QoS after a deadline.

10. **Medium — `watch` is called on the main thread.**
    - `PanelCoordinator.updateWatchers` (`PanelCoordinator.swift:171`) reaches `DirectoryWatcher.resolve`, which calls
      `realpath`.
    - On a silent network mount that would block the window; not tested on a real mount.
    - Fix: set up watching off the main thread.

11. **Low — `Parallel.map` on the main thread deadlocks if a body hops to main.**
    - `PanelModel.areSameEntries` (`PanelModel.swift:427`) does call `Parallel.map` on the main thread, with pure
      bodies.
    - Fix: document the rule and assert it in debug builds.

12. **Low — one-off SIGPIPE death of the test process**, writer unknown. Worth a `signal(SIGPIPE, SIG_IGN)` at program
    start as a safety net.

13. **Low — smaller observations from the forks.**
    - One 202 ms main-thread wait on the viewer's index lock (`TextRows.swift:272`).
    - A file truncated during indexing ends "complete" with fewer rows and no error (`ByteSource.swift:139–153`).
    - About 1.4 KB of memory per ZIP member (272 MB for 200k).
    - `ArchiveStore.archive(at:)` holds a slot lock that made a main-thread `item(at:)` wait 418 ms during another
      thread's open; no shell code was found calling it on main.

### Not run, and why

- **No quiet-machine measurement** — the load came from other agents.
- **No real dead network mount;** the stalled provider is a wrapper around `MemoryFileSystem`. On the main thread it
  records a stalled call and answers instead of blocking, so a real freeze was not induced.
- **FileJob at 50 seeds × 100k files** would take about 40 minutes; run instead as 50 × 20k and 4 × 100k. Trash,
  cross-volume moves and moves into a real ZIP were not exercised.
- **`leaks` and `heap` hung on live processes,** so the leak type in finding 1 is inferred from malloc statistics and
  the `parallelism: 1` control.
- **Debug-build runs of the harnesses** (which would enable `MainThread.assert`) were not done.
- **Scenario 1's reload step was capped at 90 s:** a 1M-entry reload takes 4–6 s, so 200 distinct reloads do not fit.
- **Scenarios 6 and 7 were run once each at full scale.**
- **FindFiles and Viewer tables were never drawn;** remote, spill-to-disk and double-byte paths in the viewer were not
  exercised.

### Clean-up

All data directories (the 1M-file directory, panel work folders, forks' trees, archives and viewer files) and all build
directories are removed. `du -sh` of the stress folder reports 19 MB: harness sources, the mirror copy, scripts, logs
and results. No process of mine is left, and the project directory was not modified.

Everything is under
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/stress/`:

- `harness/Stress/` — StressKit (watchdog) and the six harnesses
- `bin/run.py` — locked runner with timeout and sampling
- `results/` — per-scenario logs; start with `million-2.log`, `stalled-2.log`, `flood-2.log`, `flood-2k.log`,
  `parallel.log`, `million-4-cursor.sample.txt`
- `logs/` — Part A logs and the sanitizer controls
