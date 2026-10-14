# Review Network second round

# Second-round review: Sources/Plugins/Network

All 15 files were read in full; nothing in the project was modified. Two findings were confirmed by standalone experiments in the scratchpad (`review2/network/re.swift`, `url.swift`); the rest come from reading the code. I found no critical issue and no way for the main thread to block on a server for more than about 2 s.

## Findings, most severe first

### High

**1. Replacing move deletes the destination when the rename is refused for any reason** — data-loss, confirmed (code path)
- Where: `RemoteFileSystem.swift:533-543`, `SFTPSession.swift:270-275`.
- What: `move(replacing: true)` treats every `NetworkError.refused` as "something is in the way", removes the destination, then renames again. The SFTP fallback maps every `SFTPError` (permission denied, no such file) to a 550.
- Scenario: an FTP account that may delete but not rename (RNFR/RNTO answers 550/502), or an SFTP server without `posix-rename`. FileJob's `extend` writes a temporary file, then calls `move(temporary, to: destination, replacing: true)`. The rename is refused, the destination is deleted, the second rename fails, and FileJob's catch discards the temporary. Both old and new file are gone.
- The same happens when the second rename fails transiently after the remove.
- Fix: move the existing destination aside under a backup name, rename the new file in, then delete the backup; restore on failure. Only take this path when the server's answer plausibly means "exists". Do not turn every SFTP error into 550.

**2. LIST parser regexes are quadratic on long lines, and line length is unbounded** — security/freeze, confirmed by measurement
- Where: `FTPListParser.swift:129-133, 168-178`; `FTPConnection.swift:590-596`.
- What: the unanchored `(\d+)\s+…` patterns backtrack quadratically. A line `-rwxrwxrwx ` followed by N digits took 3.2 s at 8 KB, 13.6 s at 16 KB and 66 s at 32 KB for one of the three regexes.
- Scenario: a hostile server, or a man-in-the-middle on plain FTP, sends a few such lines. The listing thread spins for hours and cannot be cancelled. A batch of 2000 or more lines goes through `Parallel.map` and occupies every core of the shared pool.
- Related: `rest` grows without limit when no LF arrives, and is re-split on every block.
- Fix: reject lines over about 4 KB before parsing, cap `rest`, and anchor or pre-tokenise the patterns.

### Medium

**3. FTP replies are unbounded** — security/freeze, confirmed
- Where: `FTPReply.swift:35-48`; `FTPConnection.swift:294-301, 543-549`; `NetStream.swift:226-234`.
- What: a multi-line reply (`220-` followed by endless lines) accumulates forever; the timeout is per line, and one line may be about 1.25 MB.
- Scenario: `abortTransfer` and `isAlive` from the keep-alive read with `cancellation: nil`, so that thread never returns and memory grows.
- Fix: cap lines per reply (about 1000), bytes per reply (about 64 KB), line length (about 4 KB), and use one deadline per reply.

**4. Active mode can return a desynchronised connection to the pool** — correctness/data-loss, plausible
- Where: `FTPConnection.swift:471-474, 489-492`.
- What: after the 1xx reply, a cancel or timeout in `listener.accept` throws without setting `isBroken` and without reading the final reply. `release` sees `isUsable` and pools the connection.
- Scenario: the next command reads the stale 425/426, and the one after reads its predecessor's reply. An `MLST` that reads a foreign `250` returns nil ("does not exist"), so the following STOR overwrites without asking.
- Fix: once the command got a 1xx, any failure before `setStreams` must set `isBroken` unless the final reply was read.

**5. Active-mode listener accepts the first connection from anyone** — security, confirmed
- Where: `NetStream.swift:564, 571, 586-594`.
- What: the listener is on all interfaces and the peer is never compared with the control connection's remote address.
- Scenario: a LAN host that connects first receives the upload, or supplies the download or listing.
- Fix: check the accepted peer against `control.remoteAddress`, reject others and keep waiting; bind to the control connection's local address.

