# Verify threading and hang findings

Twelve of the fourteen claims hold as stated; claim 3's stated consequence is refuted for file jobs and claim 7 holds only narrowly. I ran standalone experiments for 10, 11 and 12 (the project's real `Parallel.swift`, built in scratch); everything else is from reading the code and its callers, and nothing was run inside the app.

Paths below are relative to `/Users/cm0k/Claude/Projects/TotalCommander/Sources`.

| # | Verdict | Basis |
|---|---|---|
| 1 | CONFIRMED, narrow window | read |
| 2 | CONFIRMED | read |
| 3 | Race CONFIRMED; stated consequence REFUTED for file jobs, weaker variant in DirectorySync | read |
| 4 | CONFIRMED, narrow window | read |
| 5 | CONFIRMED as a race, very narrow window | read |
| 6 | CONFIRMED | read |
| 7 | CONFIRMED narrowly; user-visible effect unproven | read |
| 8 | CONFIRMED | read |
| 9 | CONFIRMED | read |
| 10 | CONFIRMED mechanism; pool limit measured; needs about 80 stuck threads | read + ran |
| 11 | CONFIRMED | ran |
| 12 | CONFIRMED mechanism; "tens of GB" figure unproven | ran |
| 13 | CONFIRMED | read |
| 14 | CONFIRMED | read |

## Claims

**1. Deadlock at quit — CONFIRMED, narrow window.**
- **Evidence:**
  - `Plugins/Archives/OpenArchive.swift:1045` — `flush()` holds `flushLock` for its whole duration, including `upload()` at 1068.
  - `OpenArchive.swift:1362` — `upload()` calls `provider.write` on the server's file system.
  - `Plugins/Network/FTPSession.swift:133,137,169` and `SFTPSession.swift:121` — a (re)connect can ask a question through `askCredentials` / `askToTrust` / `askSecret`.
  - `AFMKernel/PluginAPI/Kernel.swift:102` — those go through `DispatchQueue.main.sync`.
  - `AFMShell/App/Shell.swift:112` → `ArchivesPlugin.swift:97` → `ArchiveFileSystem.swift:185` — the main thread calls `archive.flush()` and waits on `flushLock`.
- **Sequence:**
  1. A ZIP on an FTP/SFTP server has changes pending (`uploadPending` keeps `hasPendingChanges` true, `OpenArchive.swift:470`).
  2. The flush timer thread is inside `upload()` and needs a new connection.
  3. The user quits; main blocks on `flushLock`.
  4. The connection asks a question; the timer thread blocks in `main.sync`.
- **Why narrow:** the question must be posted after main has entered `applicationWillTerminate`; if it is posted earlier, a modal dialog is already up. `NetworkPlugin.stop` runs before `ArchivesPlugin.stop` and empties the sessions, so a write after that builds a fresh session, which asks if the password is not in the Keychain.
- **User sees:** beachball at quit, force quit needed, and the edit never reaches the server.

**2. `Coalescer.settle` calls `onChange` off main — CONFIRMED.**
- **Evidence:**
  - `Plugins/VirtualFolders/VirtualFileSystem.swift:510,517` schedule `settle()` on `DispatchQueue.global`; 516 calls `fire()` there with no hop to main.
  - `AFMShell/Window/PanelCoordinator.swift:178` — the callback is `reloadChangedPanels`, which mutates `missedChanges` and calls `panel.reload` (`MainThread.assert` at `PanelViewController.swift:810`).
  - `AFMKernel/FileSystem/FileSystemProvider.swift:308` — the contract says main thread.
- **Sequence:** a panel shows a branch view or search-result list; a second change report arrives within 0.5 s of the first. FSEvents latency is also 0.5 s, so under sustained changes the second report often lands just before `settle` runs.
- **User sees:** assertion crash in debug builds; in release, panel state and AppKit touched off main (undefined behaviour, possible crash).

