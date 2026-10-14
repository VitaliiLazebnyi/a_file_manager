# Review kernel concurrency core

# Second-round review: AFMKernel and AFMContracts

I read every file in both modules and ran standalone experiments against a copy of the kernel sources. The copy was built with `swiftc -O` on a 16-core machine; no project file was touched. The pool's nesting logic is deadlock-free, but there are three high-severity problems: one crash from a hostile archive or server, one crash from deep trees, and one pool starvation behind a stalled mount.

Experiments are in `/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/review2/kernel/` (`t1`–`t8`, each a `main.swift` compiled with the copy in `src/`).

## Findings

### 1. HIGH · security (crash) · `Sources/AFMContracts/Format.swift:29` · confirmed
`Format.kilobytes` computes `(value + 512) / 1024`, which traps for any value above `Int64.max - 512`.
- **Trigger:** a ZIP64 entry declaring an uncompressed size of `0xFFFF…FF`, or an SFTP server reporting such a size. `OpenArchive.swift:287` and `SFTPChannel.swift:52` clamp it to `Int64.max`; two entries of 2^62 also saturate the total to `Int64.max`. The status line then calls `Format.kilobytes(totals.totalBytes)` at `PanelViewController.swift:512`.
- **Evidence:** the trap reproduced (exit 133, `t7 format`), and the model returns `Int64.max` for two 2^62 items. The chain was verified link by link, not run end to end in the app.
- **Also affected:** `DirectoryList.swift:117`, `SpaceCalculator.swift:116/121`.
- **Fix:** `value / 1024 + (value % 1024 >= 512 ? 1 : 0)`.
- **Related, low, plausible:** `Format.speed` (line 47) and `Format.duration` (line 52) convert a `Double` to an integer and trap on non-finite or huge values, e.g. remaining time for a near-`Int64.max` `bytesTotal` at under 1 B/s.

### 2. HIGH · freeze/performance · `Sources/AFMKernel/Support/Parallel.swift:226, 150-167, 49` · confirmed
One stalled job takes every pool thread, including the 4× reserve.
- **Cause:** workers always take `open.first`, the oldest job. If its pieces block (a size walk on a mount that stopped answering), every thread the watcher adds takes another piece of the same job and blocks too.
- **Evidence (`t8`):** a 64-piece compute `Parallel.map` took 0.08 s on a healthy pool. With one stalled 5000-piece job it took 0.65–0.84 s, close to serial, with 64 threads all blocked. This lasts as long as the stall.
- **Consequence:** every `Parallel.map` in the app runs on its caller alone, including the main-thread ones (`PanelModel.areSameEntries`, any `Sorter.sort` fallback on main).
- **Deadlock:** there is none. A caller only waits for pieces already in flight.
- **Further defects in the same code:**
  - Extra threads retire only after 2 s with nothing open. After the stall ends, 43 threads were runnable on 16 cores (`t6 blocked`) and stay so under continuous load.
  - `run()` counts idle workers that an earlier `run()` already signalled (line 116). The second job can then be left without help and without the watcher armed (line 121).
  - While a blocked job has pieces left, the watcher re-arms every 20 ms indefinitely.
- **Fix:** let extra threads (and preferably all workers) skip jobs whose in-flight pieces are all waiting, or take the newest job or round-robin. Cap the pieces of one job that may be blocked at once. Retire extra threads once runnable workers exceed `width`.

### 3. HIGH · security (crash) · `Sources/AFMKernel/FileSystem/FileSystemProvider.swift:391-396`, `Parallel.swift:221` · confirmed with a synthetic provider
`totalSizeByListing` recurses once per directory level with no depth limit and no cycle guard.
- **Evidence (`t6 deep`):** a release build survives 4000 levels and dies with a bus error at 8000. The walk ran on a default 512 KB `Thread`, the same stack the pool's threads get.
- **Reach:** the archive and remote file systems use this default (only local and virtual override it). A ZIP with ~8k nested one-character folders crashes the app when Space is pressed on the folder (`PanelViewController.swift:955`). A server that returns a subfolder forever does the same, and never terminates before that.
- **Fix:** an explicit work list instead of recursion, or a depth limit of a few hundred levels (returning what was counted), plus a larger `stackSize` for pool threads.

