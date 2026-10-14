# Review 2 — network

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent rulings on a finding and sit next to it by file. Status is filled in by the fix round.


## Findings and verdicts

### N001 [finding, critical] Hang listing an FTP folder (LIST regex backtracking)
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPListParser.swift:126-130
- **Basis:** reproduced
- **Detail:** Regexes used by unix(): a LIST line with a long digit run backtracks. 250 / 500 / 1000 / 2000 digits take 15 / 56 / 217 / 991 ms, so a 16 KB line takes about a minute. Reproducer repro/net/ftplist-regex-backtracking.txt (fuzz-net, target ftplist, --timeout 0.5).
- **Proposed fix:** Cap the line length and bound the digit runs (\d{1,20}).
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### N002 [finding, critical] RemotePath.normalized joins path components across '/' + combining mark (same class, no write)
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/ServerAddress.swift:65
- **Basis:** reproduced
- **Detail:** Same Character-split class as finding 1 but no write; reproducer repro/net/remotepath-slash-joins-combining-mark.bin (fuzz-net, target address).
- **Proposed fix:** Split and compare on UTF-8 bytes.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### N003 [finding, high] Add to Download List calls displayPath per item on main (est. 0.5-1.5 s for 300k remote items).
**Outcome:** fixed — see `status/network.md`


- **Where:** Plugins/Network/NetworkCommands.swift:327-330
- **Basis:** inferred (estimated)
- **Detail:** 
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### N004 [finding, high] LIST parser regexes are quadratic on long lines and line length is unbounded (security/freeze).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPListParser.swift:129-133, 168-178; Sources/Plugins/Network/FTPConnection.swift:590-596
- **Basis:** measured
- **Detail:** Unanchored (\d+)\s+... patterns backtrack quadratically. A line "-rwxrwxrwx " followed by N digits took 3.2 s at 8 KB, 13.6 s at 16 KB and 66 s at 32 KB for one of the three regexes. A hostile server or MITM on plain FTP sends a few such lines; the listing thread spins for hours and cannot be cancelled. A batch of 2000+ lines goes through Parallel.map and occupies every core of the shared pool. Related: rest grows without limit when no LF arrives and is re-split on every block.
- **Proposed fix:** Reject lines over about 4 KB before parsing, cap rest, anchor or pre-tokenise the patterns.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N005 [finding, high] Replacing move deletes the destination when the rename is refused for any reason (data loss).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteFileSystem.swift:533-543; Sources/Plugins/Network/SFTPSession.swift:270-275
- **Basis:** read
- **Detail:** move(replacing: true) treats every NetworkError.refused as "something is in the way", removes the destination, then renames again. The SFTP fallback maps every SFTPError (permission denied, no such file) to a 550. Scenario: an FTP account that may delete but not rename (RNFR/RNTO answers 550/502), or an SFTP server without posix-rename. FileJob extend writes a temporary file then calls move(temporary, to: destination, replacing: true); rename refused, destination deleted, second rename fails, FileJob catch discards the temporary. Both old and new file are gone. Same when the second rename fails transiently after the remove.
- **Proposed fix:** Move the existing destination aside under a backup name, rename the new file in, then delete the backup; restore on failure. Only take this path when the server answer plausibly means "exists". Do not turn every SFTP error into 550.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N006 [verdict, high] Network move(replacing: true) loses both files (as worded)
**Outcome:** refuted — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteFileSystem.swift:533-543; Sources/Plugins/Network/SFTPSession.swift:270-275; Sources/Plugins/FileOperations/FileJob.swift:731; Sources/Plugins/FileOperations/FileJob.swift:862-866
- **Basis:** REFUTED as worded (ran over FTP)
- **Detail:** Claim as worded REFUTED: moving ftp:/ro/a.txt (folder not writable) to ftp:/w/ with Overwrite sent RNFR, RNTO 550, DELE /w/a.txt, RNFR, RNTO 550; target gone, source intact, move failed.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### N007 [verdict, high] Network move deletes destination after any refused rename (underlying defect)
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteFileSystem.swift:533-543; Sources/Plugins/Network/SFTPSession.swift:270-275; Sources/Plugins/FileOperations/FileJob.swift:731; Sources/Plugins/FileOperations/FileJob.swift:862-866
- **Basis:** CONFIRMED (ran) over FTP
- **Detail:** Code deletes the destination after any refused rename whatever the reason. move(missing.txt -> keep.txt, replacing: true) deleted keep.txt even though the source never existed. Plain-rename SFTP path feeds the same branch (read, not run). By reading only: for an upload with Overwrite, discard (FileJob:731) then removes the temp, leaving nothing on the server though local source remains; for Append (FileJob:862-866) the existing remote file would be lost outright.
- **Source:** reports/26-verify-file-operation-data-loss-findings.md
- **Status:** open

### N008 [finding, high] Crash on a saved connection with a negative port
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/ServerAddress.swift:48
- **Basis:** reproduced
- **Detail:** components.port = port; URLComponents traps. Reached through an imported or damaged settings file. Reproducer repro/net/saved-connection-port-trap.json (fuzz-net, target saved).
- **Proposed fix:** Validate 1...65535 on decode.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### N009 [finding, medium] Files from FTP/SFTP are never quarantined (default quarantine(of:) returns nil), so downloaded apps/pkg/command files open without a Gatekeeper check.
**Outcome:** fixed — see `status/fileops-p2.md`


- **Where:** AFMKernel/FileSystem/FileSystemProvider.swift:362; Plugins/FileOperations/FileJob.swift:789; Plugins/FileOperations/FileJob.swift:860; Plugins/FileOperations/FileJob.swift:897; Resources/Info.plist; Plugins/MacIntegration/MacIntegrationPlugin.swift:118-121; Plugins/Archives/OpenArchive.swift:210
- **Basis:** read (confirmed)
- **Detail:** The remote provider inherits the default quarantine(of:) -> nil; no implementation in Plugins/Network; Info.plist has no LSFileQuarantineEnabled; Enter calls NSWorkspace.open. An .app, .pkg, .terminal or .command downloaded from a server opens with no Gatekeeper check. Archives fetched from a server and unpacked inherit nothing either.
- **Proposed fix:** Have the remote file system return a synthesised quarantine value (flags 0083, agent name) for everything it downloads, including viewer and archive temp copies; or set LSFileQuarantineEnabled and exempt local copies.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N010 [finding, medium] Cancellation not wired through in Network: FTPSession.loginLock.lock() is untimed and SFTPSession.connectLock cannot be cancelled for mkdir, remove, rename and setAttributes.
**Outcome:** fixed — see `status/archnet-p2.md`


