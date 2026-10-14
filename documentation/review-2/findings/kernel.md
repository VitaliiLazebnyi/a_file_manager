# Review 2 — kernel

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### K001 [finding, critical] Sorter.compareNames aborts the process via localizedCaseInsensitiveCompare for certain names (CoreFoundation frees/reallocs a stack buffer)

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:54
- **Basis:** reproduced
- **Detail:** C1 (found through the selection target, outside the group). CoreFoundation's _CFCompareStringsWithLocale
  frees/reallocs a stack buffer on macOS 27.0.1 (26A434) for certain name pairs, e.g. (128 x U+0015 + U+FFFD + "a" + 66
  x "0") against U+FFFD. The process aborts ("pointer being freed was not allocated"; ASan reports bad-free). Reach:
  listing a folder that holds such names sorts them. Reproducer sorter-cfcompare-abort.bin, target selection. Standalone
  without project code: cf/cfcompare.swift crashes with defaults; cf/cf2.swift with
  `./cf2 128x15,1xFFFD,1x61,66x30 1xFFFD` (compile with swiftc -O).
- **Proposed fix:** Do not hand raw names to the localized compare; strip control characters for the collation key or
  compare precomputed sort keys, keeping the exact-bytes tie-break.
- **Source:** reports/22-fuzz-target-group-5-misc.md
- **Status:** open

### K002 [finding, critical] Process abort when sorting a listing (CoreFoundation localized compare)

**Outcome:** duplicate of K001 — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:54
- **Basis:** reproduced
- **Detail:** localizedCaseInsensitiveCompare: CoreFoundation's locale compare frees a stack buffer for certain name
  pairs (128 x U+0015 + U+FFFD + 'a' + 66 x '0' against U+FFFD) on this macOS build. Reproducer
  repro/misc/sorter-cfcompare-abort.bin (fuzz-misc, target selection); standalone demo in repro/misc/cf/.
- **Proposed fix:** Do not hand raw names to the localized compare; strip control characters or compare precomputed sort
  keys.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K003 [finding, high] totalSizeByListing recurses once per directory level with no depth limit or cycle guard; a deep ZIP or endless server tree crashes the app

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/FileSystem/FileSystemProvider.swift:391-396; Sources/AFMKernel/Support/Parallel.swift:221
- **Basis:** reproduced (synthetic provider)
- **Detail:** Evidence (t6 deep): a release build survives 4000 levels and dies with a bus error at 8000. The walk ran
  on a default 512 KB Thread, the same stack the pool's threads get. Reach: archive and remote file systems use this
  default (only local and virtual override). A ZIP with ~8k nested one-character folders crashes the app when Space is
  pressed on the folder (PanelViewController.swift:955). A server that returns a subfolder forever does the same, and
  never terminates before that.
- **Proposed fix:** An explicit work list instead of recursion, or a depth limit of a few hundred levels (returning what
  was counted), plus a larger stackSize for pool threads.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K004 [finding, high] A dead share can stop every folder from loading: PanelLoader.stream calls volume(of:) without a cancellation flag, leaving one blocked thread per refresh

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** Sources/AFMKernel/Panels/Listing.swift:80-81; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:753
- **Basis:** reproduced (stalled-provider wrapper); real mount inferred
- **Detail:** 82 blocked threads were enough that a local 300-file folder in the other panel did not open within 20 s
  (reproduced in both runs; main thread stayed responsive, max 30 ms). LocalFileSystem.volume(of:) uses resourceValues
  and statfs; a real dead mount was not tested so reproduction there is inferred. After leaving the share 8 calls stayed
  blocked (7 in volume(of:), 1 in places()) until the provider was released.
- **Proposed fix:** Run provider questions on a bounded queue per provider (or one in-flight volume(of:) per location),
  give volume(of:) a cancellation flag, and never queue a second read behind one that has not answered.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K005 [verdict, high] setComputedSizes with a filter is quadratic

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:715;
  Sources/Plugins/FileProperties/FilePropertiesPlugin.swift:254;
  Sources/Plugins/FileProperties/FilePropertiesPlugin.swift:276; Sources/AFMShell/Panel/PanelViewController.swift:973
- **Basis:** CONFIRMED (ran)
- **Detail:** Walks listedItems linearly for every name when a filter is set. For 10,000 sizes with filter active: 1M
  entries with 10k folders at head 0.38 s (51 ms without filter); 10k folders 0.26 s (1.5 ms); 100k folders 2.97 s (9
  ms); 1M folders (1,000 sizes measured) 7.96 s so ~80 s for 10,000 (100 ms without).
- **Proposed fix:** Look names up through one dictionary over listedItems, built once per call.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K006 [finding, high] One stalled Parallel job takes every pool thread including the 4x reserve, leaving every Parallel.map serial

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:226; Parallel.swift:150-167; Parallel.swift:49
- **Basis:** measured
- **Detail:** Workers always take open.first, the oldest job. If its pieces block (a size walk on a mount that stopped
  answering), every thread the watcher adds takes another piece of the same job and blocks too. Evidence (t8): a
  64-piece compute Parallel.map took 0.08 s on a healthy pool; with one stalled 5000-piece job it took 0.65-0.84 s,
  close to serial, with 64 threads all blocked, as long as the stall lasts. Consequence: every Parallel.map in the app
  runs on its caller alone, including main-thread ones (PanelModel.areSameEntries, any Sorter.sort fallback on main).
  Deadlock: none, a caller only waits for pieces already in flight.