**3. Archive eviction race — race CONFIRMED, stated consequence REFUTED for file jobs.**
- **The race:**
  - `Plugins/Archives/ArchiveFileSystem.swift:58` — `store.archive(at:)` releases the slot lock on return.
  - `ArchiveFileSystem.swift:386/395` then `OpenArchive.swift:826-834` — the caller takes the archive's own lock and sets `openWriters += 1`.
  - `ArchiveFileSystem.swift:158-166` — in between, `evict` can see `isBusy == false` and drop the slot. The comment at 155-157 ("nobody can start a change between the look and the removal") is wrong.
  - The window is a few instructions, and needs at least 12 other archives open plus another thread opening one right then.
- **Why the stated consequence fails:** `FileJob.put` writes under a temporary name and then renames (`Plugins/FileOperations/FileJob.swift:720-724`; same at 837-862). The rename resolves the archive again, gets a fresh `OpenArchive` read from disk, and fails with "not found" (`OpenArchive.swift:876`). The source is kept. A commit that succeeds without the data, followed by deletion, does not follow.
- **What does happen:** a spurious error on one file (Retry works), and the orphan's own timer later writes a stray `.afm-<uuid>.tmp` member into the ZIP.
- **Weaker variant that holds:** DirectorySync writes a new file directly under its final name (`Plugins/DirectorySync/SyncPlan.swift:272`, write at 358).
  - `commit` then succeeds as a no-op, because `openArchive(at:)` returns nil or the fresh archive (`ArchiveFileSystem.swift:197`).
  - The data exists only in the orphan until its timer fires.
  - If the app quits first, `flushAll` (line 184) skips orphans and `store.close()` deletes the spool. Sync does not delete the source.
- **Further double race:** the orphan and the fresh archive check the file signature under different locks (`OpenArchive.swift:1272-1274`), so one flush could overwrite the other.

**4. `FileSearch.Walk` data race on cancel — CONFIRMED, narrow window.**
- **Evidence:**
  - `Plugins/FindFiles/FileSearch.swift:367` — on cancel, `deliver` leaves its wait with `pending > 0`.
  - `FileSearch.swift:369` — it writes `node.candidates = []` under the lock.
  - `FileSearch.swift:433` (two reads of `.count`) and 440 (array copy) — a worker that has just left the lock at 423 reads `node.candidates` unlocked.
- **Conditions:**
  - Only with a text pattern or field rules (`needed` true).
  - Without cancellation the wait at 367 prevents it.
  - After cancel, `deliver` sweeps the sibling nodes at 375, which widens the set of nodes hit.
- **User sees:** possible crash when cancelling a content search.
  - Use-after-free on the array buffer.
  - Trap at 433 if the count goes from N to 0 between the two reads, giving a range with lower bound above upper bound.

**5. `FTPReader.close()` cuts a returned connection — CONFIRMED as a race, very narrow.**
- **Evidence:** `Plugins/Network/FTPSession.swift:702-710` snapshots `active` under `stateLock` and calls `running?.connection.interrupt()` after unlocking. `interrupt()` at 693-698 does the same under the lock, with a comment explaining why.
- **Sequence:** the reading thread hits end of file between 706 and 710, releases the connection to the pool (644-647, `release` at 282-292), another thread takes it, then `close()` closes its sockets.
- **Why narrow:** the closing thread must be preempted for a server round trip between two adjacent statements.
- **User sees:** "connection lost" on an unrelated transfer or on a rename/delete; repeatable commands reconnect silently (`perform`, 320).

**6. `LocalFileSystem.places()` blocks 1 s per call — CONFIRMED.**
- **Evidence:** `Plugins/LocalFileSystem/LocalFileSystem.swift:673-675` computes a new 1 s deadline on every call and waits while `knownPlaces == nil`. That stays nil until the first `readPlaces()` returns (700-711), which calls `mountedVolumeURLs` with resource values (733).
- **Main-thread callers:** `AFMShell/Window/ButtonBarView.swift:192`, `AFMShell/Panel/PanelViewController.swift:916`, `Plugins/Navigation/NavigationPlugin.swift:161`.
- **User sees:** with a dead network mount at launch, 1 s freezes at start-up, on every volume-menu open and on every mount notification.
- I did not make `mountedVolumeURLs` hang.

