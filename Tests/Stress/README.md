# Stress harness

Drives the real kernel, the 21 standard plugins and the real shell (window never shown, main run loop pumped for real)
through scenarios that are too big or too slow for the test targets, and measures the main thread while it does: a
watchdog pings it every 2 ms and records every answer later than 8 ms with the main thread's own processor time and
stack.

It is a separate SwiftPM package (`harness/`) that builds the project's own sources: `harness/Sources` and
`harness/TestSupport` are symbolic links to `../../../Sources` and `../../../Tests/TestSupport`. It never launches the
program itself.

## Quick check

```bash
Tests/Stress/quick.sh
```

Builds if needed (5 to 8 minutes the first time on 16 cores, 1.3 GB under `out/`), then runs seven small scenarios one
after the other: 6 minutes at a load average of 10 to 30 (measured), under 1 GB of disk and of memory. Exit status 0
when no scenario reported a failure.

`Tests/Stress/smoke.sh` (the `stress-smoke` gate of `Scripts/check.sh`) is smaller still: every harness once, on little
data and with fixed seeds (parallel, stalled, flood of 300 files, a panel of 2,000 files, the viewer on 4 MiB, FileJob
on 300 files, 1,000 archive members, Find Files on 2,000 files), about 4 minutes after the build. Logs: `out/smoke/`.

## Build

```bash
Tests/Stress/build.sh                 # all six harnesses, release with -enable-testing -> out/build/release/
Tests/Stress/build.sh StressPanel     # one
```

## Scenarios

```bash
Tests/Stress/run.sh <scenario> [arguments]
```

Each run takes a lock (two measured runs never overlap), has a time limit, makes its data under `$TMPDIR/afm-stress`
(`STRESS_DATA` to change), removes it afterwards (`STRESS_KEEP=1` keeps it) and is skipped when it would leave less than
20 GB free there (`STRESS_MIN_FREE_GB`).

| Scenario (number in report 25)                                                                                                        | Command                                                                                                                | Time on this machine (16 cores, loaded) | Disk                                                          | Peak memory                         |
| ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------- | ----------------------------------- |
| A million files in a panel (1): load, sort, quick filter, marking, cursor, validation, leave and return, 200 quiet reloads with churn | `run.sh million [files]`                                                                                               | 75 s to make the files + 2 to 3 minutes | about 4 GB (file-system records; the files hold 0 to 6 bytes) | 2 GB                                |
| A provider that stops answering (2): 23 actions, 100 refreshes of the dead share, then a local folder                                 | `run.sh stalled`                                                                                                       | 25 s                                    | none                                                          | 0.2 GB                              |
| `Parallel.map` torture (3) and the main-thread rule                                                                                   | `run.sh parallel`                                                                                                      | 40 s                                    | none                                                          | 0.2 GB                              |
| Watcher flood (8)                                                                                                                     | `run.sh flood [files] [per second] [seconds]` (default 20000 5000 20)                                                  | 30 s                                    | under 0.1 GB                                                  | 0.2 GB                              |
| Viewer on 64 MiB (7): memory per call, then the whole script                                                                          | `run.sh viewer64m`                                                                                                     | 50 s                                    | 64 MB                                                         | 0.25 GB                             |
| Viewer on 4 GiB (7), killed above 32 GB of memory (`STRESS_VIEWER_RSS_MB`)                                                            | `run.sh viewer4g`                                                                                                      | 10 s to write + 50 s                    | 4 GB                                                          | 0.5 GB since the fix (97 GB before) |
| Viewer, all four big files and truncation (7)                                                                                         | `run.sh viewerfull`                                                                                                    | about 5 minutes                         | 11 GB (4 GB of it sparse)                                     | as above                            |
| FileJob cancel/pause/resume (4)                                                                                                       | `run.sh jobs [files] [seeds]` (default 20000 3; report 25 used 20000 50 and 100000 4)                                  | 75 s; about 12 s per seed at 20k        | 1 to 4 GB                                                     | 0.2 to 0.4 GB                       |
| Archives (5): ZIP with many members, 16 readers + adder/commit + lister                                                               | `run.sh archives [entries] [seconds]` (default 50000 30; report 25 used 200000 90)                                     | 45 s                                    | 0.1 GB (0.3 GB at 200k)                                       | 0.5 GB (1 GB at 200k)               |
| Find Files (6): engine and window, cancel storm                                                                                       | `run.sh find [cancels] [million]` (default 20, tree of 100,000 files; `million` adds the 1M directory as in report 25) | 2 minutes (25 with `100 million`)       | 0.6 GB (+4 GB)                                                | 0.7 GB (12 GB with the million)     |

