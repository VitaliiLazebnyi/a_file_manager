# FileJob + Archives stress

Scenarios 4 (FileJob) and 5 (Archives) are done: no invariant violation, crash, hang or deadlock in any run, and no
main-thread stall over 100 ms attributable to the app.

`$S` =
`/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/stress`.
All builds are release with `-enable-testing`. The main thread ran the real run loop at user-interactive QoS with the 2
ms watchdog. The machine was never quiet (other agents were building and running); the load average is given per run.

## Scenario 4 — FileJob

Jobs ran through the shell's real `ProgressJobService`, headless (no window, so the progress view is never rendered). A
controller thread paused, resumed and cancelled at random times; cancels went half via the main thread and half directly
on the job handle from a background thread. Questions were answered through `monitor.ask`, as `JobBridge` does.

Each seed runs: copy, delete of what arrived, move on the same volume (half the folders merged file by file, half
renamed whole), and move back. After every job, both trees were surveyed byte for byte.

| Run                        | Size                                          | Jobs (cancelled)             | Wall  | Peak RSS | Main stalls in job phases: >8 ms / >100 ms / >1 s, max                                                  | Threads base / max / settled | Load before→after |
| -------------------------- | --------------------------------------------- | ---------------------------- | ----- | -------- | ------------------------------------------------------------------------------------------------------- | ---------------------------- | ----------------- |
| `jobs-50seeds-20k.log`     | 20,006 files, 400 folders, 64 MB, 50 seeds    | 274 local (95) + 60 deferred | 611 s | 157 MB   | copy 3/0/0, 15.0 ms; delete 0, 7.8 ms; move 1/0/0, 8.5 ms; move-back 0, 5.7 ms; deferred 3/0/0, 14.9 ms | 8 / 40 / 8–9                 | 15.8→16.7         |
| `jobs-full-100k-rerun.log` | 100,012 files, 2,000 folders, 225 MB, 4 seeds | 26 (8)                       | 275 s | 409 MB   | copy 1/0/0, 17.4 ms; delete 3/0/0, 13.8 ms; move 5/0/0, 16.1 ms; move-back 7/0/0, 33.3 ms               | 10 / 38 / 9                  | 7.9→21.1          |
| `jobs-full-100k.log`       | same tree, 8 seeds                            | 47                           | 594 s | 414 MB   | not usable (see below)                                                                                  | 8 / 39 / 8                   | 12.2→44.2         |

- **Invariants, all runs:**
  - no file lost;
  - no partial or different file under a final name;
  - no `.afm-*.tmp` left behind;
  - every job ended (cancelled jobs within milliseconds of the cancel);
  - no job reported an error or counted a failure;
  - progress never went backwards or past its total;
  - threads returned to baseline within 8 s.
- **Deferred-writes target:** 60 moves from disk to a `MemoryFileSystem` claiming `.deferredWrites`, with commit failure
  rates of 0/20/50/100 %, batch sizes 7/40/250/10,000 and random cancel/pause. There were 581 good and 32 failed
  commits; 40,258 sources were removed and 139,922 kept. No source was removed unless a successful commit covered its
  write (renames into place counted as writes).
- **Rates, uninterrupted, 100k tree (rerun):** copy 6.0k files/s (16.7 s), delete 22k files/s, move with half merged
  16.9k files/s.
- **Noise floor:** while the harness verified trees on 16 threads and the main thread only pumped, 2–3 % of pings
  exceeded 8 ms (max 87 ms). The few >8 ms pings in job phases are below that floor.
- **Polluted run:** the first 100k run is correct for invariants only. Its four stalls over 100 ms (max 128 ms) came
  from my harness statting 2,000 paths on the main thread (the one sampled stack shows it), and it overlapped other
  runs. I fixed the harness and re-ran.
- **Scaled down:** 50 seeds × 100k files would take about 40 minutes at the measured rates, so I ran 50 seeds at 20k and
  4 + 8 seeds at 100k.

## Scenario 5 — Archives

The plugin's real `ArchiveStore` and `ArchiveFileSystem` were used with the default 1 s flush delay; listings went
through `PanelLoading`.

| Run                           | What                                                             | Wall       | Peak RSS | Main stalls >8 ms / >100 ms / >1 s, max       | Threads base / settled | Load      |
| ----------------------------- | ---------------------------------------------------------------- | ---------- | -------- | --------------------------------------------- | ---------------------- | --------- |
| `archives-big.log`            | 200,064-member ZIP (96 MB), 90 s concurrent stage                | 108 s      | 985 MB   | concurrent 23/0/0, 16.7 ms; open 1/0/0, 49 ms | 7 / 8                  | 23.9→34.8 |
| `archives-big-2.log` (seed 2) | same, 60 s concurrent stage                                      | 61 s stage | 932 MB   | concurrent 9/0/0, 17.0 ms                     | 7 / 8                  | 38.3→7.9  |
| `archives-deep.log`           | 2,000-deep chain, 8,191-folder binary tree, one 60,000-byte path | 2.8 s      | 96 MB    | 0/0/0, 3.7 ms                                 | 7 / 8                  | 30.7→29.8 |