- **Where:** Network/FTPSession.swift:113
- **Basis:** read (reviewer)
- **Detail:** 
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N011 [finding, medium] resolveLinksLater has no bound per session; link-heavy listings hold command connections up to 20 s each and can open login dialogs from a background task (BUG 6).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:423,426,169; Network/RemoteSession.swift:203
- **Basis:** read
- **Detail:** Medium, responsiveness. There is one task per listing with unresolved links. Each holds a command connection for up to 20 s and counts against parallelConnections, so three link-heavy listings can stall the next foreground listing. It can also open a login dialog from a background task (FS:169). Also an unbounded wait in acquire with a nil flag (FS:426).
- **Proposed fix:** One serial resolver per session with coalescing, yielding the connection between probes.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N012 [finding, medium] FTPReader.close() interrupts outside stateLock, so it can cut a recycled connection now used by another thread (BUG 1).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:702-706,710,644,646,216,696-698
- **Basis:** read (confirmed by reading both paths)
- **Detail:** Medium-low. Path 1: close() captures running and reading == true under stateLock, unlocks, then calls running?.connection.interrupt() at FS:710. Path 2: the reading thread hits end of file: setActive(nil) FS:644 -> finishTransfer -> release FS:646 puts the connection in idle. A third thread pops it at FS:216. Interleaving: close() unlocks; the reader finishes and releases; thread X acquires the connection; close() then cuts X's control stream. X sees a spurious connectionLost, which is not retried for mkdir/delete/rename (commandMayHaveRun) or for uploads.
- **Proposed fix:** Call interrupt() while holding stateLock, re-reading active, exactly as interrupt() does at FS:696-698.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N013 [finding, medium] FTPReader.close() can interrupt a recycled connection: connection captured under stateLock, unlocked, then interrupt() called.
**Outcome:** duplicate of N012 — see `status/network.md`


- **Where:** Network/FTPSession.swift:702-710; Network/FTPSession.swift:644-646; Network/FTPSession.swift:216; Network/FTPSession.swift:696-698
- **Basis:** read
- **Detail:** Meanwhile the reading thread reaches EOF and releases the connection to the idle pool and a third thread acquires it, getting a spurious connectionLost, which is not retried for mkdir, delete, rename or uploads.
- **Proposed fix:** Interrupt while holding stateLock after re-reading active, as interrupt() does at :696-698.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N014 [finding, medium] Network plugin stop and connect-failure completion block main on QUIT write / SFTP close (2 s per idle FTP connection, 0.5 s per SFTP session).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/NetworkPlugin.swift; Network/NetworkCommands.swift
- **Basis:** read
- **Detail:** Reviewer-reported row of section (c).
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N015 [finding, medium] NetworkPlugin.stop -> disconnectAll sends QUIT with a 2 s write timeout per idle FTP connection and up to 0.5 s per SFTP channel on main at quit.
**Outcome:** duplicate of N014 — see `status/network.md`


- **Where:** Plugins/Network/FTPConnection.swift:264
- **Basis:** read (reported as confirmed)
- **Detail:** Quit only.
- **Proposed fix:** Same.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### N016 [finding, medium] Download list is an unconfirmed script that can overwrite files silently (any scheme/absolute path/~ target, replacing: true, no prompt).
**Outcome:** fixed — see `status/network.md`


- **Where:** Plugins/Network/NetworkCommands.swift:359; Plugins/Network/DownloadList.swift:22-46; Plugins/Network/NetworkCommands.swift:455-456; Plugins/Network/NetworkCommands.swift:463; Plugins/Network/NetworkCommands.swift:468
- **Basis:** read (confirmed)
- **Detail:** Class: path construction / missing confirmation. Flow: list file read with String(contentsOf:) with no cap -> DownloadList (copy:, put:, move:, A -> B) -> fileSystems.location(from:) accepts any scheme, absolute path or ~ -> transfer -> move(arrived, to: to, replacing: true). Scenario: 'FTP Download From List' on an ftplist.txt that came with a download; a line 'ftp://evil/a -> /Users/me/.zshrc' copies a into ~ and renames it over .zshrc with no overwrite prompt; 'move:~/.ssh/id_ed25519 -> ftp://evil/k' uploads and deletes a key. Nothing is shown before the run starts.
- **Proposed fix:** Show the parsed actions and require confirmation; restrict to remote->local unless the line says put:; use replacing: false plus the normal overwrite question; cap the list size.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N017 [finding, medium] ListRun skipped lines are unbounded in an alert, and the method recurses once per unsupported line (stack overflow risk).
**Outcome:** fixed — see `status/network.md`


- **Where:** Plugins/Network/NetworkCommands.swift:441; Plugins/Network/NetworkCommands.swift:450
- **Basis:** inferred (plausible)
- **Detail:** Same pattern as Create Link alert, usually small. The method recurses once per unsupported line (:450), so a very long list of unsupported lines risks a stack overflow.
- **Proposed fix:** Cap at about 20 lines plus '... and N more'.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### N018 [finding, medium] Keychain calls (SecItemCopyMatching/Delete/Add) run on main in several network commands.
**Outcome:** fixed — see `status/network.md`


- **Where:** Plugins/Network/SavedConnections.swift:26-42
- **Basis:** inferred (plausible)
- **Detail:** Blocking call, plausible. Callers on main: NetworkCommands.edit and showConnections (password lookup when the editor opens, set on OK, copy on duplicate), the Disconnect 'save?' path, and askCredentials inside askUser. Duration: normally 5-50 ms; unbounded while securityd shows an unlock or permission prompt. Sound part: the login path reads the password on the connecting thread.
- **Proposed fix:** Run Keychain calls in a job or on a utility queue.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### N019 [verdict, medium] Downloaded files carry no quarantine attribute
**Outcome:** duplicate of N009 — see `status/network.md`


