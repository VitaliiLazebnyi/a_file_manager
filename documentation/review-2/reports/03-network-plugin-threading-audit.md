# Network plugin threading audit

**Coverage:** I read 12 of the 15 files in full. `FTPListParser.swift`, `FTPReply.swift` and `ServerAddress.swift` were
only grepped for concurrency constructs (they have only `static let` regexes, calendars and tables). Nothing was built
or run; every finding is from reading.

Abbreviations: FS=FTPSession, FC=FTPConnection, NS=NetStream, SC=SFTPChannel, SS=SFTPSession, RFS=RemoteFileSystem,
RS=RemoteSession, NC=NetworkCommands, NP=NetworkPlugin, VM=VolumeMounting (all `.swift` in
`/Users/cm0k/Claude/Projects/TotalCommander/Sources/Plugins/Network/`).

## A. Lock table

| Primitive (decl)                                  | Guards                                                                                                 | Acquired at / called while held                                                                                                                                                                                                                                                                                        | Worst hold                                                               |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `Pending.condition` NS:53                         | one value                                                                                              | NS:57, 65, 72; nothing nested                                                                                                                                                                                                                                                                                          | µs; wait releases                                                        |
| `CertificateTrust.lock` NS:97                     | accepted set                                                                                           | NS:105, 110                                                                                                                                                                                                                                                                                                            | leaf                                                                     |
| `TLSSettings.lock` NS:121                         | rejectedCertificate                                                                                    | NS:130-131                                                                                                                                                                                                                                                                                                             | leaf                                                                     |
| `ExplicitTLSReport.lock` NS:182                   | two replies                                                                                            | NS:187-193                                                                                                                                                                                                                                                                                                             | leaf                                                                     |
| `NetStream.condition` NS:283                      | isReady, failure, buffer, readOffset, atEnd, receiveFailure, isReceiving, isClosed, hasFinishedWriting | NS:347 (state handler), 392, 399 (receive), 428 (`wait`, runs NS's own `ready` closures: a Data copy of at most ~1.25 MB), 511, 516, 546. No foreign callback, no other lock. `connection.cancel()` is outside (NS:362, 551)                                                                                           | one memcpy                                                               |
| `NetStream.queue` NS:282 (serial, one per stream) | NW callbacks, TLS verify block NS:141                                                                  | `SecTrustEvaluateWithError` runs here and may block on revocation checks; it stalls only this stream                                                                                                                                                                                                                   | seconds                                                                  |
| `DataListener.queue` NS:559                       | listener callbacks                                                                                     | only `Pending.fulfill`                                                                                                                                                                                                                                                                                                 | µs                                                                       |
| `LinkMemory.lock` FC:107                          | kinds                                                                                                  | FC:112, 117, 124                                                                                                                                                                                                                                                                                                       | leaf                                                                     |
| `FTPConnection.streamsLock` FC:162                | `control`/`data` refs against `interrupt`                                                              | FC:272, 281; `close()` of the streams is after unlock (FC:284)                                                                                                                                                                                                                                                         | leaf                                                                     |
| `FTPSession.condition` FS:24                      | pool: idle, inUse, total, readers, writers, flags, profile, home, login state, keepAlive               | FS:81, 86, 92, 109, 116, 149, 174, 193, 205 (wait at 231), 254, 273, 283, 298, 345, 358, 368, 384, 389, 509, 547, 555, 563. Nested: → `NetworkOptions.lock` (FS:213 → RS:49). Also reads `connection.isUsable`/`lastUsed` (no lock). No I/O, no callbacks                                                              | µs                                                                       |
| `FTPSession.loginLock` FS:55                      | one first login at a time                                                                              | FS:113, untimed `lock()`, only when `hasConnected` was false; released by defer FS:114. While held: → `condition` (116, 149, 174); `askCredentials` (133, 137, 169); `askToTrust` (163); full connect and login I/O (148); `startKeepAlive` (160)                                                                      | unbounded (user dialog, plus up to 4 attempts of ~12 commands × timeout) |
| `FTPSession.observerLock` FS:50                   | linkObserver                                                                                           | FS:416, 430; the closure is invoked after unlock                                                                                                                                                                                                                                                                       | leaf                                                                     |
| `keepAliveQueue` + timer FS:56-57                 | NOOP pings                                                                                             | handler FS:351 (`[weak self]`) → FS:356. Takes `condition` briefly; `isAlive()` (NOOP, up to 5 s, no cancellation) runs outside any lock, serially per stale connection. Timer cancelled at FS:78 and 394; never stops otherwise                                                                                       | n/a                                                                      |
| `FTPReader.stateLock` FS:585                      | active, isReading, wasClosed                                                                           | FS:610, 618, 625, 683, 696, 702. Nested at 696-698: → `streamsLock` → (released) → `NetStream.condition`, all non-blocking                                                                                                                                                                                             | µs                                                                       |
| `FTPWriter.holdLock` FS:734                       | isHolding                                                                                              | FS:796, 804 (→ `streamsLock`, `NetStream.condition`)                                                                                                                                                                                                                                                                   | µs                                                                       |
| `SFTPChannel.lock` SC:260                         | waiting, nextID, closed, errorText                                                                     | SC:285, 291, 301, 380, 388, 464, 480, 493; fulfils happen after unlock                                                                                                                                                                                                                                                 | leaf                                                                     |
| `SFTPChannel.writeLock` SC:262                    | pipe writes and closing the write end                                                                  | SC:406 (`lock(before:)` in 0.1 s turns, deadline `writeTimeout`), SC:535 (0.5 s timed). While held: non-blocking `write` + `poll(200 ms)` (SC:427-443); → `lock` via `isClosed` (SC:420, 435)                                                                                                                          | `writeTimeout` = max(10, timeout), up to 600 s without progress          |
| SFTP reader `Thread` SC:322                       | blocking `read()` on a dup'ed fd                                                                       | calls `received` → `lock` → `Pending.fulfill`                                                                                                                                                                                                                                                                          | lives until ssh's stdout hits EOF                                        |
| `errors.readabilityHandler` SC:298                | stderr tail                                                                                            | → `lock`                                                                                                                                                                                                                                                                                                               | µs                                                                       |
| `SFTPSession.lock` SS:14                          | channel, profile, flags, home, declined                                                                | SS:37, 42, 88, 127, 141, 158, 163                                                                                                                                                                                                                                                                                      | leaf                                                                     |
| `SFTPSession.connectLock` SS:16                   | one login at a time                                                                                    | SS:84 (`lock(before: 0.1)` loop; cancellable only if a flag was passed), defer unlock SS:87. Taken by every SFTP operation, even when connected. While held during a (re)login: → `lock`; `AskpassHelper` file I/O; `Process.run`; `created.start` (→ `writeLock` → `SC.lock`); `askSecret` (SS:119); realpath request | unbounded (dialog, plus timeout + 30 s)                                  |
| `NetworkOptions.lock` RS:43                       | Values                                                                                                 | RS:49-50                                                                                                                                                                                                                                                                                                               | leaf                                                                     |
| `ConnectionCenter.lock` RFS:14                    | sessions, announced, saved, lastPaths                                                                  | RFS:31, 50, 58, 70, 79, 88, 94, 121, 130, 139, 146. Nested: `dropUnconnected` (RFS:42, under 31 and 50) calls `session.isConnected` → `FTPSession.condition` or `SFTPSession.lock`. Keychain lookup and `disconnect()` are outside                                                                                     | µs                                                                       |
| `EntryCache.lock` RFS:176                         | directories, journal                                                                                   | RFS:188-291; runs the local `change` closure at RFS:250                                                                                                                                                                                                                                                                | leaf                                                                     |
| `MemoryPasswords.lock` SavedConnections:47        | dictionary                                                                                             | leaf                                                                                                                                                                                                                                                                                                                   |                                                                          |
| `Background.queue` RS:203 (concurrent, utility)   | clean-up                                                                                               | FS:423, 603, 750; SS:193, 371, 527                                                                                                                                                                                                                                                                                     | see H                                                                    |
| `DispatchSemaphore` VM:42                         | unmount completion                                                                                     | wait VM:48, no timeout                                                                                                                                                                                                                                                                                                 | unbounded                                                                |

- **Global order (acyclic):** `ConnectionCenter.lock` → {`FS.condition` → `NetworkOptions.lock` | `SS.lock`};
  `loginLock` → `FS.condition`; `connectLock` → `SS.lock`; `connectLock` → `writeLock` → `SC.lock`; {`stateLock` |
  `holdLock`} → `streamsLock`, then `NetStream.condition`.
- **Absent from the module:** `CancellationFlag.onCancel`, `DispatchGroup`, `NotificationCenter`,
  `DispatchQueue.main.sync` (the only main dispatch is `asyncAfter` at NC:448). All cancellation is polled every 0.1-0.2
  s.

## B. Main-thread paths

- **Pure text:** `parent(of:)` RFS:421, `displayPath` RFS:583, `capabilities`.
- **`capabilities(for:)` RFS:500:** takes `center.lock`, then `FS.condition` (FS:509) and `NetworkOptions.lock`. Never
  blocks.
- **`places()` RFS:602, `volume(of:)` RFS:608, the menu `enabled` closure NP:136, `NC.disconnect` NC:250:** go through
  `center.connected` to `center.lock`, then the session locks (µs). Sound.
- **`location(from:)` RFS:591:** calls `center.announce`, which disconnects never-logged-in sessions on the caller.
  Non-blocking in practice: FTP has no idle connections before the first login, and SFTP has no channel yet.
- **`store.onChange` → `center.setSaved` (NP:103):** same as above.
- **`NC.connect` failure completion NC:111:** runs `center.disconnect(key)` synchronously. For FTP this is `FC.close()`
  per idle connection, a QUIT write waited up to 2 s (FC:264). For SFTP it is `SC.close()`, up to 0.5 s (SC:535). I
  assumed job completions run on main and did not check.
- **`NP.stop()` NP:167, from Kernel.swift:84:** same `disconnectAll`, serial. Bounded at 2 s × idle FTP connections +
  0.5 s × SFTP sessions; normally under a millisecond because the QUIT fits the socket buffer. It does not wait for
  worker threads.
- **`NC.disconnect` NC:285-286:** correctly detaches on main and closes on a global queue.

**Deadlock verdict:** inside the module, main never takes `loginLock` or `connectLock`, the only locks held across
`askUser`. A deadlock needs outside code to call a connecting provider method on main:

- Main: `provider.item/list/read/write` → `FS.acquire` → `openConnection` → `loginLock.lock()` (FS:113), or `SS.open` →
  `connectLock` (SS:84).
- Background: holds that lock inside `askCredentials`/`askSecret` → `Kernel.askUser` → `DispatchQueue.main.sync`.

The only outside callers I checked, `FileOperationsPlugin.swift:507` and `:552`, are inside `jobs.run` work. The rest is
for your whole-program pass.

## C. askUser call sites

| Site                                                                          | Thread                                                                                                                                        | Held at that moment                                                                                             |
| ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| FS:133, 137 (`askCredentials` before connecting)                              | whoever needed a new connection: job thread, panel loader, Parallel pool thread, or `Background.queue` via `resolveLinksLater` (FS:423 → 426) | `loginLock` if first login; a reserved pool slot (`total`, and readers/writers if a transfer). Not `condition`. |
| FS:163 (`askToTrust`), FS:169 (`askCredentials` after `loginFailed`)          | same                                                                                                                                          | same; the failed `FTPConnection` is already closed                                                              |
| SS:119 (`askSecret`, inside the `service` closure of `created.start`, SS:110) | whoever called `SS.open`                                                                                                                      | `connectLock`. Not `SS.lock`, not `writeLock`.                                                                  |

- RFS holds no lock across session calls.
- The NC closures (NC:43-85) run on main inside `askUser`; they touch `store` and the Keychain there.
- Callers with `isFirst == false` take no `loginLock`, so several threads can queue dialogs one after another.

## D. Wait hygiene

- **`Pending.wait` NS:74-80:** predicate loop, 0.1 s timed, broadcast. Sound.
- **`NetStream.wait` NS:430-437:** predicate loop, timed. Every state change broadcasts under the same lock (NS:360,
  404, 549). No missed wakeup.
- **`FS.acquire` FS:208-232:** predicate loop, 0.2 s timed. Broadcasts at FS:257, 292, 302, 371, 396. Sound.
- **`FS.pause` FS:189:** 0.1 s sleep slices, checks flag and `isClosed`; holds a pool slot for up to 10.5 s.
- **`loginLock.lock()` FS:113:** untimed and uncancellable. A second "first" thread ignores Cancel until the dialog or
  login of the first ends (low severity).
- **`connectLock` SS:84:** polled, but uncancellable when the flag is nil (`makeDirectory`, `remove`, `rename`,
  `setAttributes`).
- **`writeLock` SC:406, 535:** timed. All NSLocks are locked and unlocked on the same thread.
- **Semaphore VM:42-48:** one signal, one wait, value returns to 0, so no deallocation crash. No timeout: if the
  completion never fires the job thread hangs. `failure` is ordered by the semaphore.

## E. interrupt()

No `onCancel` registrations exist, so there are no token-lifetime issues.

- **`FTPReader.interrupt` FS:693:** sets the flag, then cuts the connection under `stateLock`. `active` is cleared under
  that lock before every release (FS:644, 683). It cannot hit a recycled connection and is non-blocking. Sound.
- **`FTPWriter.interrupt` FS:802:** guarded by `holdLock`/`isHolding`, cleared before release (FS:796-799). Sound, also
  after close.
- **SFTP reader/writer SS:497, 596:** flag only; always safe. They never close the shared channel.
- **`CachingWriter.interrupt` RFS:647:** forwards.

**BUG 1 (medium-low; confirmed by reading both paths): `FTPReader.close()` interrupts outside the lock.**

- Path 1: FS:702-706 captures `running` and `reading == true` under `stateLock`, unlocks, then calls
  `running?.connection.interrupt()` at FS:710.
- Path 2: the reading thread hits end of file: `setActive(nil)` FS:644 → `finishTransfer` → `release` FS:646 puts the
  connection in `idle`. A third thread pops it at FS:216.
- Interleaving: close() unlocks; the reader finishes and releases; thread X acquires the connection; close() then cuts
  X's control stream. X sees a spurious `connectionLost`, which is not retried for mkdir/delete/rename
  (`commandMayHaveRun`) or for uploads.
- Fix: call `interrupt()` while holding `stateLock`, re-reading `active`, exactly as `interrupt()` does at FS:696-698.

**BUG 2 (low): `FTPReader.close()` from another thread races with `seek()`.**

- `seek` FS:663-679 never calls `begin()`, so `close()` sees `isReading == false`. It then runs `stop()` and writes
  `atEnd` (FS:713-714) while the owner reads and writes `atEnd`/`position`/`active` unlocked.
- This is outside the kernel contract (which only requires `interrupt` to be concurrent-safe) but inside the class's own
  documented promise (FS:573).
- Fix: bracket `seek` with `begin()`/`end()`.

**Latency after interrupt (not a bug):** `abortTransfer` (FC:543-549, up to 10 s plus 2 s per extra reply, no flag) and
the QUIT (2 s) run on the worker after `interrupt()` has returned.

## F. Pool and SFTP window

**FTP pool: sound.**

- A connection is in exactly one of `idle`, `inUse`, or the hands of one thread; all moves are under `condition`.
- Slot accounting balances on every path (FS:235, 242, 254-256, 285, 300, 321).
- Keep-alive removes stale connections from `idle` before pinging (FS:359-360), so it never touches an in-use one.
- `disconnect` racing a keep-alive ping or an opening connection is handled (FS:369-373, 275-278).

**BUG 3 (low-medium, responsiveness): keep-alive empties the idle pool.**

- FS:359-367 pulls all stale connections at once and pings them serially, up to 5 s each on a silently dead link.
- They still count in `total`, so a foreground command at FS:221 waits up to N × 5 s.
- Fix: ping one at a time, or do not count pinged connections against the limit.

**BUG 4 (low, logic): no 421 retry for the second "first" thread.**

- Two threads both read `isFirst == true` (FS:110). The second opens after the first succeeded, but the 421 retry at
  FS:164 requires `!isFirst`.
- On a one-connection server it fails instead of retrying.
- Fix: re-read `hasConnected` after taking `loginLock`.

**Hazards, not proven:**

- `list`'s external `receive` callback (FS:406, RFS:371) runs while a command connection is held. With
  `parallelConnections` = 1, a callback that issues another command on the same server waits forever when the flag is
  nil.
- Mixed read-first and write-first workers could cross-wait on reader and writer slots; this depends on FileJob
  ordering.

**SFTP channel: sound.**

- Ids are allocated and registered under `lock` with the closed check (SC:464-471).
- `markClosed` snapshots and fulfils every waiter with `.closed` (SC:387-395), so no waiter is lost when the channel
  dies or is closed from another thread.
- Late answers to abandoned tickets are dropped (SC:381).
- Order is `writeLock` → `lock` only.
- The reader thread captures `self` weakly, owns its fd, and exits on EOF after `terminate`.

**By design, but far-reaching:**

- Any write time-out, including in `lockForWriting`, or a cancel in mid-packet after the 2 s grace, closes the whole
  channel for every transfer (SC:440, 448-450).
- An unparsable packet (SC:379) ends the reader without terminating ssh.

**BUG 5 (low): `SS.disconnect()` during a login does not stop it.**

- SS:162-169 sees `channel == nil`. `open()` then stores the channel and sets `hasConnected` (SS:127-129) on a closed
  session.
- The ssh process lives until the session is deallocated.
- Fix: check `isClosed` at SS:127 and close `created`.

## G. Unsynchronised state and lifetime

- **Set once on main, read from workers without a lock:**
  `SessionEnvironment.askCredentials/askToTrust/askSecret/log/declineMemory` (RS:120-131; set at NC:43-77, after the
  providers are registered at NP:105), and `ConnectionCenter.makeSession/storedPassword` (RFS:20-22). Benign.
- **`FC.lastUsed`, `isUsable`:** read under `FS.condition` by a non-owner. Ownership hand-off goes through that lock, so
  this is sound.
- **`SC.extensions`, `writeTimeout`:** written before the channel is published. Sound.
- **`@unchecked Sendable`:** none. No lazy vars. Static lets are immutable.
- **Deinits:** NS:338 and FS:78 are non-blocking. Reader/writer deinits hand work to `Background.queue`. `SC.deinit`
  calls `close()`, whose `writeLock` is always free then.
- **Keychain I/O:** `center.session(for:)` (RFS:77) runs on the calling worker; NC:51 runs on main inside the dialog.

## H. GCD blocking and fan-out

- **`Background.queue` is concurrent and each item blocks a worker:**
  - FTP abort: 10 s or more (FS:604, 751).
  - SFTP `closeHandle`: up to the timeout, 30-600 s, with no flag (SS:193, 371, 527).
  - `resolveLinksLater`: up to 20 s, plus an unbounded wait in `acquire` with a nil flag (FS:426).
- **BUG 6 (medium, responsiveness): `resolveLinksLater` has no bound per session.**
  - There is one task per listing with unresolved links.
  - Each holds a command connection for up to 20 s and counts against `parallelConnections`, so three link-heavy
    listings can stall the next foreground listing.
  - It can also open a login dialog from a background task (FS:169).
  - Fix: one serial resolver per session with coalescing, yielding the connection between probes.
- **`NC.disconnect`:** uses a global utility queue for `disconnect()` (bounded, see B).
- **Other blocking calls:** `mount` (`NetFSMountURLSync`) and `unmount` block job threads and cannot be cancelled.