The only stalls over 100 ms in the big runs are the harness's own main-thread loop (and `leaks` suspending the process).

- **Open and list:** the first root listing of the 200k archive took 0.46–0.47 s off the main thread. A second listing
  took 1 ms, a 500-entry folder 1.3 ms, and all 400 folders 0.36 s on one thread or 0.17 s on 16.
- **Concurrent stage:** 16 readers over 64 probe members (0 B to 24 MB, stored and deflated, 30 % cancelled at random,
  20 % with a seek), one adder committing 1–20 new members at a time, one lister.
  - 804,155 and 742,286 reads completed and matched the reference bytes and CRC.
  - 13,419 and 11,088 reads were ended by cancel; the read ended a median 0.1 ms after the cancel, p95 4 ms, max 120 ms.
  - No read returned wrong bytes and none failed without a cancel.
- **Commits:** 30 + 26, median 0.48 s and 0.36 s (max 0.72 s) for adding at most 20 members. After every commit
  `unzip -tq` reported no errors, `zipinfo` listed every new member, and a fresh reader of the program's own found the
  right member count and read back the new members identically.
- **Deep archive:** every level listed (slowest 0.5 ms), every node read, and a member added at the bottom and
  committed. Python's `zipfile.testzip()` passed. `unzip -tq` returns status 1 ("filename too long") on the pristine
  file as well, so that is the tool's limit.
- **Memory:** no unbounded growth. Footprint plateaued around 670–690 MB during the stage and fell to 287 MB after
  `store.close()`, of which about 230 MB is harness reference data.

## Findings

Nothing of high severity. In order:

1. **Low/medium — memory per archive member.** Opening the 200,064-member ZIP raised the footprint by 272 MB, about
   1,425 bytes per member (same in both runs). The likely holders are `ArchiveEntry` with its full `ZipRecord`
   (`Sources/Plugins/Archives/ArchiveTree.swift:5`, `ZipFormat.swift:28`). A fix would be to keep names as slices of the
   central-directory buffer and build the full record only on write.
2. **Low — `item(at:)` without a cancellation flag waits for another thread's open.** Called on main 20 ms after another
   thread began opening the 200k archive, it returned after 418 ms. The wait is the unconditional `slot.lock.lock()` in
   `ArchiveStore.archive(at:)` (`ArchiveFileSystem.swift:40–57`). On an already open archive each call costs about 29 µs
   and re-stats the archive file through `isCurrent()` (`OpenArchive.swift:475`). I found no shell code calling it on
   the main thread; this is what such a caller would wait. A fix would be to answer from the already-open archive
   without taking the slot lock, and rate-limit `isCurrent()` for local files as is already done for remote ones.
3. **Low — panel load at the bottom of a 2,000-deep path takes 0.23 s** of background CPU, against 0.5 ms for the bare
   listing. The main thread does not stall. I did not locate the cause; it is presumably in the path climbing of
   `PanelLoader` (`Sources/AFMKernel/Panels/Listing.swift:47–72`).
4. **Info — commit cost on the large archive:** 0.33–0.72 s per commit on the committing thread, during which other
   listings waited at most 125–160 ms.

## Not run

- `leaks(1)` on the archive harness sat at 0 % CPU for 13 minutes; I killed that child. The no-leak statement rests on
  the footprint series only.
- Trash deletes, cross-volume moves, and moves into a real ZIP via `FileJob` were not exercised; the deferred-writes
  case used the `MemoryFileSystem` wrapper as specified.

## Reproduce

Build:
`cd $S/harness && swift build -c release -Xswiftc -enable-testing --scratch-path $S/b-harness --product StressJobs`
(same for `StressArchives`).

- Jobs:

  ```sh
  python3 $S/bin/run.py --timeout 2400 --log $S/results/x.log -- /usr/bin/time -l $S/b-harness/release/StressJobs --root $S/data/jobs --files 20000 --folders 400 --big 6 --seeds 50 --memseeds 60 --results $S/results
  ```

  (100k: `--files 100000 --folders 2000 --seeds 4 --seedbase 20`).

- Archives: `python3 $S/bin/gen_zips.py $S/data/archives 200000 2000`, then
  `StressArchives --mode big --dir $S/data/archives --entries 200000 --seconds 90 --results $S/results` and
  `--mode deep --chain 2000`, each through `run.py` as above. Regenerate `big.zip` before each big run.

Sources are in `$S/harness/Stress/StressJobs/main.swift`, `$S/harness/Stress/StressArchives/main.swift` and
`$S/bin/gen_zips.py`. Logs are `$S/results/jobs-*.log` and `$S/results/archives-*.log`.

## Cleanup

`$S/data/jobs`, `$S/data/archives` and both smoke directories are removed; `du -sh` reports "No such file or directory"
for both. The harness binaries copied to `$S/bin` are removed as well.
