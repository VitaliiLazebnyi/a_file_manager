# Archives plugin threading audit

**Scope read:** all 12 files in `/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/Archives/`, except
`ZipFormat.swift` 1-299 and 390-514 and `ArchiveLocation.swift` 131-286, which I only grepped (no locks, queues, statics
with state, or classes other than the streams there). Nothing was built or run; every finding is from reading. In scope
there is no NSCondition, DispatchSemaphore, NSRecursiveLock, private DispatchQueue, Thread, NotificationCenter, lazy var
or `@unchecked Sendable`.

## A. Lock table

| #   | Lock (decl)                                         | Guards                                                         | Acquired at / called while held                                                                                                                        | Worst hold            |
| --- | --------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------- |
| L1  | `ArchiveEnvironment.lock` OpenArchive.swift:20      | `current` options                                              | :58, :59. Nothing called. Leaf.                                                                                                                        | ns                    |
| L2  | `ArchiveStore.lock` ArchiveFileSystem.swift:15      | `slots`, `opened`, `clock`, `Slot.lastUsed`                    | :43-48, :61-63, :81-83, :95-101, :142, :149-152 (filter+sort of all slots), :161-166, :175, :208-211. Nothing called; archives released outside. Leaf. | µs                    |
| L3  | `Slot.lock` ArchiveFileSystem.swift:24              | `Slot.archive`, `Slot.failure`; serialises opening             | :52 (50 ms timed polls with a flag) or :56 (unbounded), held to return via defer :58; `try()` at :158-168. See below.                                  | unbounded             |
| L4  | `OpenArchive.lock` OpenArchive.swift:144            | tree, file, signature, counters, parked, password, timer flags | `locked{}` :431 and explicit sites. See below.                                                                                                         | ms; ~1 s on huge ZIPs |
| L5  | `OpenArchive.flushLock` OpenArchive.swift:146       | one write/upload at a time                                     | `flush` :1045, `rescue` :1391. See below.                                                                                                              | unbounded             |
| L6  | `StreamInterrupt.lock` ByteStreams.swift:90         | `isRaised`, `handlers`                                         | :95, :101-105, :116-122. Handlers run after unlock. Leaf.                                                                                              | ns                    |
| L7  | `InterruptSlot.lock` ByteStreams.swift:137          | `interrupted`, `current`                                       | :142, :148-152, :156-159, :163. `interrupt()` and `use()` call `control.set()` under it → L6 → handlers → L10 + `process.terminate()`.                 | µs                    |
| L8  | `ScratchFolder.lock` (static) ByteStreams.swift:451 | static `folders`, per-instance `isKept`                        | :457 (atexit), :470, :478, :487. Leaf.                                                                                                                 | ns                    |
| L9  | `TemporaryFile.lock` ByteStreams.swift:497          | `kept`                                                         | :506. deinit :512 reads unlocked (exclusive).                                                                                                          | ns                    |
| L10 | `ProcessStream.lock` Codecs.swift:358               | `errors`, `isClosed`                                           | :377 (GCD stderr block), :386 `stop()` (`isRunning`/`terminate()`), :412, :420.                                                                        | µs                    |
| L11 | `SharedCounter.lock` Unpacker.swift:6               | `total`                                                        | :10, :16. Leaf.                                                                                                                                        | ns                    |

**L3 while held** (ArchiveFileSystem.swift):

- L2 at :61, :81, :95.
- `archive.isCurrent()` :65 → L4, then (L4 released, L3 still held) `fileSystems.item(at: archiveURL)` on the outer
  provider, OpenArchive.swift:491: a network round trip, at most once per second, with no cancellation.
- `open()` :72:
  - Remote/nested archive: `provider.item` :119, `provider.read` :124, then the whole download :130-133.
  - `OpenArchive.init` → `load`: ZIP directory parse, or a full decompress/bsdtar pass. Archives ≤ 256 MB are
    materialised into a temp TAR up to 4 GB (OpenArchive.swift:353-366); larger ones are stream-indexed end to end.
- `evict` :75: `try()` on other slots → `isBusy` → L4.
- deinit of the replaced archive (inside `setArchive`, :103).
- Any user prompt the outer provider raises (see C).

