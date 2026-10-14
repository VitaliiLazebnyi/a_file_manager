# Review 2, second pass — archives and network (`archnet-p2`)

Scope: `Sources/Plugins/Archives`, `Sources/Plugins/Network`, and their tests in `Tests/PluginTests`
(including `NetworkServerForTests.swift`). The archives half was done by a forked agent of this one, in its own
build folder; the rows below are its report, taken over as written. Requests to other areas:
`cross-requests/archnet-p2.md`.

## 0. The hang of the full PluginTests run

**Not reproduced as a hang** in this pass: the first full run on the tree as found ended (1568 tests, 86 s). So the
cause is stated from what was found in the code, and from runs under load afterwards, not from a sample of a hung
process. Three faults were found that fit what the other agents saw (a stall "inside the fake FTP server" after
`seeksWhileReading` and `aSendThatIsCancelledOnAFullPipeEnds` had failed), two in the test helper and one in the
product:

1. **Test helper, descriptors used after they were closed** (`NetworkServerForTests.swift`). `stop()` closed the
   listening socket while the accept thread could be about to call `accept` on it; a session closed its socket and
   only then took it out of the server's list; `dropConnections()` shut down the listed sockets outside the lock.
   The tests run side by side in one process, where a closed descriptor number is reused at once, so a stopped
   server could accept, or shut down, the connection of another test's server. Now the accept thread alone closes
   its socket after it has seen the stop (and `stop()` returns only then), a socket leaves the list before it is
   closed, and connections are shut down under the lock.
2. **Test helper, a 5 s limit for the data connection** (`acceptOne`). On a busy machine the client's `connect`
   came later and the transfer failed with 425. It now waits until the connection comes, the client says something
   else or hangs up, or the server stops.
3. **Product, one pool of six background threads for all servers** (`RemoteSession.swift`, `Background`). The
   clean-up of abandoned transfers on a server that does not answer (each waits for a time limit) held every
   thread, and the connections of every other server came back to their pools only afterwards. Beside a test with
   a dead server, other tests saw extra logins or a `waitUntilIdle` (which waited for the whole process) that ran
   out. Work now belongs to a lane (a session, a channel); at most 3 pieces of a lane run at once, 24 threads in
   all. Tests wait for their own session's lane (`FTPFixture.settle`).

Also fixed on the way, both product faults that showed as test failures under load:
- **The message of ssh was lost when a login failed** (`SFTPChannel.swift`; the SFTP test the kernel agent saw
  fail). The end of ssh's output was noticed before its last line on the error output was kept. The reading thread
  now reads the rest of the error output before it closes the channel, reading and keeping a piece is one step
  under a lock, and the thread that reports the failed login waits for that (at most 10 s).
- **A command opened a second login while the only connection was being tested by the keep-alive**
  (`FTPSession.acquire`). It now waits for the test for the same moment (0.5 s) as for a connection that is on its
  way back.

After the fixes: 4 full `PluginTests` runs in a private copy with 24 busy-loops beside them (load average over
150): none hung, no network or archives test failed. Final runs in the shared tree are under "Tests".

## 1. Items handled

### Network