**6. Waits that are not cancellable and have no time limit** — threading/freeze, confirmed
- Where: `FTPSession.swift:113` (`loginLock.lock()`), `FTPSession.swift:202-232` (`acquire`), `SFTPSession.swift:84-86` (`connectLock`).
- What: while the first FTP login waits for the user at a password or certificate dialog, every other thread using that session blocks in `loginLock.lock()` with no way out. `makeDirectory`, `remove`, `rename` and `setAttributes` pass no cancellation in either protocol, so they also loop indefinitely in `acquire` or on `connectLock`.
- A reader waiting for a transfer slot also has no deadline: with four paused viewers on one server, a fifth read or a copy hangs silently.
- Fix: use `lock(before:)` in a loop with cancellation, as SFTP already does; give slot and pool waits a deadline and a clear error; pass a cancellation flag through the four mutating calls.

**7. Background link resolution holds a pooled command connection for up to 20 s and is unbounded in number** — performance/freeze, confirmed
- Where: `FTPSession.swift:421-435`; `RemoteFileSystem.swift:364-367, 246-257`.
- What: every listing with unresolved links queues a block that takes a command connection, with no cancellation and no yielding to waiting user commands.
- Scenario: with `parallelConnections` at 1, or three link-heavy folders, navigation stalls for 20 s or more. Rapid browsing piles blocks up in `acquire`, each one a blocked GCD thread, for folders the user has left.
- Side effect: each resolved link calls `cache.update`; once the listing is older than 10 s this forgets the directory and journals "unknown", so listings in flight are not stored and a copy job re-lists.
- Fix: one resolver per session, release the connection between probes when anyone waits, drop work for folders no longer shown, and make the observer a no-op when the entry is not cached.

**8. `Background.queue` can exhaust the process-wide GCD thread pool** — threading/freeze, plausible
- Where: `RemoteSession.swift:202-204`; `SFTPSession.swift:192-194, 366-372, 522-528`; `FTPSession.swift:599-607, 746-754`.
- What: every cancelled or dropped reader or writer queues a block that waits for a server (`closeHandle` up to `timeout`, `abortTransfer` 10 s or more) on a concurrent queue.
- Scenario: a stalled server plus Quick View stepping through files or many cancelled transfers produces dozens of blocked workers. At 64, every `DispatchQueue.global()` user in the app starves.
- Fix: a small fixed worker pool or a serial queue per session. For SFTP, send CLOSE synchronously (it is only a pipe write) and never wait for its answer.

**9. An SFTP channel is never declared dead after timeouts** — freeze, plausible
- Where: `SFTPChannel.swift:498-516`; `SFTPSession.swift:54-56`.
- What: a timeout abandons one request only. With keep-alive set to 0, or on a black-holed path, ssh does not exit.
- Scenario: every later request waits the full timeout again: a 1000-file delete costs 1000 × 30 s, a listing with 100 links 100 × 30 s, each cleanup block 30 s.
- Fix: close the channel after a timeout during which nothing arrived from the server; always pass `ServerAliveInterval`.

**10. SFTP CLOSE status is discarded** — data-loss, confirmed (code)
- Where: `SFTPSession.swift:186-188, 584-587`.
- What: `closeHandle` uses `try?`, so `close(attributes:)` reports success when the server's close fails (deferred write errors such as quota or NFS) or times out.
- Fix: the writer should send CLOSE itself and throw on a bad status.

**11. A mid-window SFTP write error can leave a hole that Resume accepts** — data-loss, plausible
- Where: `SFTPSession.swift:532-579`.
- What: up to 63 later writes are already on the wire when one fails. If the server refuses one (ENOSPC, EIO) and accepts the rest, the partial file has a 32 KB zero gap up to 2 MB before its end.
- Scenario: FileJob's `resumeInPlace` compares only the last 1 MB unless Verify is on, so the gap can survive into the finished file.
- Fix: on the first failed write, truncate the handle to the failed offset (`fsetstat` size) before closing.