**L4 notable holders** (OpenArchive.swift):

- `isCurrent` :476-490: `stat`.
- `timerFired` :730-750 and :756-761: `idleDelay` → `clones()` → `clonefile` + `unlink` probe (once).
- `makeDirectory` :803, `write` :826, `remove` :864, `move` :919, `duplicate` :962, `setAttributes` :978:
  `requireEditable` → `access()` ×2, or `fileSystems.capabilities(for:)` on the outer provider (:685).
- `write` also: `environment.options` (L1), `scratch.newFile` (L8 + `createDirectory`), `open(O_CREAT)`.
- `finishWrite` :843: `hasRoom` → `statfs`, possibly `volumeAvailableCapacityForImportantUsage` (:69, can be slow).
- `takeSnapshot` :1105: O(n log n) `tree.ordered`, `clones()`.
- `install` :1268: `stat`, `open`, `rename`, O(n) walk.
- `rebase` :1313: `load()`, a full ZIP directory re-parse under the lock. This is the longest L4 hold.
- Never held across `askUser`, a member read, or a flush.

**L5 while held:**

- L4 at :1053, :1054, :1183, :1268, :1313, :1360, :1380, :1071.
- `build` :1169: clone-append writes only pending bytes plus the directory; a rewrite copies the whole archive
  (multi-GB) plus `copyfile` xattrs.
- `upload` :1356: outer `provider.write/move/item/remove` for the entire archive. For a nested archive that reaches
  outer L3, outer L4 and outer L5 (via the outer `move` → `flush`), and outer `ZipMemberWriter.drain` → `Parallel.map`.
- Not held: `reportFailure`, `contentsChanged`, `askPassword`.

**Queues, groups, timers:**

- Flush timer chain, OpenArchive.swift:714: global utility `asyncAfter`, strong `self`, at most one per archive
  (`timerArmed`). `timerFired` :729 runs flush, upload and `reportFailure` on that worker.
- Park timer :571: one `asyncAfter(10 s)` per parked reader, weak self.
- `Tool.filter` group, Codecs.swift:326-336: two global-queue blocks, then `group.wait`, then `waitUntilExit`.
- `ProcessStream.errorsRead`, Codecs.swift:357, :374, :411.
- `Background.run`, Unpacker.swift:26-29.
- `contentsChanged` → `DispatchQueue.main.async`, ArchivesPlugin.swift:50.

**Nesting order (acyclic as read):** L3(inner) → L3(outer); L3 → L4 → {L1, L8, L2 → outer L4}; L5 → L4; L5(inner) →
L3/L4/L5(outer); L7 → L6 → L10. L4 → L5 does not exist: `move` :937 and `timerFired` :752 unlock first. L3(X) → L5(X)
and L5(X) → L3(X) do not exist.

## B. Main thread

- **`ArchivesPlugin.stop()`** ArchivesPlugin.swift:96:
  - `flushAll` (ArchiveFileSystem.swift:182) → L2, L4, then `flush()` → L5: a synchronous, uncancellable whole-archive
    rewrite or upload on main.
  - `rescueAll` → L5/L4.
  - `reportFailure` (:107) asks directly, since it is already on main.
  - `store.close()` runs archive deinits and a recursive scratch delete on main.
  - `flushAll` and `close` deliberately never touch L3.
- **Provider methods allowed on main:** `parent` and `displayPath` take no locks. `capabilities(for:)`
  (ArchiveFileSystem.swift:458) takes L2 then L4 (OpenArchive.swift:696), then the outer `capabilities` with nothing
  held. It never takes L5 or L3, so main cannot block behind a flush or a materialise. It can wait behind
  `rebase`/`takeSnapshot`/`install`/`finishWrite` on L4.
- **ArchiveCommands on main:** `refreshOptions` (L1); `open` :100 (L1); `location(from:)`
  (ArchiveFileSystem.swift:523-543) does `stat` on main for typed paths; `ui.*` in command bodies and completions. No
  `store.archive(at:)` on main; `showMember`, `openAsArchive` and `unpackAndOpen` use jobs.
