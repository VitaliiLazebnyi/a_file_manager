# Review 2 — archives: status of the fix round

Files changed: everything in `Sources/Plugins/Archives` (`OpenArchive.swift` and `ArchiveFileSystem.swift` largely
rewritten), `Tests/PluginTests/Archives{Fix,Format,Plugin}Tests.swift` (five expectations adapted to deliberate
changes, listed under Tests), new `Tests/PluginTests/Review2ArchivesSafetyTests.swift` and
`Review2ArchivesWriteTests.swift`. Requests to other areas: `documentation/review-2/cross-requests/archives.md`.

Short names below: OA = OpenArchive.swift, AFS = ArchiveFileSystem.swift, BS = ByteStreams.swift.

## Findings and verdicts

| ID | Status | Note |
|---|---|---|
| A001 | fixed | AFS `location(from:)` + OA `Volume.kind(ofLocalPath:)`: the disk is asked only where every volume on the path is a local disk by the cached mount table (`getfsstat(MNT_NOWAIT)`), links followed by hand; on a server the text decides. A folder named like an archive is found out in the background (`resolve` falls back to the folder). Tested for local paths; the server branch cannot be tested without a network mount. |
| A002 | duplicate of A001 | |
| A003 | fixed | OA `capabilities` reads a value published under a lock of its own that nothing is done under (`publish()`); it no longer takes the directory lock. Also: `isCurrent` stats and `finishWrite` asks for room outside the lock. |
| A004 | duplicate of A003 | |
| A005 | fixed | ArchiveTree.swift: `normalized`, `name(of:)`, `parent(of:)`, `relative(_:to:)`, `names(of:)` cut at the byte `/`; a path whose byte view and Character view disagree is refused; Unpacker.swift checks every target lies below its folder (`Unpacker.lies`). Both fuzz reproducers run in the test when present. FileTools and Network parts of the entry belong to other areas. |
| A006 | fixed | ArchivesPlugin.swift `stop()`: writes run on a background thread; main waits with the run loop turning, bounded by `quitTimeout`, then cancels; never takes the flush gate. Delayed writes do nothing once stopping. Proper quit UI needs the shell: cross-request 1. The timeout/cancel branch of `stop()` is not covered by a test. |
| A007 | fixed | ArchiveCommands.swift: the names to deselect are computed in the job, not in the completion on main. (The cost of `model.deselect` itself is the panel's.) |
| A008 | duplicate of A006 | |
| A009 | duplicate of A006 | flush is now cancellable (`environment.quitting`); `store.close()` still releases archives on the stopping thread. |
| A010 | duplicate of A006 | upload uses the caller's flag (timer: `environment.quitting`), no private flag. |
| A011 | fixed | AFS `flushAll`: innermost first, repeated until nothing waits or a round wrote nothing. |
| A012 | duplicate of A011 | test `oneCallWritesAnArchiveInsideAnArchive` (6 rounds). |
| A013 | fixed | ArchiveTree.swift: paths over 4096 bytes or 256 names are not listed; implicit folders are budgeted (48 MB of path bytes, then the archive is refused); entry cap `maxEntries`; ZIP directory loop and TAR indexing check the interrupt. |
| A014 | duplicate of A006 | flush gate is taken with a cancellable, polling wait. |
| A015 | duplicate of A003 | |
| A016 | fixed | OA `install`: a written entry that is gone from the tree and was new to the file counts as a removal, so the next write takes it out. Tests with the `whileWriting` hook. |
| A017 | duplicate of A016 | |
| A018 | fixed | Packer.swift `addThroughStore`: temporary name then `move(replacing:)`; AES encryption through `OpenArchive.write(_:level:password:)`; writer ended on every path; `options.level` honoured. |
| A019 | duplicate of A018 | |
| A020 | duplicate of A018 | |
| A021 | fixed | OA `retireIfIdle()` under the archive's lock; a retired archive throws `ArchiveError.retired` from every mutator and AFS `changing` re-resolves. The store drops an archive only after it retired. |
| A022 | fixed | Packer (`blocks`, remote `build`), Unpacker (`write`, member opens through an `InterruptSlot`), ArchiveCommands (unpackAndOpen, openAsArchive, showMember), tester, upload: cancellation variants plus `interrupting`. |
| A023 | fixed | ZipFormat.swift: WinZip AES read (AE-1/AE-2, 128/192/256) and write (AE-2, 256) with CommonCrypto; default for new archives; dialog says what it is and labels the old encryption as weak. Checked against the system's bsdtar in both directions. |
| A024 | duplicate of A021 | |
| A025 | duplicate of A022 | |
| A026 | fixed | `store.archive(at:cancellation:)` at all job sites; flush gate cancellable; `move`'s write uses `tryLock` (waits only behind another rename's small write); `isCurrent(cancellation:)`. |
| A027 | fixed | By construction: no archive with unwritten data leaves the table (A021), so there are no orphans for `flushAll` to miss. |
| A028 | duplicate of A021 | The double flush of orphan and successor cannot happen either. |
| A029 | duplicate of A013 | |
| A030 | duplicate of A005 | NUL is refused; other control characters are legal in names and kept. |
| A031 | fixed | Codecs.swift/OA: before a child opens the archive by path, the path must still be the file that was listed (`RandomAccessFile.isStillAtItsPath`); a member found by number is checked against its entry (size or name). The child still opens by path (a small window remains). |
| A032 | duplicate of A006 | |
| A033 | fixed | OA: members under `.afm-<UUID>.tmp` are never put into a snapshot, are not a pending change, keep the archive from being retired, and are not rescued. Existing leftovers in old archives are still shown (not hidden). |
| A034 | fixed | AFS `open` resolves the real file (`Durable.realFile`); Packer does the same. |
| A035 | fixed | `OutputFile.close(durably:)` (`F_BARRIERFSYNC`, else `fsync`) before every rename that replaces an archive (OA build, Packer build/append, rescue), then `fsync` of the folder. Power loss itself not tested. |
| A036 | duplicate of A035 | |
| A037 | duplicate of A034 | |
| A038 | fixed | ArchiveLocation.swift `ForeignArchive`: only 7z, RAR, CAB, XAR, cpio, ISO 9660, LHA by signature, and only with a zero byte in the first line (checked against the system's bsdtar: such a file is never read as mtree). `.Z` goes through `gzip -dc` and the plugin's own TAR reader. |
| A039 | not a defect | Accepted trade-off, see Decisions. |
| A040 | fixed | OA/AFS/BS: free-space check before and during materialising and fetching (`scratchReserve`, `SpaceWatch`); a copy that is given up is truncated at once; idle archives are evicted by the room their copies take (`scratchBudget`). |
| A041 | needs other area | Needs a batch/ordered read from the copy job: cross-request 4. No local change. |
| A042 | fixed | OA `unlocked`: one question at a time per archive, waiters reuse the answer, several passwords remembered, a refusal sticks for the operation (`withPasswordScope`: Unpack, Test) and for `passwordRefusalMemory` (5 s in the program). |
| A043 | fixed | OA `armTimer`: a second timer at user-initiated QoS `escalationDelay` (5 s) after the first. Not covered by a test (would depend on load). |
| A044 | needs other area | Cross-request 3. |
| A045 | fixed | OA `timerFired`: delay doubles per failure up to `maxRetryDelay` (1 h); a change re-arms at once. Not covered by a test. |
| A046 | fixed | OA `newSpool`: when the archive is on another volume than the temporary folder, new members wait in a hidden folder next to it; the room is watched while a large member comes in. The other-volume branch is not covered by a test (needs a second volume). |
| A047 | fixed | Packer.swift: existing local ZIP is rewritten inside `OpenArchive.whileHoldingFile` (gate held, pending changes written first, signature checked before the rename); flush failures are no longer ignored; mode kept. |
| A048 | duplicate of A023 | |
| A049 | fixed | `ArchiveEnvironment.maxEntries` (4,000,000), clear error. |
| A050 | refuted | |
| A051 | not fixed | See Not done. |
| A052 | fixed | AFS `archive(at:)`: an open, current archive is returned without the slot lock. |
| A053 | fixed | No detached archives with data (A021); timers do nothing after stop/close. |
| A054 | duplicate of A003 | |
| A055 | not a defect | By design one thread opens an archive and the others wait; every wait is cancellable with a flag, and questions about an open archive no longer take the slot lock (A052). |
| A056 | duplicate of A001 | |
| A057 | not a defect | Still true that the main thread must not call item/list/read; documented in the class comments. With A052 an open archive's look-ups do not touch the slot lock. |
| A058 | fixed | BS `ScratchFolder.sweepLeftovers`, run at plugin start in the background. |
| A059 | fixed | Codecs.swift `Tool.filter`/`collect`: dedicated threads, not pool workers. |
| A060 | fixed | Codecs.swift: stderr kept up to 64 KB. |
| A061 | fixed | Timers check `isStopping`; `store.close()` sets it. Timers hold the archive strongly on purpose (an existing test requires pending changes to keep it alive). |
| A062 | fixed | OA `FlushGate`: a waiter lends the holder its QoS (`pthread_override_qos_class_start_np`). Effect not measured. |
| A063 | not a defect | Deinits only unlink and terminate. |
| A064 | fixed | OA `park`/`armReaper`: one sweep per archive. |
| A065 | duplicate of A042 | |
| A066 | fixed | `reportFailure` no longer waits for the dialog (ArchivesPlugin.swift); busy archives remain uncapped (they hold unwritten data). |
| A067 | fixed | No polling: the end of the last writer arms the timer. |
| A068 | duplicate of A066 | |
| A069 | fixed | `armTimer` replaces a later deadline with an earlier one. |
| A070 | not a defect | Bounded by design; stderr readers moved off the pool (A059). |
| A071 | duplicate of A052 | `isCurrent` is not rate-limited for local files (a stale listing after an external change would be worse than one stat). |
| A072 | duplicate of A021 | |
| A073 | fixed | AFS: only notAnArchive/damaged/unsupported are remembered, for 30 s. |
| A074 | fixed | Nesting limit `maxNesting` (6). The host encoding is unchanged. |
| A075 | fixed | ArchiveTree.swift keeps the order by binary search instead of re-sorting. The copy of all entries per write remains. |
| A076 | not fixed | See Not done. |
| A077 | duplicate of A005 | |
| A078 | fixed | Outcomes keyed by archive identity. |
| A079 | fixed | BS `OutputFile` creates 0600; Packer gives a new archive group/other read only if every packed file has it; a replaced archive keeps its mode. |
| A080 | fixed | Codecs.swift `Tool.process`: fixed minimal environment, working folder `/var/empty`. Not sandboxed. |
| A081 | fixed | Codecs.swift `XZStream.decode`. |
| A082 | fixed | OA `rescue` writes `index-<id>.txt` beside the kept data. |
| A083 | fixed | Sweep (A058) covers scratch folders, `.afm-zip.tmp`, `.afm-pack.tmp` and spool folders noted in the `.external` list; folder 0700, files 0600. |
| A084 | fixed | OA `correctTime` verifies signature and name before patching; `canAppend` requires each member to end before the directory. |
| A085 | fixed | Signature from `fstat` of the open file. |
| A086 | fixed | Same loop as A011; test `oneCallWritesAnArchiveOnAServerThatKeepsWritesBack`. |
| A087 | duplicate of A038 | |
| A088 | fixed | OA `indexTar`: links by path, dropped when the path is reused. |
| A089 | fixed | OA `isCurrent` adopts the server's state as the mark when none is known. Not covered by a test. |
| A090 | fixed | OA `readInOnePass` throws when the stream ends early. Not covered by a test. |
| A091 | duplicate of A003 | |
| A092 | duplicate of A062 | |
| A093 | refuted | |
| A094 | fixed | OA `move` skips the rollback when the directory was re-read (`loadCount`); also restores the removal count. Not covered by a test. |
| A095 | duplicate of A018 | |
| A096 | fixed | Unpacker.swift `refuseLinks`: no folder below the target is entered through a symbolic link; a link where a file is to go is not written through. |
| A097 | duplicate of A096 | |
| A098 | fixed | Unpacker.swift: `unlock(only:)` with the members that are unpacked. |
| A099 | fixed | ZipFormat.swift: the ZIP64 end record is also looked for right in front of its locator. Tested with a hand-made stub, not a real ZIP64 SFX. |
| A100 | not a defect | Measurement, informational. |
| A101 | duplicate of A033 | |
| A102 | fixed | `streamStarts` reads under the lock. |
| A103 | not a defect | By design; the main thread never waits for the gate now, and waiters lend priority. |
| A104 | not fixed | Only partly: `capabilities` (the main-thread path) no longer takes this lock, and the stat in `isCurrent` and the room check in `finishWrite` moved out. Still under the lock: two `access()` calls per change, the clone probe (once), `install` (stat, open, rename) and `rebase` (re-reading the directory). None is reachable from the main thread. |

## Decisions

- **Encryption:** new ZIPs are encrypted with AES-256 (WinZip AE-2). The password form says which programs open it
  and offers "Use the old ZIP encryption instead (weak: …)". AES archives of other programs are read. Pack into a
  ZIP on a server or in another archive always uses AES.
- **`..` in member names:** the member is not listed and not unpacked (it stays in a ZIP that is rewritten).
  Leading slashes and `.` are still dropped. Names with a zero byte, over 4096 bytes or over 256 folders deep, and
  names where a `/` joins a neighbouring character, are treated the same way.
- **Foreign formats:** only 7z, RAR, CAB, XAR, cpio, ISO 9660, LHA go to bsdtar; `.Z` TARs go through gzip. No
  longer opened: `ar`, and TARs compressed with zstd, lz4, lzma, lzip (a compressed stream can hold an mtree
  list). Listing a foreign archive still means one full pass through bsdtar (A039, accepted).
- **Typed paths on servers:** a typed path that ends in an archive name on a network volume is the file, not the
  archive's root (Enter still opens it); one that goes on behind the name is a place in the archive.
- **Unpack and links:** nothing is unpacked through a symbolic link that already stands in the target folder,
  including links the user put there.
- **Quit:** waits up to 120 s for archive writes, then cancels them, keeps unwritten members on disk and reports
  where. If a write cannot even be cancelled, the program quits and no temporary file is deleted.
- **Limits:** 4,000,000 entries per archive; archives nest 6 deep; 2 GB stay free on the temporary volume; idle
  archives' temporary copies total at most 8 GB; failed writes retry after 30 s, doubling to 1 h.
- **Rights:** temporary and half-written files are 0600; a new archive is readable by group/others only if every
  file packed into it is.
- **Password refusal:** remembered for the Unpack/Test under way, and for 5 s for other reads.

## Tests

Added: `Tests/PluginTests/Review2ArchivesSafetyTests.swift` (18 tests), `Tests/PluginTests/Review2ArchivesWriteTests.swift` (17 tests).

Existing tests changed on purpose: three packs that are checked with `unzip -P` now ask for the old encryption
(ArchivesFixTests ×2, ArchivesFormatTests ×2 lines); the `../../evil.txt` member is expected to be hidden rather
than renamed (ArchivesFormatTests); the pack-dialog test ticks the old-encryption box (ArchivesPluginTests).

Final run, shared tree, `swift test --scratch-path .build-archives --filter Archive`:
136 tests in 8 suites passed, 0 failures (ArchiveAdoption, ArchiveFileSystems, ArchiveFixes, ArchiveFormats,
ArchiveCommandsInPanels, ArchiveJobsEndToEnd, Review2ArchivesSafety, Review2ArchivesWrites).
The same 136 passed three times in a row in a private copy built from the pre-round backup plus this area's files.
All of PluginTests in that copy: 1161 tests, 1 failure, `reportsChangesInWatchedFoldersOnly`
(LocalFileSystemTests.swift:189, a folder-watcher test outside this area).

## Not done

- **A051 / A076** (about 1.4 KB of memory per ZIP member): needs a compact entry representation; not attempted.
- **A041** (random-order reads of large stream archives): no local change; cross-request 4.
- **A044** (pending writes invisible to other operations): cross-request 3.
- **A104**: partly, see the table.
- **Quit UI** (progress sheet, Cancel): cross-request 1; `stop()` is the fallback.
- Not covered by tests: the timeout/cancel branch of `stop()`, timer escalation and back-off, spools next to an
  archive on another volume, the server branch of typed paths, A089, A090, A094, real power loss.
- `Tests/Fuzz` and `Tests/Stress` harnesses are separate packages that use this area's internals; they were not
  rebuilt against the changed code.