| ID | Status | Note |
|---|---|---|
| Hang of the full run | fixed | See section 0. `NetworkServerForTests.swift`, `RemoteSession.swift` (`Background` lanes), `FTPSession.swift`, `SFTPChannel.swift`. Stated with the limit above: the hang itself was not reproduced before the fixes. |
| `seeksWhileReading`, `aSendThatIsCancelledOnAFullPipeEnds`, SFTP test under load | fixed | Per-session wait in place of the process-wide one; time limits of the tests widened where the fault they look for is a wait of minutes or for ever (the timeouts in those tests were raised to 600 s so that 120 s still tells the two apart); ssh's last words (above). One performance assertion (`movesDataThroughTheWindowInBothDirections`, "under 8 s") replaced by a count the fake server keeps: the most answers it owed at one moment. |
| N010 / N026 (cancellable changing calls) | fixed | `RemoteFileSystem` implements `createDirectory`, `remove`, `move`, `setAttributes` with `cancellation:`; `RemoteSession` takes the flag in the four calls; `withEither` joins it with the session's own flag (`RemoteSession.swift`, `FTPSession.swift`, `SFTPSession.swift`). Tested on FTP (a wait behind a login) and SFTP (a login that never ends, a request never answered). Whether Cancel reaches them depends on the callers passing the flag (cross-request 2). |
| N071 (typed address) | fixed | `NetworkPlugin` offers the kernel's `ServerConsentService` (`TypedAddresses`), `ConnectionCenter.noteChosen`. Nobody calls it yet (cross-request 1), so a typed address is still asked once until Navigation does. |
| N100 (Keychain update order) | fixed (test added) | `KeychainPasswords` makes its four Security calls through `Calls`, which a test replaces: update in place, add only when missing, delete only when asked, a refused change leaves the old password. No real Keychain is touched. |
| N066 / N103 (mount) | fixed (test added) | `SystemVolumeMounter` makes the system's calls through `Calls`: a mount never answered is taken back on Cancel with the request it was given; an eject never answered is given up after its time; late answers harm nothing. The real NetFS calls are still not exercised by a test. |
| N057 (certificate check queue) | fixed (test added) | `TLSSettings.beforeEvaluating` (a hook where the check runs). Test against the local TLS server: while one check is held, its own stream's time limit and flag still work and three other connections come to their verdicts. |
| network 3 (`defaultButton`) | fixed | "Connect to X?" and ssh's host-key question pass `defaultButton: 1` (Cancel / No). The changed-certificate dialog keeps its form with the box to tick. Takes effect once the shell implements the parameter. |
| config-a: bind the Keychain item to host, port, user | fixed (in pass 1, confirmed) | `PasswordVault.account(of:)`: identifier + scheme + user + host + port. Tested again here through the vault. |
| config-a: sweep of Keychain items without a connection | not fixed | Judged unsound, see Decisions. |
| config-b / kernel: `connectsToServer`, `root(of:)` | fixed | `RemoteFileSystem.connectsToServer` is true; `root(of:)` answers from the address. |
| kernel 12: `volume(of:cancellation:)` | not a defect | `RemoteFileSystem.volume(of:)` answers from memory and never waits. |
| kernel 14: `PathSafety` | fixed (partly) | `RemoteEntry.isSafeName` uses `PathSafety.isSafeName`. `RemotePath` stays: it already cuts at bytes and has rules `PathSafety` lacks (it resolves `..` in what the user typed instead of refusing, and keeps names apart from a slash they would join). |
| `BlockingCalls` | not a defect | The network code has no equivalent of its own; it is for callers of providers. |
| Settings keys | fixed | The plugin declares its keys with `Kernel.settingsKeys` (kinds in cross-request 3). |
| X007 (one SIGPIPE death) | not fixed | Not reproduced. The product's pipe writer sets `F_SETNOSIGPIPE`, the test server's sockets `SO_NOSIGPIPE`, the askpass pipe is held open at both ends; the kernel's handler is the net. |

### Archives