- **Cancel on main:** `flag.cancel()` → `StreamInterrupt.set` (L6, L10 + `terminate`), `InterruptSlot.interrupt` (L7 →
  L6 → L10), outer `reader/writer.interrupt()`. All short.
- **Deinit on main** is possible for `ArchiveMemberReader`/`OpenArchive` when the last reference drops there (the
  reader's closure holds the archive strongly). It only unlinks and terminates.

### BUG 1 (High, deadlock at quit) — archive on a network provider

- Path T (GCD utility): `timerFired` :752 → `flush` :1045 takes L5 → `upload` :1362 `provider.write(temporary…)` (or
  :1373 `move`, :1379 `item`) → the network connection asks → `Kernel.askUser` → `DispatchQueue.main.sync`.
- Path M (main): `applicationWillTerminate` → `Kernel.shutdown` → `stop()` :97 → `flushAll` ArchiveFileSystem.swift:185
  → `flush` :1045 → `flushLock.lock()`.
- Interleaving: M blocks on L5 first, then T's connection asks. `applicationShouldTerminate` cancels jobs only
  (Shell.swift:103-105); the timer is not a job.
- Confirmation: both in-scope paths read. The network side is confirmed only as far as
  `environment.askCredentials/askToTrust/askSecret` → `kernel.askUser` (NetworkCommands.swift:44-78); I did not trace it
  into the provider's write path.
- Even without a question, M freezes for the whole rewrite or upload: `upload` makes a private `CancellationFlag()`
  (:1361) that nobody can set.
- Fix:
  - Never take L5 on main. Run `stop()`'s flush on a background thread with a cancellable flag while main pumps a modal
    "Saving archives…" sheet, or flush in `applicationShouldTerminate` before replying.
  - Give `OpenArchive` a `shutdown` flag that timer flushes honour.

## C. Ask sites

| Site                                                                                                                                          | Thread                                                                                                                           | In-scope locks held                                                                                                                     |
| --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `askPassword` OpenArchive.swift:647 → ArchivesPlugin.swift:38 via `ArchiveMemberReader` init/read/seek (ArchiveTree.swift:188, 205, 214, 225) | provider-caller thread                                                                                                           | none, **except** when the caller is `ArchiveStore.open` :124 reading an inner archive out of an encrypted outer ZIP: L3(inner) is held. |
| same, via `ArchiveTester.unlock` Unpacker.swift:65                                                                                            | job thread (Unpacker.swift:204, ArchiveCommands.swift:419, Packer.swift:568 → :83); GCD worker (ArchiveCommands.swift:420 → :83) | none                                                                                                                                    |
| same, via `Parallel.map` bodies Unpacker.swift:99, :320                                                                                       | pool threads / `Background.run` worker                                                                                           | none                                                                                                                                    |
| `reportFailure` OpenArchive.swift:762 → ArchivesPlugin.swift:45                                                                               | GCD utility (timer)                                                                                                              | none (L4 released :761, L5 released by flush defer). The worker stays blocked until the dialog is dismissed.                            |
| `reportFailure` ArchivesPlugin.swift:107                                                                                                      | main                                                                                                                             | none                                                                                                                                    |
| `monitor.ask` ArchiveCommands.swift:283 (from Packer.swift:299)                                                                               | job                                                                                                                              | none                                                                                                                                    |
| `monitor.ask` ArchiveCommands.swift:370 (from Unpacker.swift:279)                                                                             | job                                                                                                                              | none                                                                                                                                    |
| Out-of-scope providers asking inside calls made from here                                                                                     | `ArchiveStore.open` :119/:124                                                                                                    | L3                                                                                                                                      |
|                                                                                                                                               | `isCurrent` OpenArchive.swift:491                                                                                                | L3                                                                                                                                      |
|                                                                                                                                               | `upload`                                                                                                                         | L5 (BUG 1)                                                                                                                              |

- L3 + ask is safe only because main never takes L3 under the contract. Any main-thread `item(at:)`, `list`, `read` or
  `quarantine(of:)` on that archive would deadlock. Other threads wanting the same archive wait the whole prompt
  (unbounded at :56 without a flag).
- Low: if the CRC failure handler (:668-671) clears the password mid-run, every pool thread prompts separately, up to 3
  attempts each.

## D. Flush / commit

- **One flush at a time:** L5 is a non-recursive NSLock; no re-entry path exists (`upload` only calls outer providers).
- **Timer state machine is sound.** `timerFired` clears `timerArmed` under L4 before flushing (:731), so a change during
  the flush arms a new timer (:712). Failure re-arms (:760). I walked `uploadPending` and `leavingOutArrivals` and found
  no state with pending changes and neither an armed timer nor an in-flight timer thread.
- **Writer close vs flush:** `finishWrite` and `takeSnapshot` are both under L4. The snapshot's records retain the spool
  `TemporaryFile`, so a concurrent remove cannot unlink it. `install` re-resolves entries by order. Sound. `openWriters`
  is balanced on every path (:834, :844, deinit :1457, close :1506/:1516).
- **Minor:** `armTimer` is a no-op while a retry or `idleDelay` timer (up to 60 s) is armed. The `commit`/`move` notify
  (:955, :1099) and "retry when something else changes" (comment :754) can therefore lag up to 60 s.
- **Stale timers:** the closure holds `self` strongly, so an evicted archive's timer still fires. That is harmless for
  notify-only timers. After `stop()`, a retry timer can run `flush` against a deleted scratch folder; it fails cleanly
  (atomic rename) and then blocks its worker in `main.sync` until exit.
- **Scratch cleanup:** `scratch.removeAll()` (ArchiveFileSystem.swift:214) is serialised with in-table archives through
  L5 in `flushAll`, but not with detached archives (BUG 2) or post-stop timers.
- **Not a threading bug:** `flush()` without `leavingOutArrivals` (timer, stop) writes members still under job temp
  names.

### BUG 2 (Medium-Low, narrow window; silent no-op commit, possible data loss on move)

- The comment at ArchiveFileSystem.swift:155-157 ("nobody can start a change between the look and the removal") is
  false. `archive(at:)` returns the archive after L3 is released (:58, :65).
- Path A: `ArchiveFileSystem.write` :386 `resolve` → archive X returned, then `X.write(path)` (OpenArchive.swift:825).
- Path B: `evict` :158-166 sees `X.isBusy == false` and removes X from `slots`/`opened`. The same happens at :70 when
  `isCurrent()` is false.
- Interleaving: B runs between A's resolve and A's `openWriters += 1`.
- Result: X is detached and gets pending changes. `store.commit(url)` :197 finds nil, or a second `OpenArchive` with
  nothing pending, and returns success. A mover (FileJob.swift:1155) then deletes its sources. `flushAll` at quit misses
  X and the scratch delete removes its spools. Only X's own timer can still save the data.
- Fix: retire atomically. Under X's L4, `retireIfIdle()` sets `retired` only if not busy; mutators throw a "retired"
  error so `ArchiveFileSystem` re-resolves. Alternatively keep a store-level set of busy archives that the archive joins
  in `changed()`/`write()`, and have `commit`/`flushAll` iterate that.
- Confirmed by reading both paths.

## E. Groups / pipes

- **`Background.run`** Unpacker.swift:26-33: `result` is written in the group block and read only after `group.wait`
  returns success, so there is a happens-before. `tick` runs on the caller. Sound.
- **`Tool.filter`** Codecs.swift:312-340: stdin is written and stderr drained on GCD while the caller drains stdout;
  `errors` is read after `group.wait`. No pipe-fill deadlock. `F_SETNOSIGPIPE` is set. It is not cancellable, but the
  input is at most 4 MB.
- **`ProcessStream`:** stderr is drained asynchronously and stdout by the reader; `waitUntilExit` runs only after EOF
  (:410). EOF depends on Foundation closing the parent's write end, which holds because the `Pipe` objects are passed
  directly. Sound.
- **Slot wait:** `slot.lock.lock(before:)` loop :52-54 registers the defer only after acquiring; `try()` at :158 and
  unlock at :168 are balanced.

## F. interrupt()

- **`ArchiveMemberReader.interrupt`** ArchiveTree.swift:199 → `InterruptSlot.interrupt`. Safe at any time, repeatedly,
  after close (`current == nil`), and alongside read/close. Returns after L7 → L6 → L10 + `terminate()`. `closeStream`
  releases the slot before closing, so a parked reader is not hit later, and `park` re-checks `control.isSet` (:562).
- **`ZipMemberWriter.interrupt`** OpenArchive.swift:1460 → `StreamInterrupt.set`. Safe. Checked at write/drain/close;
  the worst latency is one `Parallel.map` deflate window.
- **`.outside` forwarders** return the outer provider's own reader/writer (ArchiveFileSystem.swift:364-366, 385, 392,
  402), so `interrupt()` is native and the flag is forwarded wherever the protocol has one.