- **Proposed fix:** Let extra threads (and preferably all workers) skip jobs whose in-flight pieces are all waiting, or
  take the newest job or round-robin. Cap the pieces of one job that may be blocked at once. Retire extra threads once
  runnable workers exceed width.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K007 [verdict, high] Blocked global-queue threads from PanelLoader.stream starve GCD pool

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** Sources/AFMShell/Panel/PanelLoading.swift:108; Sources/AFMShell/Panel/PanelViewController.swift:794;
  Sources/AFMShell/Panel/PanelViewController.swift:825; Sources/AFMKernel/Panels/Listing.swift:80-81;
  Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:752-760;
  Sources/AFMShell/Panel/PanelViewController.swift:816-820; Sources/AFMShell/Interaction/ProgressJobService.swift:78
- **Basis:** CONFIRMED (read + ran) mechanism; needs about 80 stuck threads
- **Detail:** Workers on DispatchQueue.global(qos: .userInitiated); Listing.swift calls provider.parent, root and
  volume(of:), plain system calls with no cancellation. Measured (16 cores, macOS 27.0.1): 200 blocks in a blocking
  read(): only 80 ever started; then probes on global at every QoS did not run within 3 s, asyncAfter on global did not
  run, a private serial queue still ran. A local folder load goes to the same global queue and starves, as do file jobs
  and archive flush timers. Caveats: quiet reloads do not stack (816-820), only explicit refreshes and navigations add a
  thread; not tested with a real dead mount.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### K008 [finding, high] Searching inside a large file in the viewer drives peak RSS to 44-97 GB (autoreleased NSData piles up in long-lived Parallel workers)

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:343; Sources/AFMKernel/Support/Parallel.swift:195;
  Parallel.swift:221; Sources/Plugins/Viewer/Model/ViewerSearch.swift:163
- **Basis:** measured (leak type inferred; heap/leaks hung)
- **Detail:** Footprint after 30 searches cancelled at random: 7.9 -> 85.5 GB (dense 4 GiB), 7.8 -> 66.2 GB (sparse),
  4.1 -> 37.6 GB (2 GiB line), 2.4 -> 15.2 GB (1 GiB newlines). One uncancelled forward search of the 4 GiB file added
  1.5 GB; the backward one another 2.4 GB. Isolation on a 64 MB file, 100 searches back to back: +60.8 MB per search at
  default parallelism against +1.0 MB with parallelism: 1; malloc in use 6.07 GB while pool threads alive, 13 MB 5 s
  after they exited. Footprint not returned afterwards (3.9-5.5 GB still charged; malloc_zone_pressure_relief freed 0).
  Inferred cause: autoreleased NSData from FileHandle.read(upToCount:) piles up in the long-lived AFM.Parallel workers,
  which never drain a pool (perform at :195, thread loop :221). Sources/ contains no autoreleasepool at all. The same
  pattern at smaller scale: footprint equals file size after indexing (3.9 GB for 4 GiB, 3.1 GB for 2 GiB, 1.3 GB for 1
  GiB), and a tree text search holds about 690 MB until its threads end.
- **Proposed fix:** Wrap each piece in autoreleasepool { } in ParallelPool.perform, and likewise in
  FileSearch.JobStack.work (FileSearch.swift:484) and the index scan (TextRows.swift:331/:344); or read with pread into
  owned buffers.
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### K009 [finding, high] Searching inside a large file in the viewer drives memory to 44-97 GB

**Outcome:** duplicate of K008 — see `status/kernel.md`

- **Where:** Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:343; Sources/AFMKernel/Support/Parallel.swift:195;
  Sources/Plugins/FindFiles/FileSearch.swift:484; Sources/Plugins/Viewer/Model/TextRows.swift:331
- **Basis:** measured (cause inferred)
- **Detail:** Footprint after 30 cancelled searches of the 4 GiB file went 7.9 -> 85.5 GB. On a 64 MB file each search
  added 60.8 MB at default parallelism against 1.0 MB with parallelism: 1; freed 5 s after the pool threads exited.
  Inferred cause: autoreleased NSData from FileHandle.read(upToCount:) accumulating in long-lived AFM.Parallel workers.
  Sources/ contains no autoreleasepool. (Relayed from the viewer fork, same as report 24 finding 1.)
- **Proposed fix:** Wrap each piece in autoreleasepool in ParallelPool.perform (Parallel.swift:195), and likewise in
  FileSearch.swift:484 and TextRows.swift:331.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K010 [finding, medium] S7: bulk marking on main: Select All 209 ms plus a 251 ms status recount; Invert 565 ms; select(mask:) 302 ms; operands 256 ms; selection 56 ms

**Outcome:** fixed — see `status/kernel.md`