**7. `OpenArchive.capabilities` on main — CONFIRMED narrowly; user-visible effect unproven.**
- **Evidence:** `Plugins/Archives/OpenArchive.swift:696` takes `lock`; it is reached on main from command validation (`Plugins/FileOperations/FileOperationsPlugin.swift:43`, `Plugins/Clipboard/ClipboardPlugin.swift:52`, `Plugins/MultiRename/MultiRenamePlugin.swift:27`, `Plugins/FileProperties/FilePropertiesPlugin.swift:46`).
- **Correction:** the lock is not held across member data or the archive rewrite (`build`, 1062, runs outside it). It is held across metadata system calls on the archive's volume:
  - `access()` at 686
  - `statfs` and free-space lookup at 850
  - `clonefile` probe at 772
  - `stat`, open and rename in `install`, 1268-1274
  - `stat` at 482
  - a full re-read of the ZIP directory in `rebase`, 1313-1327
- **User sees:** nothing on a local SSD (microseconds to milliseconds); a stall on a slow or stalled network share.

**8. `realpath` on main — CONFIRMED.**
- **Evidence:** `AFMShell/Window/PanelCoordinator.swift:171-180` → `Plugins/LocalFileSystem/LocalFileSystem.swift:840-843` → `DirectoryWatcher.swift:75,112-114`.
- **Worse than stated:** every location change passes both panels' directories. If one panel sits on a dead mount, each navigation in the healthy panel runs `realpath` on the dead path on main.
- **User sees:** UI freeze on each navigation until the mount times out.

**9. `ViewerPane.stopWork` closes remote readers on main — CONFIRMED.**
- **Evidence:** `Plugins/Viewer/UI/ViewerPane.swift:324` → `Plugins/Viewer/Model/ByteSource.swift:182-188` closes each idle reader.
  - SFTP: `Plugins/Network/SFTPSession.swift:486-490` → `closeHandle` (186-188) is a synchronous request with the 30 s default timeout.
  - FTP: `FTPSession.swift:713` → `stop()` → `abortTransfer()` (`FTPConnection.swift:538-552`) waits up to 10 s for a reply.
- **Scale:** up to one idle reader per core, closed one after another.
- **User sees:** freeze when closing the viewer or switching quick-view file while the server is slow.

**10. Blocked threads from `PanelLoader.stream` — CONFIRMED mechanism; needs about 80 stuck threads.**
- **Where the threads come from:** `DispatchQueue.global(qos: .userInitiated)` workers, at `AFMShell/Panel/PanelLoading.swift:108` and `PanelViewController.swift:794,825`.
- **Why they stick:** `AFMKernel/Panels/Listing.swift:80-81` calls `provider.parent`, `root` and `volume(of:)`; `LocalFileSystem.volume(of:)` (752-760) is plain system calls with no cancellation.
- **Measured (16 cores, macOS 27.0.1):** with 200 blocks sitting in a blocking `read()`, only 80 ever started. After that:
  - probes on `global` at every QoS did not run within 3 s
  - `asyncAfter` on a global queue did not run
  - a private serial queue still ran
- **Why a local folder starves:** its load goes to the same global queue, which starts no more blocks. So does everything else on global queues, including file jobs (`AFMShell/Interaction/ProgressJobService.swift:78`) and archive flush timers.
- **Caveats:**
  - Quiet reloads do not stack (`PanelViewController.swift:816-820`); only explicit refreshes and navigations add a thread.
  - I did not test with a real dead mount.