What a run prints (from `bin/summary.py`, the columns of the table in report 25):

```bash
== stalled.log
   exit 0, wall 24.9 s
   peak RSS 172 MB
   main thread: max stall 591.5 ms; stalls >8 ms 37, >100 ms 3, >1 s 0 (watched 23.46 s)
   threads: baseline(after start-up)=25 after shut-down=22
   load average during the run 18.3-21.5
```

The full log, `out/results/<scenario>.log`, has one `STEP` line per step (wall, CPU, threads, footprint, load), the
harness's own checks (`FAIL: …`, `FAILURES: n`), and the watchdog's table per phase with the stacks of the longest
stalls. Read the per-phase table before quoting the total: phases named `(harness …)` and stalls whose stack is harness
code (`verify`, ground truth, making files) are the harness working on the main thread, not the program.

## Reading the figures

- **Load.** Every figure depends on what else the machine does. `summary.py` prints the load average during the run; a
  stall whose `max cpu` is far below its length means the main thread had no core, not that it was working.
- **Threads.** The system's own queue threads come and go by two or three, so "before → after" is exact only to that.
  `parallel`, `jobs` and `archives` therefore count a thread that did not go away as a failure only when it is one of
  the program's own (named `AFM.…`; the pool's single `AFM.Parallel.watch` thread may stay).
- **The two child cases of `parallel`** (main thread inside `Parallel.map` while bodies call `DispatchQueue.main.sync`)
  are meant to hang and to trap: they show what breaking the rule does in a release build. They are reported, not
  counted as failures. Step 7b checks that the rule can be asked (`Parallel.isHoldingUpMainThread`).
- **`stalled`**: the provider stalls `item(at:)`, `volume(of:)`, `totalSize`, `entries`, `places`, `watch` and listings.
  `capabilities(for:)` answers at once, as the protocol requires, and is only counted. A stalled call that arrives on
  the main thread is recorded with its stack as a failure and answered, so the harness itself does not hang.

## Sanitizer runs of the project's test suite (Part A of report 25)

```bash
Tests/Stress/bin/sanitizers.sh tsan 3     # build with ThreadSanitizer into out/b-tsan, three runs of the suite
Tests/Stress/bin/sanitizers.sh asan 1
Tests/Stress/bin/sigpipe.sh 6             # PluginTests under TSan with a SIGPIPE backtrace trap
```

These build the root package (not this one), take 10 to 20 minutes per build and 3 to 5 GB.

## Where things go

| What                                      | Where                                          |
| ----------------------------------------- | ---------------------------------------------- |
| Build output and build logs               | `Tests/Stress/out/build`, `out/build-*.log`    |
| Logs of runs, samples of hangs            | `out/results/`                                 |
| The lock of measured runs                 | `out/measure.flock`                            |
| Sanitizer builds and logs                 | `out/b-tsan`, `out/b-asan`, `out/sanitizers/`  |
| Data (files, trees, archives)             | `$TMPDIR/afm-stress/` (removed after each run) |
| Logs of the first runs (reports 23 to 25) | `results/`, `logs/`                            |

`out/` can be deleted at any time and should be ignored by version control.

## Files

- `harness/Stress/StressKit` – watchdog, hang guard, steps, thread and memory figures.
- `harness/Stress/StressPanel` (`million`, `stalled`, `flood`; `StallFS.swift` is the silent provider),
  `StressParallel`, `StressJobs`, `StressArchives`, `StressFind`, `StressViewer`.
- `bin/run.py` – lock, time limit (samples and kills on expiry), memory limit.
- `bin/gen_million.py`, `bin/gen_zips.py` – data; `bin/summary.py` – the figures of a log.