### 4. MEDIUM · correctness/performance · `Sources/AFMKernel/Panels/Sorting.swift:53-56, 181-200, 312-327, 695-709` · confirmed
The comparison that defines the order (`localizedCaseInsensitiveCompare`, then `compare`) is not an order. Tests `t2`, `t3`, `t4`.
- **Not antisymmetric, in any locale:** `compare("й", "ийтф")` and its reverse both return descending. About 10 % of random и/й pairs and 2 % of е/ё pairs behave this way; some ligature pairs (ﬁ, ß, ǆ) too.
- **Not transitive:** in Danish, Norwegian, Welsh, traditional Spanish, Hungarian and Croatian, for plain ASCII names (e.g. `'aBa' < 'AA' < 'aAB'` but not `'aBa' < 'aAB'`).
- **The ASCII gate is unsound:** it passes for `da`, `nb`, `cy` and `es@collation=traditional` because 1- and 2-character names agree, but longer mixed-case digraph names do not. `Sorter.sort` then returns lists with adjacent inversions against `areInOrder` (97 in 200 small lists for `da`; `'1aA'` before `'1AA'`). No counterexample in `en`, `de`, `cs`, `sv`, `fi`, `pl`, `tr`, `ja`, `zh` and others.
- **Adjacent checking cannot restore a total order that does not exist:** with и/й or е/ё present, the check fails whichever way the pair lies. Every such sort then pays the single-threaded exact re-sort, and every streamed batch pays an exact re-merge.
- **Cost at 1M Cyrillic names (`t5`):** sort 0.56 s → 1.15 s; streamed load 2.3 s → 6.1 s with a worst single `add` of 1.17 s. Hungarian ASCII names: 0.55 s → 2.0 s.
- **Stability:** the result depends on the path taken (key sort, fallback, merge, reverse), so adding one non-ASCII file can reorder unrelated names.
- **Memory safety:** holds. The bucket sort and Swift's sort stay in bounds with an inconsistent comparator.
- **Fix:** make ICU the definition. Compare by secondary-strength sort key, then by bytes. That is a true total order, needs no gate or check, and is already computed.

### 5. MEDIUM · freeze · `Sources/AFMKernel/Panels/PanelModel.swift:215, 489-495, 537-541, 705` · plausible
Background results are invalidated by changes that change nothing, and the fallback is the full work on the main thread.
- `update(with:)` bumps `listVersion` even when it returns false (via `setListed` → `listChanged`). `setComputedSizes` and `applyFilter` bump it too, though `listedItems` is unchanged.
- On a stale version, `setFilter(_:prefiltered:listVersion:)` filters the whole list synchronously. `ViewOptionsPlugin.swift:200` falls back to `model.setSort(order)` on main.
- **Scenario:** a 1M-entry folder with a steady stream of file-system events or arriving Space sizes. Each header click or quick-filter keystroke then runs on the main thread.
- **Measured on main at 1M (16 cores):** `setSort` 0.16 s for ASCII names; a direction flip of non-ASCII names 0.6 s, because `resort` calls `NSString.compare` per adjacent pair (line 125).
- `setSort(_:presorted:)` only checks the count, so stale content of equal length is accepted silently if a caller skips the version check.
- **Fix:** bump the version only when `listedItems` really changed. On a stale version return false without doing the work, so the caller restarts in the background.

### 6. MEDIUM · correctness · `Sources/AFMKernel/Panels/PanelModel.swift:247-278` · confirmed (`t7 model`)
`Snapshot` holds `items` but neither `filter` nor `sort`.
- **Filter:** the shell snapshots, drops the quick filter, then calls `open` (`PanelViewController.swift:601-603`). If the read fails, `restore` leaves `filter == nil` with `items` still the filtered subset. The panel shows part of the folder with no filter indicated, and totals count the subset. A later `setComputedSize` silently swaps in the whole list (line 719).
- **Sort:** if the order changed while the folder was opening, `restore` brings back the old order under the new `sort`. The next direction flip reverses a list that is not in the assumed order: asking for ascending gave `c, b, a`.
- **Fix:** put `filter` and `sort` in the snapshot, or re-derive `items` from `listedItems` on restore.