| ID | Status | Note |
|---|---|---|
| A051 | fixed | Compact directory: 396 bytes of live heap per ZIP member, was 975 by the same measure (200,064 members, 45-byte paths, 24 bytes of extra fields; the review's 1,425 was process footprint). `ArchiveTree.swift`: entries sit in one array and everything else refers to them by a 4-byte number. `ZipFormat.swift`: a record's name shares storage with the entry's path; extra fields and comment as plain byte arrays; `ZipDirectory.scan` hands records over one by one. `maxEntries` also lowered from 4,000,000 to 2,000,000 (see Decisions). |
| A076 | fixed | Same as A051. |
| A104 | fixed | `OpenArchive.swift`: no disk or provider call is left under the directory lock. The `access()` calls, the capability question for fetched archives and the clone probe moved to `requireWritable()` before the lock; spool folder and file are made outside it; `install` checks, opens and renames outside it; `rebase` opens the file and reads the directory outside it and only swaps under it. Still under the lock, memory only: the walk over written entries in `install` and the copy of all entries in `takeSnapshot`. |
| A041 | fixed | `ArchiveFileSystem.readOrder(of:)`: members of an archive that can only be read front to back come back in archive order. Only archives that are already open are looked at. Tested: 12 members asked backwards are read with one pass. |
| A044 | fixed | `ArchiveStore.bringUpToDate`, registered with `kernel.fileSystems.addFlusher`: commits open archives that are the given file, lie below the given folder, or are nested in such an archive, innermost first. The archives side is tested; `FileJob` already calls `flushPendingWrites`. |
| L043 (unpack) | fixed | `Unpacker.swift`, `UnpackFolder`: on local disks every folder is reached by `openat` with `O_NOFOLLOW` from the target's descriptor; files are created `O_EXCL|O_NOFOLLOW` under a temporary name and renamed with `renameat` / `renameatx_np(RENAME_EXCL)`; links with `symlinkat`. Tested with a link swapped in mid-unpack, a link two levels down, and a link the archive brings itself. Targets on servers, in other archives or on network volumes keep the path-based route, so the race remains there. |
| X008 | fixed | Cause was in the product: the delayed write ran on the system's shared queues and starved with them. It now starts on a thread of its own from a private clock queue (`ArchiveEnvironment.schedule`). The two tests also set `escalationDelay` to 0.3 s. Not re-run under the thread sanitizer. |
| F081 | fixed (in pass 1, confirmed) | `OpenArchive.capabilities` reads only the value published under `stateLock`. |
| F058 | fixed | `ArchiveCommands.swift` `unpack()`: `selectionCount`. No dedicated test. |
| Quit hook | fixed | `ArchivesPlugin.prepareToQuit(cancellation:completion:)` as the kernel defines it. After a cancel, `stop()` does not start the 120 s wait again; it keeps the data and reports where. `shouldTerminate` stays at the default. `kernel-p2.md` re-checked at the end: no other may-terminate hook. |
| `root(of:)` (K039) | fixed | `ArchiveFileSystem.root(of:)` answers without climbing. Tested equal to the climb for five kinds of location. |
| Absolute member paths | not a defect | Still stripped of the leading slash, not refused. Test `membersWithAbsolutePathsLandBelowTheFolderThatIsUnpackedInto` (ZIP and TAR): every such member lands below the target and nothing arrives at the claimed place. |
| Untested paths of pass 1 | fixed (partly) | Now tested: both timeout branches of `stop()`, timer escalation, back-off 30/60/100/100 s with reset after success, spools next to an archive "on another volume" (injected through `environment.volume`), A090. Not tested: A089, A094, the server branch of typed paths, real power loss. |
| Cross-requests to archives | fixed | fileops 1: `realLocation(of:)` for "outside" locations. fileops 2 / network 1: cancellable `createDirectory`, `remove`, `move`, `setAttributes`, `setQuarantine`, `volume(of:cancellation:)`. network 2(b): the fetched copy of a remote archive carries the download mark; 2(c) was in place. kernel 14: `PathSafety.isSafeName` / `isContained` in the Unpacker. shell 6: confirmed. The mark on the fetched copy and the pass-through to an outer provider are built, not asserted by a test. |
| fileops-p2 item 4 (pause inside a commit) | not fixed | `commit(_:cancellation:progress:)` appeared in `kernel-p2.md` at the very end of this pass; not adopted. |

## 2. Decisions

- **Background work per server:** at most 3 pieces per session or channel at a time, 24 threads in all (was 6 for
  everything).
- **A replacing move and Cancel:** on a server whose rename does not replace, the flag ends only the first step.
  Once the file in the way stands aside, the rest is seen through, so a Cancel cannot leave the name without a file.
- **A command waits up to 0.5 s for a connection the keep-alive is testing** before it logs in again.
- **A failed ssh login waits up to 10 s for ssh's last line** before it says "ended without a message".
- **No sweep of Keychain items that have no saved connection** (asked by config-a). An item is bound to
  identifier, host, port and user, so one left behind cannot be sent to another server. Deleting on the word of
  the settings list would turn an import of a foreign or damaged settings file into the loss of the user's
  passwords, which cannot be undone. Deleting a connection in the dialog still removes its password.
- **Return is Cancel / No** in "Connect to X?" and in ssh's host-key question.
- **Archives, entry limit 2,000,000** (was 4,000,000): at about 400 bytes per member the largest directory takes
  about 0.8 GB. One constant, `ArchiveEnvironment.maxEntries`, if 4,000,000 is wanted.
- **Unpacked files get no rights beyond the user's umask**, as `tar` and `unzip` do.
- **Symbolic links from an archive are made last** when members are unpacked in parallel; an archive with a link
  `x` and a member `x/file` gets a real folder `x`, and the link is reported as refused.
- **One problem line per folder that could not be made**; members below it are skipped without a line each.
- **Absolute member paths** are still stripped, not refused (tested to land below the target).
- **`readOrder`** reorders only front-to-back archives; ZIP and plain TAR keep the order asked.
- **`ArchivesPlugin.environment` and `.store`** are internal instead of private, so tests can set limits.
- **`BlockingCalls` not adopted in archives**; `ArchiveTree.normalized` stays (it has rules `PathSafety` lacks).

## 3. Tests

Added:
- `Tests/PluginTests/Review2NetworkP2Tests.swift` (19 tests: background lanes, cancellable changing calls on FTP and
  SFTP, typed addresses, the top of a server, Keychain call order, mount and eject with stand-ins, the certificate
  check, the test server itself).
- `Tests/PluginTests/Review2ArchivesP2Tests.swift` (16 tests), `Review2ArchivesP2MemoryTests.swift` (1 test).
- One test added to `NetworkPluginTests.swift` (the consent service and the declared settings keys).

Changed on purpose: `NetworkServerForTests.swift` (section 0); `NetworkFTPTests.swift`, `NetworkAdoptTests.swift`,
`NetworkFixTests.swift`, `NetworkFixSFTPTests.swift`, `Review2NetworkFTPTests.swift`,
`Review2NetworkSFTPTests.swift` (per-session waits, wider limits with longer timeouts, the count in place of the
8 s); `NetworkPluginTests.aTypedURLConnectsByItself` accepts "asked once" or "not asked";
`ArchivesFileSystemTests.swift`, `ArchivesFixTests.swift` (`escalationDelay`); `Review2ArchivesSafetyTests.swift`
(one line).

Final runs in the shared tree, `--scratch-path .build-archnet-p2`, after the last source change:
- `--filter "Archive|Network"`: **358 tests in 49 suites passed**, twice in a row.
- `--filter PluginTests` (everything): **1746 tests in 228 suites passed, 0 issues**, twice in a row (65 s and
  79 s). No hang.

Earlier runs, for the record:
- Network tests alone in a private package with 32 busy-loops beside them: 10 of 10 runs passed after the last
  fix. Before it, `theRealShellTakesTheOptionsAndTheBannerIsNotShownAsTheError` failed in about 1 run of 8.
- Three earlier full runs in the shared tree, built while other agents were editing: two died with
  `Fatal error: Index out of range` in `onlyChosenItemsAreSearched` (a FindFiles test, not this area); one ended
  with 9 issues, all in Viewer, CompareContent and tools tests. Neither showed in the final build.

## 4. Not done

- **The hang was not caught in the act.** The causes above are what the code and the runs under load point to. If
  a full run hangs again, sample it; the helper script used here was a loop that samples the test process when
  its log stops growing.
- **Callers:** nobody calls `ServerConsentService.userChose` yet, and Cancel reaches the four changing calls only
  where the caller passes its flag (cross-requests 1 and 2).
- **Kernel APIs that appeared at the end of the pass, not adopted:** `commit(_:cancellation:progress:)`,
  `remove(_:below:cancellation:)`, `createDirectory(at:exclusive:cancellation:)`, `FileSystemCapabilities.removeOnly`,
  `copy(…cancellation:progress:)`. Their defaults apply.
- **Network, still not tested with the real thing:** NetFS mount and eject, the Keychain itself, a revocation
  check that is really slow, the SFTP window on a slow line (N039).
- **Network test limits are wide now** (120 s where the fault would be 600 s or for ever). They no longer say how
  fast a cancel takes hold, only that it does.
- **`seeksWhileReading`** can still open a second login if the server's answer to a broken transfer takes more
  than 10 s (`abortTransfer`'s limit); not seen in any run here.
- **Archives:** no tests for A089, A094, the server branch of typed paths, real power loss; the descriptor-based
  unpack covers local disks only; X008 not re-run under the thread sanitizer; the memory test asserts a loose
  bound (under 700 bytes per member; 396 measured alone); `Tests/Fuzz` and `Tests/Stress` not rebuilt.
- **X007** (SIGPIPE): not reproduced, no change.