- **Internal consumers:** `ArchiveStore.open` :124-128 and `upload` :1362-1365 pass both the flag and
  `flag.interrupting`. The defer order releases the tie before `reader.close()`.
- **Tokens:** OpenArchive.swift:224, :594 and ArchiveTree.swift:185 use weak captures and are kept for exactly the
  blocking span. Sound.

### BUG 3 (Medium, Cancel unresponsive on stalled I/O)

These consumers have neither a flag nor an `interrupting` tie and only poll between blocks:

- `Packer.blocks` Packer.swift:272 (`provider.read(item.url)`)
- `Packer.build` :375
- `Unpacker.write` Unpacker.swift:370
- `unpackAndOpen` ArchiveCommands.swift:147
- `openAsArchive` :177
- `ArchiveFileSystem.read(_:)` :351 (opens a `.member` behind a long decompression with no way to interrupt)
- timer and stop uploads (:1361)

Fix: use the cancellation variants plus `monitor.cancellation.interrupting(...)`.

## G. Shared state

- **Sound:**
  - Every `OpenArchive` var is touched under L4. `load` runs in init or under L4 in `rebase`. `clones()` and `canClone`
    are always under L4. `ArchiveTree.ordered` (a mutating getter) is always under L4.
  - `format` is read unlocked at ArchiveFileSystem.swift:442 but is assigned only in init.
  - `Slot.archive`/`failure` are under L3 and `lastUsed` under L2.
  - `archive(at:)` re-checks `slots[key] === slot` after taking L3 (:61-64), so two threads open one archive once, and a
    cancelled open removes its slot (:81-83).
  - `ArchiveEnvironment` closures are set once in `start()` before registration.
  - Unpacker `result`/`itemsDone`/`lines` are job-thread only. `Parallel.map` bodies touch only `SharedCounter`, the
    monitor, and per-item streams.
  - No lock is held by any caller across `Parallel.map` (OpenArchive.swift:1488, Codecs.swift:584, Packer.swift:67,
    Unpacker.swift:96/:317). Bodies take L4 briefly, and L5 via `provider.move` into a ZIP; the caller holds neither.