**12. FTP upload length is checked only for REST+STOR** — data-loss, plausible
- Where: `FTPSession.swift:531-532, 784-790`.
- What: there is no SIZE check after APPE or plain STOR, and the check is silently skipped when SIZE gives no answer.
- Scenario: a server that implements APPE as STOR leaves a "resumed" file containing only the tail, with a 226. A truncated TLS upload that still gets a 226 is also undetected.
- Fix: after every binary upload on a server with SIZE, compare with `start + written`.

**13. Download-list lines can be injected through remote names** — security, confirmed mechanism
- Where: `DownloadList.swift:22-52`; `NetworkCommands.swift:328-331, 452-470`.
- What: lines are written as `displayPath + " -> " + target` with no escaping. Parsing splits on every `isNewline` character (LF, CR, U+2028, U+0085, VT), and `isSafeName` allows all of them and ` -> `.
- Scenario: a server offers a path like `/pub/payload -> /Users/me/Library/LaunchAgents/x.plist<U+2028>sleep:1`. If the user adds it to a list and runs the list, `/pub/payload` is downloaded to that local path, followed by a rename with `replacing: true`.
- Fix: refuse or escape names containing newline characters or the separator when writing; treat list contents as untrusted when running.

**14. One cancelled SFTP write can close the channel for everyone** — correctness, plausible
- Where: `SFTPChannel.swift:400, 437-441`.
- What: a cancel that arrives mid-packet gets 2 s, then the shared channel is closed.
- Scenario: on a slow uplink the pipe is always full, so cancelling one upload kills every other transfer and the panels.
- Fix: let the packet finish (it is at most about 32 KB) under the normal write timeout.

**15. Fixed 64-request window causes head-of-line blocking on slow links** — performance/correctness, plausible
- Where: `SFTPSession.swift:28, 405-410, 466`.
- What: the window is 2 MB whatever the line speed, and every `read` tops it up afterwards.
- Scenario: at 1 Mbit/s a listing queues 16 s behind each active transfer and times out at 30 s with two; a viewer that reads one page still pulls up to 2 MB.
- Fix: size the window from measured throughput (about 1–2 s of data), and top up only after a sequential continuation.

**16. `ServerKey.url` falls back to `file:///`, and IDN hosts change key** — correctness, confirmed by experiment
- Where: `ServerAddress.swift:44-51, 161`.
- What: `URLComponents.url` is nil for hosts containing `% # ? " < ^ { |`, a space or bidi characters, all of which `ServerAddress` accepts. The remote location silently becomes the local root.
- Also: `bücher.de` comes back as `xn--bcher-kva.de`. The announced profile and the panel URL then have different keys, so a second session logs in anonymously and the typed credentials are dropped.
- Fix: validate hosts in `ServerAddress` and `ServerKey` (IDNA-normalise once), and return an optional or throw instead of a file URL.

**17. A changed certificate is not distinguished from first use** — security, confirmed
- Where: `NetStream.swift:154-165`; `NetworkCommands.swift:55-76`.
- What: when a host already has an accepted fingerprint and presents a different untrusted certificate, the same dialog appears with "Yes" as the only button.
- Other observations: exceptions are keyed by host without port. Host A's exception cannot be used for host B.
- Fix: a distinct, stronger warning showing old and new fingerprints.

**18. "User declined" memory is also set by ordinary cancellation** — correctness, confirmed
- Where: `FTPSession.swift:174-181`; `SFTPSession.swift:141-146`.
- Scenario: the user leaves during a slow connect and retries within 5 s; the retry fails with "The operation was cancelled" without trying.
- Fix: record `declined` only when a dialog was refused.

**19. File names do not round-trip** — correctness, confirmed (code)
- Where: `FTPConnection.swift:50-59`; `SFTPChannel.swift:86, 120`.
- What:
  - FTP automatic mode decodes non-UTF-8 names as CP1252 but always encodes UTF-8.
  - Both protocols force NFC on send, so NFD names on byte-comparing servers are not found.
  - SFTP decodes invalid UTF-8 lossily.
  - `allowLossyConversion` turns unencodable characters into `?`, which can address a different file.
- Fix: keep the raw bytes with the entry, or at least remember the encoding and normalisation used to decode; fail on lossy encodes.