### 7. MEDIUM · performance on the main thread · `Sources/AFMKernel/Panels/PanelModel.swift:182-199, 638-642, 715, 744` · confirmed
Measured at 1M entries (`t7 model`):

| Operation | Time on main |
|---|---|
| `selectAll` | 0.22 s |
| `invertSelection` | 0.35 s |
| `totals` after select-all | 0.26 s |
| `update(with:)` with nothing changed | 0.07 s per refresh |
| `setComputedSizes`, 200 names, filter active | 0.15 s |

- With a filter active, each name in `setComputedSizes` walks `listedItems` linearly (line 715). That is about 0.75 ms per name, so 10k sizes take about 7 s.
- The name index is rebuilt on main after every list change once three lookups happen.
- **Fix:** index `listedItems` too when filtered, build the key sets off-main or incrementally, and count all-selected totals from the list totals.

### 8. LOW-MEDIUM · threading · `Sources/AFMContracts/Format.swift:6-12, 24` · plausible
One static `NumberFormatter` is used from pool threads and the main thread at once. `ContentColumn.value` runs "on background threads, several at once" (the Size on Disk column at `PropertyDetails.swift:37`), as do `DirectoryList` and `NameList`. `NumberFormatter` is on Apple's not-thread-safe list. I did not run a race detector on it.
- **Fix:** format integers by hand or use a per-thread formatter.
- **Also:** the cached `DateFormatter` never follows a locale or time-zone change.