- **Where:** AFMKernel/Panels/PanelModel.swift:638-652; AFMKernel/Panels/PanelModel.swift:744
- **Basis:** measured
- **Detail:** The plugin's Select All is 171 ms model-only per the fork.
- **Proposed fix:** A bit set by row instead of a name set, or do it in the background and apply once.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### K011 [finding, medium] Whole-list PanelModel operations at 1M entries cost 0.07-0.35 s on the main thread, and setComputedSizes with a filter active is linear per name

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:182-199; PanelModel.swift:638-642; PanelModel.swift:715;
  PanelModel.swift:744
- **Basis:** measured
- **Detail:** Measured at 1M entries (t7 model), time on main: selectAll 0.22 s; invertSelection 0.35 s; totals after
  select-all 0.26 s; update(with:) with nothing changed 0.07 s per refresh; setComputedSizes (200 names, filter active)
  0.15 s. With a filter active each name in setComputedSizes walks listedItems linearly (line 715): about 0.75 ms per
  name, so 10k sizes take about 7 s. The name index is rebuilt on main after every list change once three lookups
  happen.
- **Proposed fix:** Index listedItems too when filtered, build the key sets off-main or incrementally, and count
  all-selected totals from the list totals.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K012 [finding, medium] Background results are invalidated by changes that change nothing, and the fallback is full work on the main thread

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:215; PanelModel.swift:489-495; PanelModel.swift:537-541;
  PanelModel.swift:705; Sources/Plugins/ViewOptions/ViewOptionsPlugin.swift:200
- **Basis:** inferred (plausible); timings measured
- **Detail:** update(with:) bumps listVersion even when it returns false (via setListed -> listChanged).
  setComputedSizes and applyFilter bump it too though listedItems is unchanged. On a stale version
  setFilter(_:prefiltered:listVersion:) filters the whole list synchronously; ViewOptionsPlugin.swift:200 falls back to
  model.setSort(order) on main. Scenario: 1M-entry folder with a steady stream of file-system events or arriving Space
  sizes; each header click or quick-filter keystroke then runs on the main thread. Measured on main at 1M (16 cores):
  setSort 0.16 s for ASCII names; a direction flip of non-ASCII names 0.6 s because resort calls NSString.compare per
  adjacent pair (line 125). setSort(_:presorted:) only checks the count, so stale content of equal length is accepted
  silently if a caller skips the version check.
- **Proposed fix:** Bump the version only when listedItems really changed. On a stale version return false without doing
  the work so the caller restarts in the background.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K013 [finding, medium] PanelModel.Snapshot holds items but not filter or sort, so a failed open leaves a filtered subset with no filter shown, and restore can reinstate a stale order

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:247-278
- **Basis:** reproduced
- **Detail:** Filter: shell snapshots, drops the quick filter, then calls open (PanelViewController.swift:601-603). If
  the read fails, restore leaves filter == nil with items still the filtered subset; panel shows part of the folder with
  no filter indicated, totals count the subset; a later setComputedSize silently swaps in the whole list (line 719).
  Sort: if the order changed while the folder was opening, restore brings back the old order under the new sort; the
  next direction flip reverses a list not in the assumed order: asking for ascending gave c, b, a.
- **Proposed fix:** Put filter and sort in the snapshot, or re-derive items from listedItems on restore.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K014 [verdict, medium] Snapshot omits filter and sort