- **Minor:** `streamStarts` is `private(set)` and readable unlocked (tests).
- **Deinit:** `OpenArchive.deinit` :230 and `ProcessStream.deinit` run on arbitrary threads and only terminate/unlink.
  `ZipMemberWriter.deinit` :1457 takes L4 briefly.

## H. GCD blocking / fan-out

- A timer flush occupies a utility worker for a whole rewrite or upload, and then indefinitely in `reportFailure`'s
  `main.sync`. That is one worker per failing archive, and the number of busy archives is not capped (capacity 12
  applies to idle ones only).
- Priority inversion: a userInitiated job in `commit`/`move`, or main in `stop()`, waits on L5 held by a utility-QoS
  worker. NSLock gives no priority donation.
- `Background.run` blocks one userInitiated worker per unpack/test job.
- `ProcessStream` blocks one default-QoS worker per live child, including parked readers (up to 4 per archive, 10 s
  each).
- `Tool.filter` uses two workers per bzip2 piece, so about 2 × cores at once. Speculation: this approaches GCD's
  blocked-thread limit on 24+ core machines.
- `park` (:571) schedules one 10 s `asyncAfter` per member read, so a 100k-member per-file copy out of a stream archive
  queues 100k blocks. Low.
- `timerFired` polls every `flushDelay` (0.5 s) while any writer is open (:745).