**20. The entry cache can answer "absent" wrongly before an overwriting STOR or rename** — data-loss, plausible
- Where: `RemoteFileSystem.swift:203-208, 466, 530`.
- What: lookups are case-sensitive and up to 10 s old. FTP STOR and `posix-rename` overwrite silently.
- Scenario: on a case-insensitive server, `File.txt` overwrites `file.txt` without a prompt; so does a file created elsewhere within the 10 s.
- Fix: before a destructive open or rename, treat a cached "absent" as unknown and ask the server.

### Low

**21. Close of a cancelled SFTP handle races with the following remove or rename** — correctness, plausible
- Where: `SFTPSession.swift:192-194, 494, 585`.
- What: `closeHandleLater` runs on another queue, so FileJob's remove of the partial file can reach the server first. Servers with Windows semantics refuse it and leave the partial file; handles also leak when the close times out.
- Fix: as in finding 8, send CLOSE in order and do not wait.

**22. Up to about 11 logins per server** — correctness, confirmed
- Where: `FTPSession.swift:60, 213-225`.
- What: 3 command connections plus 4 readers plus 4 writers at the default setting. Servers with a per-IP limit answer 421; after 10.5 s of back-off the transfer fails.
- Fix: one shared cap, with transfers borrowing idle command connections.

**23. Passwords handled against expectation** — security, confirmed
- `VolumeMounting.swift:35`: the mount error prints `url.absoluteString`, password included.
- `NetworkCommands.swift:273-276`: a quick-connect password is saved to the Keychain even when the user unticked "Keep the password".
- `NetworkCommands.swift:51`: the password is stored before the login succeeded.
- `SavedConnections.swift:35-42`: delete-then-add with results ignored loses the old password when the add fails.
- `ServerAddress.swift:197-205`: `removingPassword` misses addresses without `://` and passwords containing `/`. It is applied only to `lastServer`; other modules that store typed text (command line, target history) were not checked.

**24. ssh invocation and askpass**
- Sound: no option injection (host after `--`, user via `-l` and checked for a leading `-`, numeric port); nothing secret in argv, environment or files; FIFOs 0600 in a 0700 directory; stderr is capped at 8 KB and never parsed for prompts.
- `SFTPSession.swift:51-60`: missing `-o RemoteCommand=none`, `-o PermitLocalCommand=no`, `-o ControlMaster=no`, `-T`. With `ControlMaster auto` in the user's config, disconnecting can SIGTERM the master and end the user's terminal sessions.
- `SFTPSession.swift:68-79`: the first `@` is used, so a user name containing `@` never gets the stored password. A question without `@` gets it unconditionally.
- `SFTPSession.swift:112-119`: server-supplied keyboard-interactive text reaches the dialog unmarked, so a server can show "Enter passphrase for key …". A prompt containing `(yes/no` is treated as a confirmation.
- `SFTPSession.swift:113-118`: a wrong stored password is never re-asked; the saved connection fails until it is edited.
- `SFTPChannel.swift:202-208, 241-245`: `SSH_ASKPASS_PROMPT` (FIDO touch notices) is ignored. An answer written after the helper script died stays in the FIFO and answers the next question.
- `SFTPChannel.swift:292`: the last three stderr lines, which include the server banner, are shown as the error text.