**Outcome:** fixed — see `status/shell-p2.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:247-278;
  Sources/AFMShell/Panel/PanelViewController.swift:601-603; Sources/AFMShell/Panel/PanelViewController.swift:657;
  Sources/AFMShell/Panel/PanelViewController.swift:783
- **Basis:** CONFIRMED (ran)
- **Detail:** Controller takes the snapshot, dropQuickFilter resets the filter, then open; restore at 657 and 783.
  Reproduced on the model: after restore 93 items shown of 1000 listed with filter == nil; sort says size-descending
  while items are in name order. Not a performance issue; persists until next refresh.
- **Proposed fix:** Store filter and sort in Snapshot and restore them; controller must restore its quickFilters entry
  too.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K015 [finding, medium] Releasing a million-item list on the main thread costs about 0.5 s (leaving the folder, every quiet reload, shutdown)

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:392
- **Basis:** measured
- **Detail:** Leaving the folder 515-574 ms stall; 200 quiet reloads collapsed into 18-19 list updates in 90 s each
  stalling 500-670 ms inside PanelModel.update(with:) releasing the old array; shutdown shows 503 ms.
- **Proposed fix:** Hand the old arrays to a background queue to release; consider not storing a URL per item.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K016 [verdict, medium] update(with:) / setListed with filter or marks is expensive on main

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:392-422; Sources/AFMKernel/Panels/PanelModel.swift:497-501;
  Sources/AFMKernel/Panels/PanelModel.swift:559-567
- **Basis:** CONFIRMED (ran); release figure lower than claimed
- **Detail:** At 1M, identical listing, main CPU: no filter no marks 26 ms; filter active 371 ms; all marked 413 ms;
  filter + 123k marked 808 ms (1.09 s wall). About 10x lower at 100k. Releasing the old array 110 ms at 1M, 10 ms at
  100k (not ~0.5 s), on main when oldItems goes out of scope. Release figure lower than claimed.
- **Proposed fix:** Do the filter and mark-pruning in the background task that already sorts; hand old arrays to a
  background queue to free.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K017 [verdict, medium] listVersion bumped by no-op refresh

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:410; Sources/AFMKernel/Panels/PanelModel.swift:215;
  Sources/AFMKernel/Panels/PanelModel.swift:416; Sources/AFMKernel/Panels/PanelModel.swift:705;
  Sources/AFMKernel/Panels/PanelModel.swift:549; Sources/Plugins/ViewOptions/ViewOptionsPlugin.swift:200;
  Sources/AFMKernel/Panels/PanelModel.swift:538-539
- **Basis:** CONFIRMED (ran)
- **Detail:** setListed -> listChanged() runs before areSameEntries; update(with:) on an identical listing returns false
  and version still goes 1->2. Other bumps that change no list: setComputedSizes (705), applyFilter with prefiltered
  list (549). Fallback on main: setSort 5-16 ms at 100k, 60-105 ms CPU (134-175 ms wall) at 1M; setFilter 32 ms at 100k,
  355 ms at 1M. With names hitting the slow sort path (claim 15) the sort fallback is single-threaded: 0.67-0.78 s for
  200k names.
- **Proposed fix:** Bump listVersion only when listedItems actually changed (in update after comparison, not in
  setComputedSizes, not in applyFilter); when stale, re-dispatch the sort or filter to the background.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K018 [finding, medium] Sort or filter with a filter active re-filters on main even on the good path

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:499
- **Basis:** measured
- **Detail:** setSort(_:presorted:) and update go through setListed, which re-filters on main: 378 ms at 1M, 32 ms at
  100k.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K019 [verdict, medium] selectAll / invertSelection / SelectionPlugin on main are O(n)

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:638-642; Sources/Plugins/Selection/SelectionPlugin.swift:258;
  Sources/Plugins/Selection/SelectionPlugin.swift:338-354
- **Basis:** CONFIRMED (ran)
- **Detail:** Linear, at 100k / 1M: selectAll 14 ms / 207 ms; invertSelection 23 ms / 340-442 ms; select(mask:) 18 ms /
  216 ms; select all files only (filter+map+setSelected) 55 ms / 919 ms; save+restore selection 22 ms / 358 ms;
  status-line totals afterwards 12 ms / 212 ms.
- **Proposed fix:** Keep marks as a bitset by row index (or 'all except' form) so all/invert/none are O(n/64); keep
  running selected totals instead of recounting.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K020 [finding, medium] Marking in a huge folder blocks the main thread 0.3-1.3 s (select all 351 ms, invert 281-404 ms, select group by mask 333,336 hits 1,266 ms)

**Outcome:** duplicate of K019 — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:640-642; Sources/Plugins/Selection/SelectionPlugin.swift:240-258
- **Basis:** measured
- **Detail:** PanelModel.selectAll / invertSelection and Selections.apply work on the whole list synchronously.
- **Proposed fix:** Compute the new mark set in the background above the same 20,000-item threshold used for sort and
  filter, then swap it in.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K021 [verdict, medium] Sort comparator is not a strict weak order

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:53-56
- **Basis:** CONFIRMED (ran, this machine's ICU)
- **Detail:** Sorter.compareNames rests on localizedCaseInsensitiveCompare, which is asymmetric: 'й' vs 'ий' returns
  descending in both directions. Russian letters и й е ё И Е я а, names up to 3 letters: 2,268 asymmetric pairs and
  48,631 intransitive triples. Also asymmetric for ž in Croatian, ñ in Spanish, å in Danish/Norwegian.
- **Proposed fix:** Define the order by the ICU collator itself (sort-key bytes, then name bytes as tie-break); strict
  weak order by construction, removes the gate, check pass and fallback.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K022 [verdict, medium] Slow sort fallback for non-ASCII names

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:53-56
- **Basis:** CONFIRMED (ran)
- **Detail:** 200k such names take 0.67-0.78 s on the calling thread against 14 ms for ASCII; result still has thousands
  of adjacent pairs against the definition. Danish with å/ø 0.57 s. Hungarian ASCII (gate off) 0.43 s vs 0.05 s.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K023 [finding, medium] The name comparison (localizedCaseInsensitiveCompare then compare) is not a total order: not antisymmetric in any locale, not transitive in da/nb/cy/es-traditional/hu/hr

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:53-56; Sorting.swift:181-200; Sorting.swift:312-327;
  Sorting.swift:695-709
- **Basis:** reproduced
- **Detail:** Tests t2, t3, t4. Not antisymmetric in any locale: compare("й","ийтф") and its reverse both return
  descending; about 10% of random и/й pairs and 2% of е/ё pairs; some ligature pairs (fi, ß, dz). Not transitive in
  Danish, Norwegian, Welsh, traditional Spanish, Hungarian, Croatian for plain ASCII (e.g. 'aBa' < 'AA' < 'aAB' but not
  'aBa' < 'aAB'). The ASCII gate is unsound: it passes for da, nb, cy and es@collation=traditional because 1- and
  2-character names agree, but longer mixed-case digraph names do not; Sorter.sort then returns lists with adjacent
  inversions against areInOrder (97 in 200 small lists for da; '1aA' before '1AA'). No counterexample in en, de, cs, sv,
  fi, pl, tr, ja, zh and others. Adjacent checking cannot restore a total order that does not exist: with и/й or е/ё
  present the check fails whichever way the pair lies, so every such sort pays the single-threaded exact re-sort and
  every streamed batch pays an exact re-merge. Cost at 1M Cyrillic names (t5): sort 0.56 s -> 1.15 s; streamed load 2.3
  s -> 6.1 s with worst single add 1.17 s; Hungarian ASCII names 0.55 s -> 2.0 s. Stability: result depends on the path
  taken (key sort, fallback, merge, reverse), so adding one non-ASCII file can reorder unrelated names. Memory safety
  holds with an inconsistent comparator.
- **Proposed fix:** Make ICU the definition: compare by secondary-strength sort key, then by bytes. A true total order,
  needs no gate or check, and is already computed.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K024 [verdict, medium] ASCII fast-path gate keysOrderPlainNames is unsound

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:695-709
- **Basis:** CONFIRMED (ran)
- **Detail:** Tests only 2-character names and returned true under da, nb, cy and es@collation=traditional. Pure-ASCII
  names then sort fast and unchecked, against the definition. Adjacent inversions in 1M names: da/nb 2,868; cy 5,960; es
  traditional 1,620. Example under Welsh: 'ddd' placed before 'ddf', which the definition orders the other way.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K025 [finding, medium] Extra pool threads retire only after 2 s idle, leaving 43 runnable threads on 16 cores after a stall ends

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift
- **Basis:** measured
- **Detail:** After the stall ended, 43 threads were runnable on 16 cores (t6 blocked) and stay so under continuous
  load.
- **Proposed fix:** Retire extra threads once runnable workers exceed width.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K026 [finding, medium] run() counts idle workers that an earlier run() already signalled, so a second job can be left without help and without the watcher armed

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:116; Parallel.swift:121
- **Basis:** read
- **Detail:** Second job can be left without help and without the watcher armed (line 121).
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K027 [finding, medium] The Parallel pool grows through a global queue so it stops adding threads when the global pool is exhausted

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:152
- **Basis:** read
- **Detail:** Pool growth goes through a global queue, so it stops adding threads in the same state (80 blocked global
  threads).
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### K028 [verdict, medium] No autorelease pool on Parallel pool threads

**Outcome:** duplicate of K008 — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:195-208; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:343
- **Basis:** CONFIRMED (ran) mechanism; 'tens of GB' figure unproven
- **Detail:** Bodies run with no pool; no autoreleasepool anywhere in Sources. Measured (same read as
  LocalFileSystem:343, 2048 MiB in waves through the real pool): malloc in use at end 1908 MiB as in the project vs 0
  MiB with autoreleasepool around each piece. In-use dropped to 0 once threads exited after 2 s idle but process
  footprint stayed at 1920 MiB. One pass over a 4 GiB file holds about 4 GiB. 'Tens of GB' figure unproven (needs
  repeated passes without a 2 s pause; not measured in app).
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### K029 [verdict, medium] Parallel workers always take the oldest job

**Outcome:** duplicate of K006 — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:226; Sources/AFMKernel/Support/Parallel.swift:161-166;
  Sources/AFMKernel/Support/Parallel.swift:125
- **Basis:** CONFIRMED (ran)
- **Detail:** open.first; threads added by watchLater take the same job. Measured: 64 CPU pieces of 50 ms took 0.24 s on
  16 threads alone, 3.73 s on 1 thread beside an older job whose pieces sleep; sleeping job grew to 61 threads. Later
  job not blocked (caller always works on it) but loses all parallelism until the older job has handed out every piece.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### K030 [finding, low] Byte-identical duplicate names in one listing make totals and selection counts disagree

**Outcome:** fixed — see `status/kernel.md`

- **Basis:** read
- **Detail:** No minimised reproducer kept.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K031 [finding, low] FileMask slowest pattern/name pair took 180 ms under ASan

**Outcome:** not a defect — see `status/kernel.md`

- **Basis:** measured
- **Detail:** No hang.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K032 [finding, low] ListingCache: a big listing can be freed under the lock (up to 300k entries, tens of ms)

**Outcome:** fixed — see `status/kernel.md`

- **Where:** AFMKernel/Panels/ListingCache.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### K033 [finding, low] setComputedSize copies the whole list when a background closure holds it (50 ms measured); with a filter on it does one linear search per name

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** AFMKernel/Panels/PanelModel.swift:710-719
- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### K034 [finding, low] Pool scheduling: pool threads always take open.first, so while an older job with slow I/O pieces is open, a later main-thread job gets no helpers (and watchLater threads take the old job too); main waits on a plain semaphore for .userInitiated threads with no priority donation

**Outcome:** fixed — see `status/kernel.md`

- **Where:** AFMKernel/Support/Parallel.swift:226
- **Basis:** read
- **Detail:**
- **Proposed fix:** Prefer the job opened by the highest-QoS caller, or by the main thread.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### K035 [verdict, low] Format.kilobytes traps near Int64.max

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMContracts/Format.swift:29; Sources/AFMShell/Panel/PanelViewController.swift:512;
  Sources/Plugins/FileProperties/SpaceCalculator.swift:116; Sources/Plugins/FileProperties/SpaceCalculator.swift:121;
  Sources/Plugins/SystemTools/DirectoryList.swift:117
- **Basis:** CONFIRMED (ran); reach unproven
- **Detail:** Int64.max crashes with signal 5 in debug and release; Int64.max - 512 is fine. Reach unproven: callers
  pass saturating sums so value reachable in principle (e.g. server listing with absurd sizes); whether remote parsers
  clamp sizes was not checked.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### K036 [verdict, low] Static NumberFormatter used across threads

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMContracts/Format.swift:6-12; Sources/Plugins/SystemTools/SystemToolsPlugin.swift:182;
  Sources/Plugins/DirectorySync/SyncSession.swift:176
- **Basis:** UNPROVEN (usage CONFIRMED, harm unproven)
- **Detail:** Called off main. Stress test 8 threads x 300,000 calls gave no wrong output and no crash; averaged ~10 us
  per call. Usage confirmed, harm unproven.
- **Proposed fix:** A hand-written digit grouper, also much faster.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K037 [finding, low] URL.appending(name:) accepts /, .. and NUL; only FileJob.isSafeName guards the copy engine

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/FileSystem/FileItem.swift:91-93
- **Basis:** read
- **Detail:** Other callers not verified.
- **Proposed fix:** A precondition or a sanitising variant in the kernel would make this safe by default.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K038 [verdict, low] totalSizeByListing recursion is unbounded

**Outcome:** duplicate of K003 — see `status/kernel.md`

- **Where:** Sources/AFMKernel/FileSystem/FileSystemProvider.swift:391-396
- **Basis:** CONFIRMED (ran) mechanism; real trigger PLAUSIBLE-unproven
- **Detail:** With a fake provider on a 512 KB thread stack a release build survives 2,000 levels and crashes at 4,000;
  debug crashes between 300 and 400. Local disks cannot nest that deep (path limit; LocalFileSystem has its own
  totalSize). Needs crafted archive or hostile server; not built. Related: FileJob's measure, deleteTree and
  transferFolder recurse per level too; not tested.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### K039 [finding, low] Panel load at the bottom of a 2,000-deep archive path takes 0.23 s of background CPU against 0.5 ms for the bare listing

**Outcome:** fixed — see `status/archnet-p2.md`

- **Where:** Sources/AFMKernel/Panels/Listing.swift:47-72
- **Basis:** measured
- **Detail:** Main thread does not stall. Cause not located; presumably the path climbing of PanelLoader.
- **Source:** reports/23-filejob-archives-stress.md
- **Status:** open

### K040 [finding, low] PanelLoader.stream calls provider.volume(of:) before the cancellable listing, which has no cancellation variant, parking an uncancellable thread per navigation on a stalled mount

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** Sources/AFMKernel/Panels/Listing.swift:80-81
- **Basis:** inferred (plausible)
- **Detail:** On a stalled mount each navigation attempt can park one more global-queue thread that cancel cannot reach.
  Also: the comment at lines 65-66 says an error after the first batch ends the listing with what has arrived, but line
  96 rethrows (the shell handles the throw).
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K041 [finding, low] PanelModel: a mark without a shown row after setSort

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift
- **Basis:** reproduced
- **Detail:** Root cause not analysed. Reproducer in repro/kernel/ (fuzz-kernel, target panel).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K042 [finding, low] hasIdenticalNames is only known once the lazy index is built; marking a duplicated name adds one file to cached totals while operands() returns two

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:129; PanelModel.swift:618-627; PanelModel.swift:723
- **Basis:** reproduced
- **Detail:** Before the index exists, marking a name that occurs twice in a gathered list adds one file to the cached
  totals, while operands() returns two and a recount says two.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K043 [finding, low] duplicate() copies a partial list but not isComplete/isRefreshing, so a tab duplicated mid-load claims to be complete

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:150-155
- **Basis:** reproduced
- **Detail:** The shell reloads it on activation; a tab opened with activate: false stays that way until then.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K044 [finding, low] Parallel.map on the main thread deadlocks (and crashes with signal 5 if every body does it) if a body hops to main via DispatchQueue.main.sync

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:427
- **Basis:** reproduced
- **Detail:** PanelModel.areSameEntries does call Parallel.map on the main thread, with pure bodies. The doc comment on
  Parallel.map does not forbid the hop. Sample saved.
- **Proposed fix:** Document the rule and assert it in debug builds.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K045 [finding, low] PanelModel: shown versus listed computed size differs after setComputedSizes

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:712-720
- **Basis:** reproduced
- **Detail:** Root cause not analysed. Reproducer in repro/kernel/ (fuzz-kernel, target panel).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K046 [finding, low] PanelModel selection: `Set<String>` merges NFC/NFD twin names

**Outcome:** not a defect — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/PanelModel.swift:97-102
- **Basis:** reproduced
- **Detail:** Reproducer in repro/kernel/ (fuzz-kernel, target panel).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K047 [finding, low] Switching to Unsorted from another key keeps the previous key's order; arrival order is lost until reload

**Outcome:** fixed — see `status/plugins-a-p2.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:111-117
- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K048 [verdict, low] Croatian ASCII digraphs (lj, nj) misorder