### 9. LOW · correctness · `Sources/AFMKernel/Support/FileMask.swift:19-27, 49, 75-85` · confirmed (`t7 mask`)
Matching is by bytes, so the mask disagrees with how names compare elsewhere.
- An NFC mask does not match an NFD name: `café*` versus `cafe\u{301}.txt` is false, though `String ==` says the two are equal. Names from HFS+ and many servers are NFD.
- `?` matches one byte: `caf?.txt` does not match `café.txt`, but `caf??.txt` does. `?.txt` does not match `😀.txt`.
- `[` and `\` are `fnmatch` syntax: the mask `report[1].txt` does not match the file `report[1].txt`.
- `STRASSE*` does not match `straße`.
- **Complexity:** fine. `*a*a*a*a*a*b` against 255 `a`s returns in microseconds.
- **Fix:** normalise mask and name to NFC, match over scalars, and pass `FNM_NOESCAPE` or escape `[`.

### 10. LOW · correctness · `PanelModel.swift:150-155` · confirmed
`duplicate()` copies a partial list but not `isComplete` or `isRefreshing`. A tab duplicated mid-load claims to be complete. The shell reloads it on activation; a tab opened with `activate: false` stays that way until then.

### 11. LOW · correctness · `PanelModel.swift:129, 618-627, 723` · confirmed
`hasIdenticalNames` is only known once the lazy index is built. Before that, marking a name that occurs twice in a gathered list adds one file to the cached totals, while `operands()` returns two and a recount says two.

### 12. LOW · correctness · `Sorting.swift:111-117` · by reading
Switching to Unsorted from another key keeps the files in the previous key's order. The arrival order is gone until a reload.

### 13. LOW · threading · `Parallel.swift:137, 245`
- The main thread waits on a `DispatchSemaphore`, which donates no priority, for workers at `.userInitiated`.
- All pool work runs at `.userInitiated` whatever the caller's QoS. Utility work such as `ColumnValueStore` is raised to it.

### 14. LOW · freeze (API gap) · `Sources/AFMKernel/Panels/Listing.swift:80-81` · plausible
`PanelLoader.stream` calls `provider.volume(of:)` before the cancellable listing, and `volume(of:)` has no cancellation variant. On a stalled mount each navigation attempt can park one more global-queue thread that cancel cannot reach.
- **Also:** the comment at lines 65-66 says an error after the first batch "ends the listing with what has arrived", but line 96 rethrows. The shell handles the throw.

### 15. LOW · security hardening · `Sources/AFMKernel/FileSystem/FileItem.swift:91-93`
`URL.appending(name:)` accepts `/`, `..` and NUL. `FileJob.isSafeName` guards the copy engine; I did not verify other callers. A precondition or a sanitising variant in the kernel would make this safe by default.

## Shared mutable state and its protection

| State | Protection | Sufficient? |
|---|---|---|
| `ParallelPool` (`open`, `threads`, `idle`, `workers`, `isWatching`, job counters, `sleeper`) | one `NSCondition` | Yes |
| `Job.body` | read without the lock, but only while `inFlight > 0`; cleared under the lock at 0 | Yes |
| `currentJob` | thread-specific, unretained; the job outlives its pieces | Yes |
| `CancellationFlag` | `NSLock`; handlers run outside it | Yes |
| `NameCollator.cache` | static `NSLock` | Yes |
| Shared `UCollator` | immutable after `init`; only `ucol_getSortKey` is called concurrently | Yes |
| `ListingCache` | one `NSLock`, never held while sorting | Yes |
| `PanelModel`, `PanelTabs`, command/menu/toolbar/preference registries, `PanelEvents`, `KeyBindings` | main-thread confinement, asserted only in `changed()` and `post()`, debug builds only | Yes by convention; no off-main caller found |
| `FileSystemRegistry`, `ColumnRegistry`, `ServiceRegistry` | unsynchronised, written only during plugin start (all `register` calls checked) | Yes |
| `Format` formatters | none | No — finding 8 |
| `MemorySettings` | none (tests only) | n/a |

## Checked and found sound

- **Pool nesting cannot deadlock.** A thread waiting on job J waits only for holders of J's pieces, and whatever those hold above the piece is strictly deeper in the job tree. Stress with 12 threads plus main and random nesting passed (`t6 stress`).
- **No lost wake-ups.** The sleeper is created and checked under the lock, the semaphore counts, and a timed-out idle worker re-checks `open`.
- **Pool overhead** is about 0.3 µs per nested call (`t6 storm`).
- **The blocked-thread heuristic.** Mach port names are removed under the lock before a thread exits, so there are no stale ports. It is conservative for threads that are computing.
- **Main-thread waits.** Main never waits on pool work that waits on main: the kernel's main-thread `Parallel.map` bodies are pure.
- **`askUser`.** I found no main-thread wait on an asking thread within the kernel. The main-thread semaphore waits elsewhere (`VolumeMounting.unmount`, `CommandLine`, `OperationLog`) were not traced.
- **Sorter, where the comparison is a real order.** Fuzzing against a reference sort gave zero differences for sort, incremental merge and reversal, across all keys and directions, with duplicates and 2–9000 items, for ASCII in `en`, Latin accents, NFC/NFD, CJK/kana, ignorables and Turkic.
- **Key building.** Buffer growth, 16-bit limits, the keyless fallback and the date bit mapping are correct. The fast and slow paths of `FileItem.split` agree.
- **ICU access.** The `dlopen` path, unversioned symbol names and attribute constants are correct.
- **`CancellationFlag`.** Handlers run exactly once under concurrent cancel and register. All call sites keep the token alive with `withExtendedLifetime` and capture weakly. `isCancelled` costs about 21 ns.
- **Provider defaults.** No forwarding cycle; `totalSize`, `append` and `commit` dispatch dynamically.
- **`ListingCache`.** Bounds, ticket logic and locking are correct.
- **`PanelModel` caches.** Totals and index invalidation is correct on every mutation path except the cases in findings 6 and 11; saturating sums hold.
- **Shell streaming.** Batches grow geometrically, so total merge cost is not quadratic.

## Not reviewed

- The real `SettingsStore` implementation and its read-modify-write sequences (it lives in the shell).
- Plugin-side `enabled` closures evaluated per menu validation.
- Whether providers other than `FileJob` sanitise names.
- TSan and debug-build runs: all experiments were `-O` builds.
- Run-time locale switching: reasoned about only. The collator is re-read per sort, and a change mid-sort gives one inconsistent list.