- **Where:** Sources/AFMKernel/FileSystem/FileSystemProvider.swift:278; Resources/Info.plist
- **Basis:** CONFIRMED (read)
- **Detail:** No quarantine code in Sources/Plugins/Network; protocol default returns nil; Info.plist has no quarantine key. Malicious or compromised server, user opens download: no Gatekeeper prompt. Low-medium.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N020 [finding, medium] Download-list lines can be injected through remote names (security).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/DownloadList.swift:22-52; Sources/Plugins/Network/NetworkCommands.swift:328-331, 452-470
- **Basis:** read
- **Detail:** Lines are written as displayPath + " -> " + target with no escaping. Parsing splits on every isNewline character (LF, CR, U+2028, U+0085, VT) and isSafeName allows all of them and " -> ". Scenario: a server offers /pub/payload -> /Users/me/Library/LaunchAgents/x.plist<U+2028>sleep:1; if the user adds it to a list and runs it, /pub/payload is downloaded to that local path followed by a rename with replacing: true.
- **Proposed fix:** Refuse or escape names containing newline characters or the separator when writing; treat list contents as untrusted when running.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N021 [finding, medium] Active mode can return a desynchronised connection to the pool (correctness/data loss).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPConnection.swift:471-474, 489-492
- **Basis:** inferred
- **Detail:** After the 1xx reply a cancel or timeout in listener.accept throws without setting isBroken and without reading the final reply. release sees isUsable and pools the connection. The next command reads the stale 425/426 and the one after reads its predecessor reply. An MLST that reads a foreign 250 returns nil ("does not exist"), so the following STOR overwrites without asking.
- **Proposed fix:** Once the command got a 1xx, any failure before setStreams must set isBroken unless the final reply was read. (Plausible.)
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N022 [finding, medium] File names do not round-trip (encoding and normalisation).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPConnection.swift:50-59; Sources/Plugins/Network/SFTPChannel.swift:86, 120
- **Basis:** read
- **Detail:** FTP automatic mode decodes non-UTF-8 names as CP1252 but always encodes UTF-8. Both protocols force NFC on send so NFD names on byte-comparing servers are not found. SFTP decodes invalid UTF-8 lossily. allowLossyConversion turns unencodable characters into ?, which can address a different file.
- **Proposed fix:** Keep the raw bytes with the entry, or at least remember the encoding and normalisation used to decode; fail on lossy encodes.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N023 [finding, medium] Unbounded FTP listing remainder re-split on every block (quadratic time, unbounded memory)
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPConnection.swift:592-594
- **Basis:** read
- **Detail:** rest is re-split in full on every 256 KB block, so a long line without a newline costs quadratic time and unbounded memory, separately from the regex.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N024 [verdict, medium] Catastrophic regex backtracking in FTP LIST parsing
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPListParser.swift:129-133; Sources/Plugins/Network/FTPConnection.swift:592-596; Sources/Plugins/Network/NetStream.swift:457-472; Sources/Plugins/Network/FTPConnection.swift:294-300
- **Basis:** CONFIRMED (ran), worse than claimed
- **Detail:** Worse than claimed. One line of '-rwxrwxrwx ' plus N digits took 3.4 s at 5,000, 20 s at 10,000, 78 s at 20,000, 268 s at 40,000. No line cap; readLine and the reply buffer are unbounded. Malicious FTP server; user opens any folder: one ~40 KB line holds a thread for minutes, many lines hold every core, a server that never sends a newline exhausts memory.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N025 [finding, medium] FTP replies are unbounded (security/freeze).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPReply.swift:35-48; Sources/Plugins/Network/FTPConnection.swift:294-301, 543-549; Sources/Plugins/Network/NetStream.swift:226-234
- **Basis:** read
- **Detail:** A multi-line reply (220- followed by endless lines) accumulates forever; timeout is per line and one line may be about 1.25 MB. abortTransfer and isAlive from the keep-alive read with cancellation: nil, so that thread never returns and memory grows.
- **Proposed fix:** Cap lines per reply (about 1000), bytes per reply (about 64 KB), line length (about 4 KB), use one deadline per reply.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N026 [finding, medium] Waits that are not cancellable and have no time limit (threading/freeze).
**Outcome:** fixed — see `status/archnet-p2.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:113; Sources/Plugins/Network/FTPSession.swift:202-232; Sources/Plugins/Network/SFTPSession.swift:84-86
- **Basis:** read
- **Detail:** While the first FTP login waits for the user at a password or certificate dialog, every other thread using that session blocks in loginLock.lock() (113) with no way out. makeDirectory, remove, rename and setAttributes pass no cancellation in either protocol so they loop indefinitely in acquire (202-232) or on connectLock (SFTP 84-86). A reader waiting for a transfer slot also has no deadline: with four paused viewers on one server a fifth read or a copy hangs silently.
- **Proposed fix:** Use lock(before:) in a loop with cancellation as SFTP already does; give slot and pool waits a deadline and clear error; pass a cancellation flag through the four mutating calls.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N027 [finding, medium] "User declined" memory is also set by ordinary cancellation.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:174-181; Sources/Plugins/Network/SFTPSession.swift:141-146
- **Basis:** read
- **Detail:** The user leaves during a slow connect and retries within 5 s; the retry fails with "The operation was cancelled" without trying.
- **Proposed fix:** Record declined only when a dialog was refused.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N028 [finding, medium] Background link resolution holds a pooled command connection for up to 20 s and is unbounded in number.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:421-435; Sources/Plugins/Network/RemoteFileSystem.swift:364-367, 246-257
- **Basis:** read
- **Detail:** Every listing with unresolved links queues a block that takes a command connection, with no cancellation and no yielding to waiting user commands. With parallelConnections at 1, or three link-heavy folders, navigation stalls 20 s or more. Rapid browsing piles blocks up in acquire, each a blocked GCD thread, for folders the user has left. Side effect: each resolved link calls cache.update; once the listing is older than 10 s this forgets the directory and journals "unknown", so listings in flight are not stored and a copy job re-lists.
- **Proposed fix:** One resolver per session, release the connection between probes when anyone waits, drop work for folders no longer shown, make the observer a no-op when the entry is not cached.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N029 [finding, medium] FTP upload length is checked only for REST+STOR (data loss).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:531-532, 784-790
- **Basis:** inferred
- **Detail:** No SIZE check after APPE or plain STOR, and the check is silently skipped when SIZE gives no answer. A server implementing APPE as STOR leaves a "resumed" file containing only the tail with a 226. A truncated TLS upload that still gets a 226 is also undetected. Plausible.
- **Proposed fix:** After every binary upload on a server with SIZE, compare with start + written.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N030 [finding, medium] A changed certificate is not distinguished from first use (security).
**Outcome:** fixed — see `status/shell-p2.md`


- **Where:** Sources/Plugins/Network/NetStream.swift:154-165; Sources/Plugins/Network/NetworkCommands.swift:55-76
- **Basis:** read
- **Detail:** When a host already has an accepted fingerprint and presents a different untrusted certificate, the same dialog appears with "Yes" as the only button. Other observation: exceptions are keyed by host without port; host A exception cannot be used for host B.
- **Proposed fix:** A distinct, stronger warning showing old and new fingerprints.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N031 [verdict, medium] FTPS: changed certificate gets the same trust dialog as a new one
**Outcome:** duplicate of N030 — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetStream.swift:154-165; Sources/Plugins/Network/NetworkCommands.swift:56-75
- **Basis:** CONFIRMED (read)
- **Detail:** A new fingerprint for a host that already has an accepted one gets the same dialog; 'Always trust' appends. On-path attacker against a server with a self-signed certificate. Medium for FTPS.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N032 [finding, medium] Active-mode listener accepts the first connection from anyone (security).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetStream.swift:564, 571, 586-594
- **Basis:** read
- **Detail:** Listener is on all interfaces and the peer is never compared with the control connection remote address. A LAN host that connects first receives the upload, or supplies the download or listing.
- **Proposed fix:** Check the accepted peer against control.remoteAddress, reject others and keep waiting; bind to the control connection local address.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N033 [verdict, medium] Download-list run overwrites files with no preview
**Outcome:** duplicate of N016 — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetworkCommands.swift:351-363; Sources/Plugins/Network/NetworkCommands.swift:468; Sources/Plugins/LocalFileSystem/LocalFileSystem.swift:439
- **Basis:** CONFIRMED (read)
- **Detail:** No preview after the file-name prompt; move(arrived, to: to, replacing: true) reaches plain rename(2). List also accepts put:, copy:, move:, so it can upload or move local files. Precondition: user runs a list file someone else wrote. ftp://evil/x -> ~/.zshenv silently replaces an existing file; copy step only asks if the source's own name exists.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N034 [finding, medium] The entry cache can answer "absent" wrongly before an overwriting STOR or rename (data loss).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteFileSystem.swift:203-208, 466, 530
- **Basis:** inferred
- **Detail:** Lookups are case-sensitive and up to 10 s old. FTP STOR and posix-rename overwrite silently. On a case-insensitive server File.txt overwrites file.txt without a prompt; so does a file created elsewhere within the 10 s. Plausible.
- **Proposed fix:** Before a destructive open or rename treat a cached "absent" as unknown and ask the server.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N035 [finding, medium] Background.queue can exhaust the process-wide GCD thread pool.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteSession.swift:202-204; Sources/Plugins/Network/SFTPSession.swift:192-194, 366-372, 522-528; Sources/Plugins/Network/FTPSession.swift:599-607, 746-754
- **Basis:** inferred
- **Detail:** Every cancelled or dropped reader or writer queues a block that waits for a server (closeHandle up to timeout, abortTransfer 10 s or more) on a concurrent queue. A stalled server plus Quick View stepping through files or many cancelled transfers produces dozens of blocked workers. At 64, every DispatchQueue.global() user in the app starves. Plausible.
- **Proposed fix:** Small fixed worker pool or a serial queue per session. For SFTP send CLOSE synchronously (a pipe write) and never wait for its answer.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N036 [finding, medium] One cancelled SFTP write can close the shared channel for everyone.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPChannel.swift:400, 437-441
- **Basis:** inferred
- **Detail:** A cancel arriving mid-packet gets 2 s, then the shared channel is closed. On a slow uplink the pipe is always full, so cancelling one upload kills every other transfer and the panels. Plausible.
- **Proposed fix:** Let the packet finish (at most about 32 KB) under the normal write timeout.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N037 [finding, medium] An SFTP channel is never declared dead after timeouts.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPChannel.swift:498-516; Sources/Plugins/Network/SFTPSession.swift:54-56
- **Basis:** inferred
- **Detail:** A timeout abandons one request only. With keep-alive set to 0, or on a black-holed path, ssh does not exit. Every later request waits the full timeout again: 1000-file delete costs 1000 x 30 s, a listing with 100 links 100 x 30 s, each cleanup block 30 s. Plausible.
- **Proposed fix:** Close the channel after a timeout during which nothing arrived from the server; always pass ServerAliveInterval.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N038 [finding, medium] SFTP CLOSE status is discarded, so close(attributes:) reports success when the server close fails (data loss).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:186-188, 584-587
- **Basis:** read
- **Detail:** closeHandle uses try?, so deferred write errors such as quota or NFS, or a close timeout, are not reported.
- **Proposed fix:** The writer should send CLOSE itself and throw on a bad status.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N039 [finding, medium] Fixed 64-request SFTP window causes head-of-line blocking on slow links.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:28, 405-410, 466
- **Basis:** inferred
- **Detail:** Window is 2 MB whatever the line speed and every read tops it up afterwards. At 1 Mbit/s a listing queues 16 s behind each active transfer and times out at 30 s with two; a viewer that reads one page still pulls up to 2 MB. Plausible.
- **Proposed fix:** Size the window from measured throughput (about 1-2 s of data) and top up only after a sequential continuation.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N040 [finding, medium] A mid-window SFTP write error can leave a hole that Resume accepts (data loss).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:532-579
- **Basis:** inferred
- **Detail:** Up to 63 later writes are already on the wire when one fails. If the server refuses one (ENOSPC, EIO) and accepts the rest, the partial file has a 32 KB zero gap up to 2 MB before its end. FileJob resumeInPlace compares only the last 1 MB unless Verify is on, so the gap can survive into the finished file. Plausible.
- **Proposed fix:** On the first failed write truncate the handle to the failed offset (fsetstat size) before closing.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N041 [finding, medium] ServerKey.url falls back to file:/// and IDN hosts change key.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/ServerAddress.swift:44-51, 161
- **Basis:** reproduced
- **Detail:** URLComponents.url is nil for hosts containing % # ? " < ^ { |, a space or bidi characters, all of which ServerAddress accepts; the remote location silently becomes the local root. Also bucher.de (bücher.de) comes back as xn--bcher-kva.de; the announced profile and panel URL then have different keys, so a second session logs in anonymously and typed credentials are dropped.
- **Proposed fix:** Validate hosts in ServerAddress and ServerKey (IDNA-normalise once) and return an optional or throw instead of a file URL.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N042 [finding, low] Mixed read-first and write-first workers could cross-wait on reader and writer slots.
**Outcome:** fixed — see `status/network.md`


- **Basis:** inferred (not proven)
- **Detail:** Hazard, not proven; depends on FileJob ordering.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N043 [finding, low] FTP abortTransfer and QUIT run on the worker after interrupt() has returned, up to 10 s plus 2 s per extra reply with no flag.
**Outcome:** not a defect — see `status/network.md`


- **Where:** Network/FTPConnection.swift:543-549
- **Basis:** read
- **Detail:** Latency after interrupt (not a bug).
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N044 [finding, low] No 421 retry for the second 'first' login thread (BUG 4).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:110,164
- **Basis:** read
- **Detail:** Two threads both read isFirst == true (FS:110). The second opens after the first succeeded, but the 421 retry at FS:164 requires !isFirst. On a one-connection server it fails instead of retrying.
- **Proposed fix:** Re-read hasConnected after taking loginLock.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N045 [finding, low] No 421 retry for the second 'first' thread.
**Outcome:** duplicate of N044 — see `status/network.md`


- **Where:** Network/FTPSession.swift:110; Network/FTPSession.swift:164
- **Basis:** read (reviewer)
- **Detail:** 
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N046 [finding, low] loginLock.lock() is untimed and uncancellable; a second first-login thread ignores Cancel until the first login or dialog ends.
**Outcome:** duplicate of N010 — see `status/network.md`


- **Where:** Network/FTPSession.swift:113
- **Basis:** read
- **Detail:** Low severity. loginLock is held during user dialogs, up to 4 attempts of ~12 commands x timeout (unbounded).
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N047 [finding, low] Potential deadlock if outside code calls a connecting provider method on main while a background thread holds loginLock/connectLock across askUser (main.sync).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:113; Network/SFTPSession.swift:84,119; FileOperations/FileOperationsPlugin.swift:507,552
- **Basis:** inferred
- **Detail:** Inside the module main never takes loginLock or connectLock, the only locks held across askUser. Main: provider.item/list/read/write -> FS.acquire -> openConnection -> loginLock.lock() (FS:113), or SS.open -> connectLock (SS:84). Background: holds that lock inside askCredentials/askSecret -> Kernel.askUser -> DispatchQueue.main.sync. The only outside callers checked (FileOperationsPlugin.swift:507 and :552) are inside jobs.run work; the rest left for the whole-program pass.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N048 [finding, low] Callers with isFirst == false take no loginLock, so several threads can queue credential dialogs one after another.
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:133,137,169
- **Basis:** read
- **Detail:** askUser call-site analysis.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N049 [finding, low] FTPSession.pause holds a pool slot for up to 10.5 s.
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:189
- **Basis:** read
- **Detail:** Sleeps in 0.1 s slices checking flag and isClosed.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N050 [finding, low] FTP keep-alive pulls all stale connections at once and pings them serially, up to 5 s each, while they still count against the limit.
**Outcome:** duplicate of N051 — see `status/network.md`


- **Where:** Network/FTPSession.swift:359-367
- **Basis:** read (reviewer)
- **Detail:** Reviewer.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N051 [finding, low] Keep-alive pulls all stale idle FTP connections at once and pings them serially (up to 5 s each), so a foreground command can wait N x 5 s (BUG 3).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:359-367,221
- **Basis:** read
- **Detail:** Low-medium, responsiveness. They still count in total, so a foreground command at FS:221 waits up to N x 5 s on a silently dead link. isAlive() (NOOP, up to 5 s, no cancellation) runs outside any lock, serially per stale connection.
- **Proposed fix:** Ping one at a time, or do not count pinged connections against the limit.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N052 [finding, low] list's external receive callback runs while a command connection is held; with parallelConnections = 1 a callback issuing another command on the same server waits forever when the flag is nil.
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:406; Network/RemoteFileSystem.swift:371
- **Basis:** inferred (not proven)
- **Detail:** Hazard, not proven.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N053 [finding, low] resolveLinksLater is unbounded per session and can raise a login dialog from a background task.
**Outcome:** duplicate of N011 — see `status/network.md`


- **Where:** Network/FTPSession.swift:423-426
- **Basis:** read (reviewer)
- **Detail:** 
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N054 [finding, low] Background.queue is concurrent and each item blocks a worker: FTP abort 10 s or more, SFTP closeHandle up to 30-600 s with no flag, resolveLinksLater up to 20 s.
**Outcome:** duplicate of N035 — see `status/network.md`


- **Where:** Network/FTPSession.swift:604,751,426; Network/SFTPSession.swift:193,371,527
- **Basis:** read
- **Detail:** GCD blocking and fan-out.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N055 [finding, low] FTPReader.close() from another thread races seek().
**Outcome:** duplicate of N056 — see `status/network.md`


- **Where:** Network/FTPSession.swift:663-679
- **Basis:** read (reviewer)
- **Detail:** 
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N056 [finding, low] FTPReader.close() from another thread races with seek() (BUG 2).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/FTPSession.swift:663-679,713-714,573
- **Basis:** read
- **Detail:** seek never calls begin(), so close() sees isReading == false. It then runs stop() and writes atEnd (FS:713-714) while the owner reads and writes atEnd/position/active unlocked. Outside the kernel contract (which only requires interrupt to be concurrent-safe) but inside the class's own documented promise (FS:573).
- **Proposed fix:** Bracket seek with begin()/end().
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N057 [finding, low] NetStream TLS verification (SecTrustEvaluateWithError) runs on the stream's serial queue and may block seconds on revocation checks.
**Outcome:** fixed (test added) — see `status/archnet-p2.md`


- **Where:** Network/NetStream.swift:141
- **Basis:** read
- **Detail:** Stalls only this stream.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N058 [finding, low] NetworkCommands.connect failure completion runs center.disconnect(key) synchronously on (assumed) main, waiting up to 2 s per idle FTP connection QUIT and 0.5 s for SFTP close.
**Outcome:** duplicate of N014 — see `status/network.md`


- **Where:** Network/NetworkCommands.swift:111; Network/FTPConnection.swift:264; Network/SFTPChannel.swift:535
- **Basis:** read (main-thread assumption unchecked)
- **Detail:** For FTP this is FC.close() per idle connection, a QUIT write waited up to 2 s (FC:264). For SFTP it is SC.close(), up to 0.5 s (SC:535). The report assumed job completions run on main and did not check.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N059 [finding, low] NetworkPlugin.stop() -> disconnectAll closes serially on main at quit, bounded at 2 s per idle FTP connection plus 0.5 s per SFTP session.
**Outcome:** duplicate of N014 — see `status/network.md`


- **Where:** Network/NetworkPlugin.swift:167; AFMKernel/Kernel.swift:84
- **Basis:** read
- **Detail:** Normally under a millisecond because the QUIT fits the socket buffer. It does not wait for worker threads.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N060 [finding, low] An unparsable SFTP packet ends the reader without terminating ssh.
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/SFTPChannel.swift:379
- **Basis:** read
- **Detail:** By design, but far-reaching.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N061 [finding, low] Any SFTP write time-out or a cancel mid-packet after the 2 s grace closes the whole channel for every transfer.
**Outcome:** duplicate of N036 — see `status/network.md`


- **Where:** Network/SFTPChannel.swift:440,448-450
- **Basis:** read
- **Detail:** By design, but far-reaching. Includes write timeouts in lockForWriting.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N062 [finding, low] The SFTP askpass dialog (askSecret) is raised while connectLock is held.
**Outcome:** not a defect — see `status/network.md`


- **Where:** Network/SFTPSession.swift:119
- **Basis:** read
- **Detail:** Not SS.lock, not writeLock.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N063 [finding, low] SFTPSession.disconnect() during a login leaves ssh alive.
**Outcome:** duplicate of N064 — see `status/network.md`


- **Where:** Network/SFTPSession.swift:127; Network/SFTPSession.swift:162
- **Basis:** read (reviewer)
- **Detail:** 
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N064 [finding, low] SFTPSession.disconnect() during a login does not stop it; the channel is stored on a closed session and ssh lives on (BUG 5).
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/SFTPSession.swift:162-169,127-129
- **Basis:** read
- **Detail:** SS:162-169 sees channel == nil. open() then stores the channel and sets hasConnected (SS:127-129) on a closed session. The ssh process lives until the session is deallocated.
- **Proposed fix:** Check isClosed at SS:127 and close created.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N065 [finding, low] SFTPSession.connectLock is uncancellable when no flag is passed (makeDirectory, remove, rename, setAttributes), and is taken by every SFTP operation even when connected.
**Outcome:** fixed — see `status/network.md`


- **Where:** Network/SFTPSession.swift:84
- **Basis:** read
- **Detail:** Polled with lock(before: 0.1), but uncancellable when the flag is nil. Held unbounded during a (re)login (dialog, plus timeout + 30 s).
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N066 [finding, low] VolumeMounting's unmount semaphore wait has no timeout; if the completion never fires the job thread hangs.
**Outcome:** fixed (test added) — see `status/archnet-p2.md`


- **Where:** Network/VolumeMounting.swift:42-48
- **Basis:** read
- **Detail:** One signal, one wait, value returns to 0 so no deallocation crash. mount (NetFSMountURLSync) and unmount block job threads and cannot be cancelled.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N067 [finding, low] RemoteFileSystem has no quarantine(of:), so downloads carry no mark while the general opener starts anything.
**Outcome:** duplicate of N009 — see `status/network.md`


- **Where:** Plugins/FileOperations/FileJob.swift:1071-1078
- **Basis:** read
- **Detail:** 
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### N068 [finding, low] Plain FTP sends PASS with no cleartext warning.
**Outcome:** fixed — see `status/network.md`


- **Where:** Plugins/Network/FTPConnection.swift:234-236
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N069 [finding, low] FTP active-mode listener binds all interfaces and takes the first peer without comparing it to the server.
**Outcome:** duplicate of N032 — see `status/network.md`


- **Where:** Plugins/Network/NetStream.swift:563-593
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N070 [finding, low] Whole-file reads without cap: download list.
**Outcome:** fixed — see `status/network.md`


- **Where:** Plugins/Network/NetworkCommands.swift:334; Plugins/Network/NetworkCommands.swift:359
- **Basis:** read
- **Detail:** Table 'Whole-file reads': no cap.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N071 [finding, low] Any URL from an untrusted file triggers an unprompted connection (anonymous FTP, or ssh as NSUserName() with the user's keys and config).
**Outcome:** fixed — see `status/shell-p2.md`


- **Where:** Plugins/Network/RemoteFileSystem.swift:57-84; Plugins/FolderTabs/TabFile.swift:71; Plugins/FolderTabs/FolderTabsPlugin.swift:263; Plugins/FolderTabs/FolderTabsPlugin.swift:417; Plugins/VirtualFolders/VirtualFoldersPlugin.swift:188-193; AFMShell/Window/PanelCoordinator.swift:32; AFMShell/Window/PanelCoordinator.swift:52; AFMShell/Panel/PanelDragAndDrop.swift:25
- **Basis:** read (confirmed)
- **Detail:** Rated LOW/MEDIUM. Sources: tab files, file lists (also an unbounded read), restored tabs at launch, viewer links (finding 2), and the private drag type afm.panel-item. Mitigation present: stored passwords only go to a matching scheme+host+port; an unknown SSH host key is asked about.
- **Proposed fix:** Connect implicitly only to saved or already-connected servers; otherwise ask 'Connect to X?'.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N072 [finding, low] Keychain access in the connection editor is normally 5-50 ms but unbounded during a system prompt (plausible).
**Outcome:** duplicate of N018 — see `status/network.md`


- **Where:** Plugins/Network/SavedConnections.swift:26-42
- **Basis:** inferred
- **Detail:** Plausible only.
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### N073 [finding, low] A second 1xx is taken as the verdict and leaves the 226 unread.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPConnection.swift:522-524
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N074 [finding, low] A listing has no entry or byte cap.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPConnection.swift:581-596
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N075 [verdict, low] Download-list line injection via server-supplied names
**Outcome:** duplicate of N020 — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPListParser.swift:32-35
- **Basis:** UNPROVEN (PLAUSIBLE, read)
- **Detail:** isSafeName rejects only / and NUL; DownloadList.parse splits on every Unicode newline. No / allowed per name so payload needs nested remote folder names. Precondition: malicious server, then 'Add to download list', then run.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N076 [finding, low] currentProfile is read after unlock (data race).
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:209-212
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N077 [finding, low] Up to about 11 logins per server.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:60, 213-225
- **Basis:** read
- **Detail:** 3 command connections plus 4 readers plus 4 writers at the default setting. Servers with a per-IP limit answer 421; after 10.5 s of back-off the transfer fails.
- **Proposed fix:** One shared cap, with transfers borrowing idle command connections.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N078 [finding, low] atEnd is written by close() from another thread (FTPReader).
**Outcome:** duplicate of N056 — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:629-632, 713-714
- **Basis:** read
- **Detail:** atEnd and position unprotected against a cross-thread close().
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N079 [verdict, low] FTPReader.close() cuts a connection already returned to the pool
**Outcome:** duplicate of N012 — see `status/network.md`


- **Where:** Sources/Plugins/Network/FTPSession.swift:702-710; Sources/Plugins/Network/FTPSession.swift:693-698; Sources/Plugins/Network/FTPSession.swift:644-647; Sources/Plugins/Network/FTPSession.swift:282-292; Sources/Plugins/Network/FTPSession.swift:320
- **Basis:** CONFIRMED (read) as a race, very narrow window
- **Detail:** close() snapshots active under stateLock and calls running?.connection.interrupt() after unlocking; interrupt() at 693-698 does it under the lock with an explaining comment. Sequence: reader hits EOF between 706 and 710, releases connection to the pool, another thread takes it, then close() closes its sockets. Closing thread must be preempted for a server round trip between two adjacent statements. User sees 'connection lost' on an unrelated transfer or rename/delete; repeatable commands reconnect silently (perform, 320).
- **Source:** reports/27-verify-threading-and-hang-findings.md
- **Status:** open

### N080 [finding, low] NetStream does one dispatch per line read.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetStream.swift:470
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N081 [verdict, low] Active-mode FTP data listener accepts first connection with no peer check
**Outcome:** duplicate of N032 — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetStream.swift:564-592; Sources/Plugins/Network/FTPConnection.swift:454
- **Basis:** CONFIRMED (read)
- **Detail:** NWListener(using: .tcp, on: .any), first connection wins, no peer check. Passive mode correctly reuses the control peer. Precondition: active mode (not default), plain FTP, attacker reaching the port in the window. Low.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N082 [finding, low] Disconnect on the main thread is bounded at 2 s per idle FTP connection (QUIT) and 0.5 s per SFTP channel.
**Outcome:** duplicate of N014 — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetworkCommands.swift:111; Sources/Plugins/Network/NetworkPlugin.swift:166-168
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N083 [verdict, low] Password saved despite unticking 'save password'
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetworkCommands.swift:233-235; Sources/Plugins/Network/NetworkCommands.swift:273-276
- **Basis:** CONFIRMED (read)
- **Detail:** edit() deletes it when unticked; the caller then sees none stored and saves profile.password. Precondition: quick connect with password in the address, then 'save session' on disconnect.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N084 [finding, low] A quick-connect password is saved to the Keychain even when the user unticked "Keep the password".
**Outcome:** duplicate of N083 — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetworkCommands.swift:273-276
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N085 [finding, low] The password is stored before the login succeeded.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/NetworkCommands.swift:51
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N086 [verdict, low] Password redirect via import (sub-ruling of claim 6)
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteFileSystem.swift:59-65
- **Basis:** CONFIRMED (read)
- **Detail:** Password lookup by UUID alone; redirect needs the victim's connection UUID, which is in their own export. Low-medium.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N087 [finding, low] location(from:) announces as a side effect and can drop a session that is in the middle of its login.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/RemoteFileSystem.swift:591-599
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N088 [finding, low] SSH_ASKPASS_PROMPT (FIDO touch notices) is ignored, and an answer written after the helper script died stays in the FIFO and answers the next question.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPChannel.swift:202-208, 241-245
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N089 [finding, low] The last three stderr lines, including the server banner, are shown as the error text.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPChannel.swift:292
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N090 [finding, low] The 64 MB packet limit is allocated on a hostile length.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPChannel.swift:367
- **Basis:** read
- **Detail:** 
- **Proposed fix:** 1 MB is ample.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N091 [finding, low] Server-supplied keyboard-interactive text reaches the dialog unmarked, so a server can show "Enter passphrase for key ..."; a prompt containing (yes/no is treated as a confirmation.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:112-119
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N092 [finding, low] A wrong stored password is never re-asked; the saved connection fails until it is edited.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:113-118
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N093 [finding, low] disconnect() does not stop a login in progress, and a channel opened afterwards is stored in the closed session.
**Outcome:** duplicate of N064 — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:126-131, 162-169
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N094 [finding, low] Close of a cancelled SFTP handle races with the following remove or rename.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:192-194, 494, 585
- **Basis:** inferred
- **Detail:** closeHandleLater runs on another queue so FileJob remove of the partial file can reach the server first. Servers with Windows semantics refuse it and leave the partial file; handles also leak when the close times out. Plausible.
- **Proposed fix:** As in finding 8: send CLOSE in order and do not wait.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N095 [finding, low] SFTP link stats are waited one by one each with a full timeout; tickets leak in waiting when a send throws.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:214-226
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N096 [finding, low] A server with a read limit below 32 KB costs serial follow-ups per chunk; a seek discards everything in flight and the next small read asks for 256 KB.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:454-463, 486-487
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N097 [finding, low] ssh invocation lacks -o RemoteCommand=none, PermitLocalCommand=no, ControlMaster=no and -T; with ControlMaster auto, disconnecting can SIGTERM the user master and end terminal sessions.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:51-60
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N098 [verdict, low] SFTP: changed host key handled by dialog
**Outcome:** refuted — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:52-59
- **Basis:** REFUTED (read)
- **Detail:** SFTP uses /usr/bin/ssh with no StrictHostKeyChecking override, so the system ssh handles a changed key rather than this dialog.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N099 [finding, low] Askpass uses the first @, so a user name containing @ never gets the stored password; a question without @ gets it unconditionally.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/SFTPSession.swift:68-79
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N100 [finding, low] SavedConnections delete-then-add with ignored results loses the old password when the add fails.
**Outcome:** fixed (test added) — see `status/archnet-p2.md`


- **Where:** Sources/Plugins/Network/SavedConnections.swift:35-42
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N101 [finding, low] removingPassword misses addresses without :// and passwords containing /.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/ServerAddress.swift:197-205
- **Basis:** read
- **Detail:** Applied only to lastServer; other modules that store typed text (command line, target history) were not checked.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N102 [verdict, low] Credential leak through VirtualLocation.prefix(of:) user-info
**Outcome:** refuted — see `status/network.md`


- **Where:** Sources/Plugins/Network/ServerAddress.swift:44-50; Sources/Plugins/Network/ServerAddress.swift:183; Sources/Plugins/Network/RemoteFileSystem.swift:591-598
- **Basis:** REFUTED as stated
- **Detail:** prefix(of:) would copy user-info, but panel URLs are built without credentials. Only a hand-written ftp://u:p@host/ in a tab file or afm.panel-item could carry one. Negligible.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N103 [finding, low] NetFSMountURLSync cannot be cancelled.
**Outcome:** fixed (test added) — see `status/archnet-p2.md`


- **Where:** Sources/Plugins/Network/VolumeMounting.swift:32
- **Basis:** read
- **Detail:** It runs in a job, not on the main thread.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N104 [finding, low] Mount error message prints the URL including the password.
**Outcome:** fixed — see `status/network.md`


- **Where:** Sources/Plugins/Network/VolumeMounting.swift:35
- **Basis:** read
- **Detail:** The mount error prints url.absoluteString, password included.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N105 [verdict, low] Password in typed address appears in mount-error alert
**Outcome:** duplicate of N104 — see `status/network.md`


- **Where:** Sources/Plugins/Network/VolumeMounting.swift:35; Sources/Plugins/Network/NetworkCommands.swift:383
- **Basis:** CONFIRMED (read)
- **Detail:** VolumeMounting puts url.absoluteString in the alert; NetworkCommands echoes typed text. Precondition: user typed smb://user:pass@host and the mount failed. On-screen only; no log write found but ui.report not traced to the end.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### N106 [finding, info] Archives L3 -> MAIN (password for an outer archive) and L5 -> MAIN (upload through a network provider) lock-to-main edges; MAIN -> L5 at quit, MAIN -> L4 (capabilities), MAIN -> placesCondition, MAIN -> DiskBlockCache.lock.
**Outcome:** not a defect — see `status/network.md`


- **Where:** AFMKernel/PluginAPI/Kernel.swift:102; AFMShell/Interaction/ProgressJobService.swift:223
- **Basis:** read
- **Detail:** Lock-order graph edges.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N107 [finding, info] loginLock, connectLock and L3 -> MAIN are safe only because main never calls a connecting or opening provider method; the invariant holds by convention only (one main-thread item(at:) would deadlock).
**Outcome:** duplicate of N047 — see `status/network.md`


- **Where:** Network/FTPSession.swift; Network/SFTPSession.swift
- **Basis:** read
- **Detail:** All provider call sites in AFMShell and in Navigation, Places, Clipboard, FolderTabs, Selection, SystemTools and FileOperations plugins were checked and are inside jobs or background closures.
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### N108 [finding, info] Several session/environment closures are set once on main and read from workers without a lock.
**Outcome:** not a defect — see `status/network.md`


- **Where:** Network/RemoteSession.swift:120-131; Network/NetworkCommands.swift:43-77; Network/NetworkPlugin.swift:105; Network/RemoteFileSystem.swift:20-22
- **Basis:** read
- **Detail:** SessionEnvironment.askCredentials/askToTrust/askSecret/log/declineMemory and ConnectionCenter.makeSession/storedPassword. Benign.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open


## Checked and found sound

### N109 [sound, info] Lock acquisition order is acyclic.

- **Basis:** read
- **Detail:** ConnectionCenter.lock -> {FS.condition -> NetworkOptions.lock | SS.lock}; loginLock -> FS.condition; connectLock -> SS.lock; connectLock -> writeLock -> SC.lock; {stateLock | holdLock} -> streamsLock, then NetStream.condition.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N110 [sound, info] No CancellationFlag.onCancel, DispatchGroup, NotificationCenter or DispatchQueue.main.sync in the module.

- **Basis:** read
- **Detail:** The only main dispatch is asyncAfter at NC:448. All cancellation is polled every 0.1-0.2 s.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N111 [sound, info] Main-thread pure-text paths are sound.

- **Basis:** read
- **Detail:** parent(of:), displayPath, capabilities.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N112 [sound, info] No onCancel registrations exist, so no token-lifetime issues.

- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N113 [sound, info] FTP pool is sound.

- **Basis:** read
- **Detail:** A connection is in exactly one of idle, inUse, or the hands of one thread; all moves are under condition. Slot accounting balances on every path (FS:235, 242, 254-256, 285, 300, 321). Keep-alive removes stale connections from idle before pinging (FS:359-360). disconnect racing a keep-alive ping or an opening connection is handled (FS:369-373, 275-278).
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N114 [sound, info] SFTP channel is sound.

- **Basis:** read
- **Detail:** Ids allocated and registered under lock with the closed check (SC:464-471). markClosed snapshots and fulfils every waiter with .closed (SC:387-395). Late answers to abandoned tickets are dropped (SC:381). Order is writeLock -> lock only. The reader thread captures self weakly, owns its fd, and exits on EOF after terminate.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N115 [sound, info] FTPConnection.lastUsed/isUsable reads under FS.condition by a non-owner are sound.

- **Basis:** read
- **Detail:** Ownership hand-off goes through that lock.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N116 [sound, info] SFTPChannel.extensions and writeTimeout are written before the channel is published.

- **Basis:** read
- **Detail:** Sound.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N117 [sound, info] No @unchecked Sendable, no lazy vars, static lets immutable.

- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N118 [sound, info] Deinits are non-blocking.

- **Basis:** read
- **Detail:** NS:338 and FS:78 are non-blocking. Reader/writer deinits hand work to Background.queue. SC.deinit calls close(), whose writeLock is always free then.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N119 [sound, info] Keychain I/O location is as intended.

- **Basis:** read
- **Detail:** center.session(for:) (RFS:77) runs on the calling worker; NC:51 runs on main inside the dialog.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N120 [sound, info] RemoteFileSystem holds no lock across session calls.

- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N121 [sound, info] Network connect, list, mount, eject and disconnect run in jobs or on a utility queue.

- **Basis:** read
- **Detail:** FTP and SFTP state locks are never held during I/O. center.connected and capabilities(for:) are short. There is no DNS on main.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### N122 [sound, info] Network group executions

- **Basis:** reproduced
- **Detail:** 3,515,177 asan and 3,047,481 rel executions: 1 crash, 1 hang, 1 mismatch.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### N123 [sound, info] FTPSession.acquire wait is sound.

- **Where:** Network/FTPSession.swift:208-232
- **Basis:** read
- **Detail:** Predicate loop, 0.2 s timed. Broadcasts at FS:257, 292, 302, 371, 396.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N124 [sound, info] FTPReader.interrupt is sound.

- **Where:** Network/FTPSession.swift:693
- **Basis:** read
- **Detail:** Sets the flag, then cuts the connection under stateLock. active is cleared under that lock before every release (FS:644, 683). Cannot hit a recycled connection and is non-blocking.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N125 [sound, info] FTPWriter.interrupt is sound, also after close.

- **Where:** Network/FTPSession.swift:802,796-799
- **Basis:** read
- **Detail:** Guarded by holdLock/isHolding, cleared before release.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N126 [sound, info] NetStream.wait is sound.

- **Where:** Network/NetStream.swift:430-437
- **Basis:** read
- **Detail:** Predicate loop, timed. Every state change broadcasts under the same lock (NS:360, 404, 549). No missed wakeup.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N127 [sound, info] Pending.wait is sound.

- **Where:** Network/NetStream.swift:74-80
- **Basis:** read
- **Detail:** Predicate loop, 0.1 s timed, broadcast.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N128 [sound, info] NC.disconnect detaches on main and closes on a global queue.

- **Where:** Network/NetworkCommands.swift:285-286
- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N129 [sound, info] capabilities(for:) never blocks.

- **Where:** Network/RemoteFileSystem.swift:500
- **Basis:** read
- **Detail:** Takes center.lock, then FS.condition (FS:509) and NetworkOptions.lock.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N130 [sound, info] location(from:) / center.announce and store.onChange -> center.setSaved are non-blocking in practice.

- **Where:** Network/RemoteFileSystem.swift:591; NetworkPlugin.swift:103
- **Basis:** read
- **Detail:** FTP has no idle connections before the first login, and SFTP has no channel yet.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N131 [sound, info] places(), volume(of:), the menu enabled closure and NC.disconnect go through short locks.

- **Where:** Network/RemoteFileSystem.swift:602,608; NetworkPlugin.swift:136; NetworkCommands.swift:250
- **Basis:** read
- **Detail:** center.connected -> center.lock then session locks (microseconds).
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N132 [sound, info] CachingWriter.interrupt forwards.

- **Where:** Network/RemoteFileSystem.swift:647
- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N133 [sound, info] writeLock waits are timed and all NSLocks lock and unlock on the same thread.

- **Where:** Network/SFTPChannel.swift:406,535
- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N134 [sound, info] SFTP reader/writer interrupt is flag-only and always safe.

- **Where:** Network/SFTPSession.swift:497,596
- **Basis:** read
- **Detail:** They never close the shared channel.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N135 [sound, info] VolumeMounting semaphore usage is balanced.

- **Where:** Network/VolumeMounting.swift:42-48
- **Basis:** read
- **Detail:** One signal, one wait, value returns to 0, so no deallocation crash; failure is ordered by the semaphore.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N136 [sound, info] FTP protocol: PASV address ignored in favour of the control peer; CR/LF/NUL rejected in commands; PASS masked in log; ports clamped.

- **Where:** Plugins/Network/FTPConnection.swift:446-454; Plugins/Network/FTPConnection.swift:314; Plugins/Network/FTPConnection.swift:236; Plugins/Network/NetStream.swift:328
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N137 [sound, info] Server and archive names rejected or normalised at the source and again at the sink; decoded and combined names reduced to one component.

- **Where:** Plugins/Network/FTPListParser.swift:32-35; Plugins/Network/FTPListParser.swift:55; Plugins/Network/FTPListParser.swift:91; Plugins/Network/FTPListParser.swift:111; Plugins/Network/SFTPSession.swift:211; Plugins/Archives/ArchiveTree.swift:81-84; Plugins/FileOperations/FileJob.swift:1499-1514; Plugins/FileTools/Transcoding.swift:519-525; Plugins/FileTools/SplitCombine.swift:242-244
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N138 [sound, info] TLS: system evaluation with host name, TLS 1.2 minimum, per-host SHA-256 exceptions; refused AUTH TLS fails instead of downgrading; PROT P enforced.

- **Where:** Plugins/Network/NetStream.swift:136-165; Plugins/Network/NetStream.swift:237-262; Plugins/Network/FTPConnection.swift:224-232
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N139 [sound, info] Credentials: passwords only in the Keychain, stripped from history and last-server.

- **Where:** Plugins/Network/SavedConnections.swift:234-236; Plugins/Network/NetworkCommands.swift:373; Plugins/Network/NetworkCommands.swift:386
- **Basis:** read
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N140 [sound, info] ssh invocation: no option injection (host after --, user via -l checked for leading -, numeric port); nothing secret in argv, environment or files; FIFOs 0600 in a 0700 directory; stderr capped at 8 KB and never parsed for prompts.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N141 [sound, info] Shared state: SFTPChannel.waiting/nextID/closed/errorText under lock; pipe writes and fd close under writeLock; Pending uses NSCondition with predicate loop (no lost wake-up); SFTPSession fields under lock with logins serialised by connectLock (except disconnect during login); SFTP reader/writer single owner plus CancellationFlag; NetStream condition for all state, every wait has a timeout, buffer bounded at about 1.25 MB; FTPConnection single owner with streamsLock for interrupt; FTPSession pool counters under condition, balanced on every traced path; LinkMemory, EntryCache, CertificateTrust, NetworkOptions, ConnectionCenter each own lock, leaf locks except center -> session state lock with no reverse path; NetworkCommands, ConnectionStore, ListRun main thread only.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** No lock-order inversion found. Kernel.askUser uses main.sync while loginLock or connectLock is held; safe only because no main-thread path takes those locks, which holds today.
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N142 [sound, info] capabilities(for:), places(), displayPath, parent(of:) and canAppend take only short state locks, never one held during I/O.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N143 [sound, info] TLS: verification uses a host or IP policy, minimum TLS 1.2, PROT P enforced, USER/PASS sent only after the handshake; a refused AUTH TLS is an error.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N144 [sound, info] PASV/EPSV: address in the reply is ignored and the port range-checked; data connections go to the control connection peer.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N145 [sound, info] Command injection: CR, LF and NUL are rejected in every FTP command.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N146 [sound, info] Sliding-window bookkeeping handles out-of-order replies, short replies, EOF mid-window, late replies to abandoned ids and interrupt() giving up only its own ids; a failed write is sticky and close throws it.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N147 [sound, info] NetStream send-piece ordering, the waiting state when the network is down (fails at once), and continuation patterns (no double resume) are correct.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N148 [sound, info] 421 back-off sleeps on the calling worker in 0.1 s slices and is cancellable.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N149 [sound, info] Keychain items carry no host or user in their attributes; URLs never carry credentials.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N150 [sound, info] The ssh child is reaped by Process.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N151 [sound, info] No critical issue, and no way for the main thread to block on a server for more than about 2 s.

- **Where:** Sources/Plugins/Network/
- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open


## Not covered / left behind

### N152 [gap, info] Not read in full: FTPListParser.swift, FTPReply.swift, ServerAddress.swift.

- **Basis:** read
- **Detail:** Only grepped for concurrency constructs (only static let regexes, calendars and tables).
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N153 [gap, info] Nothing was built or run; every finding is from reading.

- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N154 [gap, info] Callers outside the module that might call a connecting provider method on main were not checked beyond FileOperationsPlugin.swift:507 and :552.

- **Basis:** read
- **Detail:** Left for the whole-program pass.
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N155 [gap, info] Not covered: FTP LIST date and size parsing, SFTP attribute decoding bounds.

- **Basis:** 
- **Detail:** 
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### N156 [gap, info] Whether bytes following the 234 in the same segment go to TLS or to the application after prependApplicationProtocol (STARTTLS injection) was not reviewed.

- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N157 [gap, info] How Network.framework reports a TLS stream that ends without close_notify is unknown, so download truncation by an active attacker is unassessed.

- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N158 [gap, info] Whether NWConnection.cancel() always flushes the last TLS records of an upload was not verified; the code relies on a test.

- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N159 [gap, info] Callers outside the plugin not checked: where typed addresses with passwords are stored, and whether FileReader.close() (blocks up to timeout for SFTP) is ever called on the main thread.

- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N160 [gap, info] Nothing was run against real servers; the project was not built and its tests were not run.

- **Basis:** read
- **Detail:** 
- **Source:** reports/14-review-network-second-round.md
- **Status:** open

### N161 [gap, info] Job-completion thread (main or not) for NC.connect failure completion was assumed, not checked.

- **Where:** Network/NetworkCommands.swift:111
- **Basis:** read
- **Detail:** 
- **Source:** reports/03-network-plugin-threading-audit.md
- **Status:** open

### N162 [gap, info] Keychain prompt behaviour is plausible only, not verified.

- **Where:** Plugins/Network/SavedConnections.swift:26-42
- **Basis:** 
- **Detail:** 
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open