**Outcome:** refuted — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Panels/Sorting.swift:695-709
- **Basis:** REFUTED / not reproduced (ran)
- **Detail:** Not reproduced. Hungarian correctly has the gate off.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K049 [finding, low] FileMask matches by bytes: NFC mask misses NFD names, ? matches one byte, [ and backslash are fnmatch syntax, STRASSE* misses straße

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/FileMask.swift:19-27; FileMask.swift:49; FileMask.swift:75-85
- **Basis:** reproduced (t7 mask)
- **Detail:** An NFC mask does not match an NFD name: `café*` versus `cafe`+U+0301+`.txt` is false though String == says
  equal; names from HFS+ and many servers are NFD. ? matches one byte: caf?.txt does not match café.txt but caf??.txt
  does; ?.txt does not match an emoji name. [ and \ are fnmatch syntax: mask report[1].txt does not match file
  report[1].txt. STRASSE* does not match straße. Complexity fine: *a*a*a*a*a*b against 255 a's returns in microseconds.
- **Proposed fix:** Normalise mask and name to NFC, match over scalars, and pass FNM_NOESCAPE or escape [.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K050 [finding, low] While a blocked job has pieces left, the watcher re-arms every 20 ms indefinitely

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K051 [finding, low] Parallel pool does not add threads for waiting (sleeping) bodies: 256 bodies sleeping 100 ms took 1.67 s, as 16 threads would

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift
- **Basis:** measured
- **Detail:** Scenario 3 detail: 256 bodies that each sleep 100 ms took 1.67 s, the same as 16 threads would; the pool
  did not add threads for the waiting bodies.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K052 [finding, low] Parallel main-thread wait on a DispatchSemaphore donates no priority, and all pool work runs at .userInitiated regardless of caller QoS

**Outcome:** fixed — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:137; Parallel.swift:245
- **Basis:** read
- **Detail:** The main thread waits on a DispatchSemaphore (no priority donation) for workers at .userInitiated. Utility
  work such as ColumnValueStore is raised to .userInitiated.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K053 [verdict, low] Autorelease pool claim: 'tens of GB' figure

**Outcome:** duplicate of K028 — see `status/kernel.md`

- **Where:** Sources/AFMKernel/Support/Parallel.swift:195-208
- **Basis:** UNPROVEN
- **Detail:** One pass over a 4 GiB file holds about 4 GiB; tens of GB would need repeated passes without a 2 s pause;
  not measured in the app.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### K054 [finding, info] PanelModel.update -> Parallel.map and Sorter.sort when a piece arrives in the wrong order run on main (pure CPU, ms) but get no pool help while an older I/O job is open

**Outcome:** fixed — see `status/kernel.md`

- **Where:** AFMKernel/Panels/PanelModel.swift:435
- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### K055 [finding, info] Lock table notes: NameCollator.lock held across first collator build (CPU only); PauseGate threads poll every 0.1 s; FileJob.decisions held across monitor.ask (main.sync) and stop.cancel(); FileJob.counters held across emit -> monitor.report -> PauseGate (whole pause); OperationLog.flush does queue.sync from main at quit; SyncComparison progress callback under lock; archive L3 and L5 held for unbounded I/O; loginLock and connectLock held across askUser

**Outcome:** not a defect — see `status/kernel.md`

- **Where:** AFMKernel/Panels/Sorting.swift:647; AFMShell/Interaction/ProgressJobService.swift:153;
  Plugins/FileOperations/FileJob.swift:188; Plugins/FileOperations/FileJob.swift:193;
  Plugins/FileOperations/FileJob.swift:1409; Plugins/FileOperations/OperationLog.swift:57;
  Plugins/DirectorySync/SyncComparison.swift:40
- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### K056 [verdict, info] Pool-starvation claim 10: not tested with a real dead mount; quiet reloads do not stack

**Outcome:** duplicate of K007 — see `status/kernel.md`

- **Where:** Sources/AFMShell/Panel/PanelViewController.swift:816-820
- **Basis:** UNPROVEN (real dead mount untested)
- **Detail:** Only explicit refreshes and navigations add a thread; needs about 80 stuck threads.
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

## Checked and found sound

### K057 [sound, info] Listing: read, sort and merge happen in the background; reloadData at 1M rows is 0.6-3 ms and select-and-scroll 0.3 ms

- **Basis:** measured
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### K058 [sound, info] No lock-order cycle among the program's locks except L5 -> MAIN -> L5; no cycle through Parallel (caller waits only for pieces already taken, pool threads hold no lock while taking a piece, no caller holds a lock across Parallel.map)

- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### K059 [sound, info] ParallelPool: no lost wake-ups, nested calls cannot deadlock, closure never outlives the call, worker exit accounting correct. CancellationFlag handlers run outside the lock. ListingCache ticket/clock scheme rejects out-of-order stores

- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### K060 [sound, info] Pool nesting cannot deadlock

- **Basis:** reproduced
- **Detail:** A thread waiting on job J waits only for holders of J's pieces, and whatever those hold above the piece is
  strictly deeper in the job tree. Stress with 12 threads plus main and random nesting passed (t6 stress).
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K061 [sound, info] No lost wake-ups in the pool

- **Basis:** read
- **Detail:** Sleeper is created and checked under the lock, the semaphore counts, a timed-out idle worker re-checks
  open.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K062 [sound, info] Pool overhead is about 0.3 us per nested call (t6 storm)

- **Basis:** measured
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K063 [sound, info] Blocked-thread heuristic is sound

- **Basis:** read
- **Detail:** Mach port names are removed under the lock before a thread exits, so no stale ports. Conservative for
  threads that are computing.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K064 [sound, info] Main never waits on pool work that waits on main in the kernel

- **Basis:** read
- **Detail:** Main-thread Parallel.map bodies in the kernel are pure.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K065 [sound, info] askUser: no main-thread wait on an asking thread within the kernel

- **Basis:** read
- **Detail:** Main-thread semaphore waits elsewhere (VolumeMounting.unmount, CommandLine, OperationLog) were not traced.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K066 [sound, info] Sorter is correct where the comparison is a real order

- **Basis:** reproduced
- **Detail:** Fuzzing against a reference sort gave zero differences for sort, incremental merge and reversal, across
  all keys and directions, with duplicates and 2-9000 items, for ASCII in en, Latin accents, NFC/NFD, CJK/kana,
  ignorables and Turkic.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K067 [sound, info] Key building is correct

- **Basis:** read
- **Detail:** Buffer growth, 16-bit limits, the keyless fallback and the date bit mapping are correct. Fast and slow
  paths of FileItem.split agree.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K068 [sound, info] ICU access is correct

- **Basis:** read
- **Detail:** dlopen path, unversioned symbol names and attribute constants are correct.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K069 [sound, info] CancellationFlag is correct

- **Basis:** reproduced
- **Detail:** Handlers run exactly once under concurrent cancel and register; all call sites keep the token alive with
  withExtendedLifetime and capture weakly; isCancelled costs about 21 ns.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K070 [sound, info] Provider defaults have no forwarding cycle

- **Basis:** read
- **Detail:** totalSize, append and commit dispatch dynamically.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K071 [sound, info] ListingCache bounds, ticket logic and locking are correct

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K072 [sound, info] PanelModel caches: totals and index invalidation correct on every mutation path except findings 6 and 11; saturating sums hold

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K073 [sound, info] Shell streaming batches grow geometrically, so total merge cost is not quadratic

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K074 [sound, info] Shared state is sufficiently protected: ParallelPool (one NSCondition), Job.body, currentJob, CancellationFlag NSLock, NameCollator.cache, shared UCollator immutable, ListingCache, main-thread-confined PanelModel/PanelTabs/registries (asserted only in changed() and post(), debug builds only; no off-main caller found), FileSystemRegistry/ColumnRegistry/ServiceRegistry unsynchronised but written only during plugin start

- **Basis:** read
- **Detail:** MemorySettings has none (tests only). Format formatters unprotected: see finding 8.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K075 [sound, info] Scenario 3 Parallel.map torture: all correct, ordered, no deadlock

- **Basis:** measured
- **Detail:** 39 s, 19 MB, max stall 15 ms, threads 6->7 (peak 65). 10,016 small maps from 32 threads, nested depth 4 x
  width 16 (65,536 leaves), four such trees with 2,711 DispatchQueue.main.sync hops while main ran 2,051 maps, bursts
  around the 2 s thread retirement.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K076 [sound, info] Scenario 2 stalled provider: no provider call that actually blocked reached the main thread; main stayed responsive

- **Basis:** measured
- **Detail:** 23 actions + 100 refreshes, 49 s, 263 MB, max stall 158 ms; stalls 99/4/0; 55-80 ms per navigation are
  AppKit list rebuilds.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### K077 [sound, info] Kernel group: no trap in 917,259 asan and 1,053,579 rel executions

- **Basis:** reproduced
- **Detail:** Only 3 low PanelModel mismatches; a Sorter abort was found via group 5.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### K078 [sound, info] Viewer and MacIntegration menu closures already use cheap tests

- **Basis:** measured
- **Detail:** Not a cost source for per-key validation.
- **Source:** reports/31-verify-main-thread-scaling-findings.md
- **Status:** open

### K079 [sound, info] No actors, @MainActor or atomics; only async/await at Viewer/UI/RichViews.swift:208; only @unchecked Sendable at FileTools/Hashes.swift:459 (justified); all static mutable state locked or main-only

- **Where:** Plugins/Viewer/UI/RichViews.swift:208; Plugins/FileTools/Hashes.swift:459
- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

## Not covered / left behind

### K080 [gap, info] Not covered: kernel and other plugins' costs

- **Basis:** read
- **Detail:** PanelModel.hasOperandFile / operands, PanelSet.refresh with very many changed folders (called from sync,
  rename and compare completions), the settings store's set cost, and FileListService.show with 2M URLs.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### K081 [gap, info] The real SettingsStore implementation and its read-modify-write sequences (lives in the shell) were not reviewed

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K082 [gap, info] Plugin-side enabled closures evaluated per menu validation were not reviewed

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K083 [gap, info] Whether providers other than FileJob sanitise names was not checked

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K084 [gap, info] TSan and debug-build runs not done: all experiments were -O builds

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### K085 [gap, info] Run-time locale switching only reasoned about; the collator is re-read per sort, and a change mid-sort gives one inconsistent list

- **Basis:** read
- **Detail:**
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open