**11. Workers always take the oldest job — CONFIRMED (ran).**
- **Evidence:** `AFMKernel/Support/Parallel.swift:226` (`open.first`); threads added by `watchLater` (161-166) take the same job.
- **Measured:** 64 CPU pieces of 50 ms took 0.24 s on 16 threads alone, and 3.73 s on 1 thread beside an older job whose pieces sleep. The sleeping job grew to 61 threads.
- **Consequence:** the later job is not blocked, since its caller always works on it (line 125); it loses all parallelism until the older job has handed out every piece.

**12. No autorelease pool on pool threads — CONFIRMED mechanism (ran); "tens of GB" unproven.**
- **Evidence:** `Parallel.swift:195-208` runs bodies with no pool; there is no `autoreleasepool` anywhere in `Sources`.
- **Measured** (same read as `LocalFileSystem.swift:343`, 2048 MiB in waves through the real pool):

| Variant | malloc in use at end |
|---|---|
| As in the project | 1908 MiB |
| `autoreleasepool` around each piece | 0 MiB |

- In-use dropped to 0 once the threads exited after 2 s idle, but the process footprint stayed at 1920 MiB.
- **Size:** one pass over a 4 GiB file holds about 4 GiB. Tens of GB would need repeated passes without a 2 s pause; I did not measure that in the app.

**13. A stuck job blocks commands and Quit — CONFIRMED.**
- **Evidence:**
  - `AFMShell/App/Shell.swift:103-107` returns `.terminateLater`.
  - `ProgressJobService.swift:99-106` — the reply is sent only when the queue empties.
  - `ProgressJobService.swift:79` — that happens only after `work` returns.
  - `AFMKernel/PluginAPI/Kernel.swift:79` — `isBusy` rejects every command not marked `runsDuringJobs`.
- **User sees:** beeps on most commands, queued jobs never start, Quit does nothing; force quit.
- A job counts as stuck if its work never returns after cancel, or never starts because the global pool is exhausted (claims 10 and 14).

**14. One GCD thread parked per launched program — CONFIRMED.**
- **Evidence:** `Plugins/Configuration/CommandRunner.swift:261-267` — both branches sit in `ended.wait()` until the login shell exits.
- **Scope:** lines turned into `open -a` return at once; a program run directly holds a thread for its lifetime.
- **Consequence:** these threads count toward the 80-thread limit measured under claim 10.

## New defects noticed

- **Every local read loop has the claim-12 problem.** In isolation, a GCD block reading 200 MiB through `FileHandle.read(upToCount:)` held 200 MiB until the block ended. The same reader is used, with no pool, in:
  - `Plugins/FileOperations/FileJob.swift:813` (stream copy local to server or archive; the whole job is one block)
  - `Plugins/FileOperations/Checksum.swift:21`
  - `Plugins/FindFiles/DuplicateFinder.swift:121`
  - `Plugins/FindFiles/TextPattern.swift:314-347` (on search threads that live for the whole search, `FileSearch.swift:461`)
  - `Plugins/DirectorySync/SyncComparison.swift:342`
  - `Plugins/FileTools/ToolRun.swift:135`

  Memory would grow by roughly the bytes read. Not measured in the app.
- **Pool exhaustion chains into claim 13.** Once 80 global-queue threads are blocked, a new job's work never starts, `isBusy` stays true and Quit hangs.
- **The `Parallel` pool grows through a global queue** (`Parallel.swift:152`), so it stops adding threads in the same state.
- **Orphaned archives are skipped at quit** (`ArchiveFileSystem.swift:184` iterates only the table), then `store.close()` deletes their spool files (line 214).

The experiment sources are in `/private/tmp/claude-501/-Users-cm0k-Claude-Projects-TotalCommander/91e36f29-0d53-4421-8985-1ec839e7f5c4/scratchpad/verify2/threads/` (`par/`, `gcd/`, `thr/`); binaries and the 2 GiB test file are removed.