**25. Smaller items**
- `SFTPChannel.swift:367`: the 64 MB packet limit is allocated on a hostile length; 1 MB is ample.
- `SFTPSession.swift:214-226`: link stats are waited one by one, each with a full timeout; tickets leak in `waiting` when a send throws.
- `SFTPSession.swift:454-463, 486-487`: a server with a read limit below 32 KB costs serial follow-ups per chunk; a seek discards everything in flight and the next small read asks for 256 KB.
- `SFTPSession.swift:126-131, 162-169`: `disconnect()` does not stop a login in progress, and a channel opened afterwards is stored in the closed session.
- `FTPConnection.swift:522-524`: a second 1xx is taken as the verdict and leaves the 226 unread.
- `FTPConnection.swift:581-596`: a listing has no entry or byte cap.
- `FTPSession.swift:209-212`: `currentProfile` is read after unlock (data race).
- `FTPSession.swift:629-632, 713-714`: `atEnd` is written by `close()` from another thread.
- `RemoteFileSystem.swift:591-599`: `location(from:)` announces as a side effect and can drop a session that is in the middle of its login.
- `NetStream.swift:470`: one dispatch per line read.
- `NetworkCommands.swift:111`, `NetworkPlugin.swift:166-168`: disconnect on the main thread, bounded at 2 s per idle FTP connection (QUIT) and 0.5 s per SFTP channel.
- `VolumeMounting.swift:32`: `NetFSMountURLSync` cannot be cancelled; it runs in a job, not on the main thread.

## Shared mutable state

| State | Protection | Verdict |
|---|---|---|
| `SFTPChannel.waiting`, `nextID`, `closed`, `errorText` | `lock` on every access | Sufficient |
| `SFTPChannel` pipe writes and fd close | `writeLock`, `isClosed` checked after locking | Sufficient |
| `Pending` | `NSCondition`, predicate loop, broadcast under lock | Sufficient; no lost wake-up |
| `SFTPSession` fields | `lock`; logins serialised by `connectLock` | Sufficient, except finding 25 (disconnect during login) |
| SFTP reader and writer | Single owner plus `CancellationFlag` | Sufficient |
| `NetStream` | `condition` for all state; callbacks on its own serial queue | Sufficient; every wait has a timeout; buffer bounded at about 1.25 MB |
| `FTPConnection` | Single owner; `streamsLock` for `interrupt` | Sufficient |
| `FTPSession` pool counters | `condition` | Accounting balanced on every path I traced; one unlocked read (finding 25) |
| `LinkMemory`, `EntryCache`, `CertificateTrust`, `NetworkOptions`, `ConnectionCenter` | Own lock each | Sufficient; all leaf locks except center → session state lock, which has no reverse path |
| `FTPReader` | `stateLock` for `active`, `isReading`, `wasClosed` | `atEnd` and `position` unprotected against a cross-thread `close()` |
| `NetworkCommands`, `ConnectionStore`, `ListRun` | Main thread only | Sufficient |

No lock-order inversion found. `Kernel.askUser` uses `main.sync` while `loginLock` or `connectLock` is held; this is safe only because no main-thread path takes those locks, which holds today.

## Checked and found sound

- `capabilities(for:)`, `places()`, `displayPath`, `parent(of:)` and `canAppend` take only short state locks, never one held during I/O.
- TLS: verification uses a host or IP policy, minimum TLS 1.2, PROT P is enforced, and USER/PASS are sent only after the handshake; a refused AUTH TLS is an error.
- PASV/EPSV: the address in the reply is ignored and the port is range-checked; data connections go to the control connection's peer.
- Command injection: CR, LF and NUL are rejected in every FTP command.
- Sliding-window bookkeeping: out-of-order replies, short replies, EOF mid-window, late replies to abandoned ids, and `interrupt()` giving up only its own ids are handled correctly; a failed write is sticky and `close` throws it.
- NetStream: send-piece ordering, the `waiting` state when the network is down (fails at once), and continuation patterns (no double resume) are correct.
- 421 back-off sleeps on the calling worker in 0.1 s slices and is cancellable.
- Keychain items carry no host or user in their attributes; URLs never carry credentials.
- The ssh child is reaped by `Process`.

## Could not review or verify

- Whether bytes following the `234` in the same segment go to TLS or to the application after `prependApplicationProtocol` (STARTTLS injection).
- How Network.framework reports a TLS stream that ends without close_notify, so download truncation by an active attacker is unassessed.
- Whether `NWConnection.cancel()` always flushes the last TLS records of an upload; the code relies on a test.
- Callers outside the plugin: where typed addresses with passwords are stored, and whether `FileReader.close()` (which blocks up to `timeout` for SFTP) is ever called on the main thread.
- Nothing was run against real servers; the project was not built and its tests were not run.
