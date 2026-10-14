# Review 2 — general

Every item the reviewers, verifiers, stress runs and fuzzers reported for this area. `verdict` items are independent
rulings on a finding and sit next to it by file. Status is filled in by the fix round.

## Findings and verdicts

### G001 [finding, high] Format.kilobytes traps for any value above Int64.max - 512, reachable from a ZIP64 entry or SFTP server size

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** Sources/AFMContracts/Format.swift:29
- **Basis:** reproduced
- **Detail:** Format.kilobytes computes (value + 512) / 1024. Trigger: a ZIP64 entry declaring an uncompressed size of
  0xFFFF...FF, or an SFTP server reporting such a size. OpenArchive.swift:287 and SFTPChannel.swift:52 clamp it to
  Int64.max; two entries of 2^62 also saturate the total to Int64.max. The status line then calls
  Format.kilobytes(totals.totalBytes) at PanelViewController.swift:512. Trap reproduced (exit 133, t7 format); model
  returns Int64.max for two 2^62 items; chain verified link by link, not run end to end in the app. Also affected:
  DirectoryList.swift:117, SpaceCalculator.swift:116/121.
- **Proposed fix:** value / 1024 + (value % 1024 >= 512 ? 1 : 0)
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### G002 [finding, low] descript.ion comments misread or lost after an edit

**Outcome:** fixed (first pass, F077/F078) — see `status/fileops-p2.md`

- **Where:** Descript.swift:55-57; Descript.swift:71-76
- **Basis:** reproduced
- **Detail:** Byte-order-mark collision (55-57) and Character-based parsing (71-76); six reproducers in repro/misc/.
- **Source:** reports/30-fuzz-parsers-under-sanitizers.md
- **Status:** open

### G003 [finding, low] Format.speed and Format.duration convert a Double to an integer and trap on non-finite or huge values

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** Sources/AFMContracts/Format.swift:47; Sources/AFMContracts/Format.swift:52
- **Basis:** inferred
- **Detail:** e.g. remaining time for a near-Int64.max bytesTotal at under 1 B/s. Related to finding 1, low, plausible.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### G004 [finding, low] Format uses one static NumberFormatter from pool threads and the main thread at once (not thread-safe); cached DateFormatter ignores locale/time-zone change

**Outcome:** fixed — see `status/kernel-p2.md`

- **Where:** Sources/AFMContracts/Format.swift:6-12; Format.swift:24
- **Basis:** inferred (plausible)
- **Detail:** ContentColumn.value runs on background threads, several at once (Size on Disk column at
  PropertyDetails.swift:37), as do DirectoryList and NameList. NumberFormatter is on Apple's not-thread-safe list. No
  race detector run. Also: the cached DateFormatter never follows a locale or time-zone change. Report severity label
  LOW-MEDIUM.
- **Proposed fix:** Format integers by hand or use a per-thread formatter.
- **Source:** reports/19-review-kernel-concurrency-core.md
- **Status:** open

### G005 [finding, info] The UI-never-freezes requirement is not met (main thread saturates under watcher flood, stalls 0.3-1.3 s on million-item operations, a dead share can stop folder loading); stated as the report's overall conclusion

**Outcome:** duplicate of S009 — see `status/shell.md`

- **Basis:** measured
- **Detail:** Overall conclusion of the report; details in findings 1-13.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

## Checked and found sound

### G006 [sound, info] Flooding is throttled

- **Basis:** read
- **Detail:** Find Files batches, duplicate status, sync progress, viewer search progress and rename job progress are
  all time-throttled (10-20 Hz), and stale generations are dropped.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### G007 [sound, info] No blocking file or provider calls on main in the five plugins

- **Basis:** read
- **Detail:** No FileManager, stat or provider item/list/volume call was found on main in these five plugins. The only
  ones on main are text-only (displayPath, location(from:), capabilities(for:)).
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### G008 [sound, info] Other background -> main guards sound: FindFiles (search === search), Sync (running === comparison), Compare, MultiRename, directory tree (generation, showCounter), Viewer (reviewer)

- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### G009 [sound, info] interrupt() implementers (FTP, SFTP, archive member readers, ZIP writer, viewer pooled readers) are safe at any time, repeatedly, after close and non-blocking, apart from finding 4; forwarders pass the flag

- **Basis:** read (reviewer)
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### G010 [sound, info] All condition waits are predicate loops with broadcast (PauseGate, placesCondition, Walk, JobStack, FTPSession, NetStream, Pending, CommentStore); all semaphores start at 0 and Pool.slots is fully restored before release; no main-thread provider I/O in AFMShell or listed plugins; ProgressSheet.ask never reached from main

- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### G011 [sound, info] FindFiles+Viewer: no crash, hang, deadlock, wrong result or thread leak at full scale

- **Basis:** measured
- **Detail:**
- **Source:** reports/24-findfiles-viewer-stress.md
- **Status:** open

### G012 [sound, info] Scenarios 4-7 results relayed from forks (not re-verified): FileJob invariants held, archives reads correct, FindFiles complete, viewer first rows 11-24 ms

- **Basis:** read
- **Detail:** FileJob: no file lost, no partial file, no .afm-*.tmp, progress monotonic, cancelled jobs ended within
  milliseconds; deferred writes 581 good/32 failed commits with no source removed without commit. Archives: 804,155 and
  742,286 reads matched; archive passed unzip -tq, zipinfo and the app's reader after each of 56 commits; cancelled
  reads median 0.1 ms (max 120 ms). FindFiles cancels median 20 ms, max 549 ms. Viewer index 0.15-3.4 s, no crash in 12
  truncate/remove rounds.
- **Source:** reports/25-run-stress-and-sanitizer-checks.md
- **Status:** open

### G013 [sound, info] No system, popen, posix_spawn, NSAppleScript, NSUserScriptTask or XPC, and no URL-scheme, document, Services or Apple-event handlers (Info.plist, Shell.swift, main.swift checked; argv not read)

- **Where:** AFMShell/App/Shell.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### G014 [sound, info] Supply chain: Package.swift has no dependencies; unsafeFlags only on test targets pointing at a fixed root-owned path; the only try! is a constant regex

- **Where:** Package.swift; Plugins/Network/FTPListParser.swift:150
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### G015 [sound, info] Process-execution sites: CommandRunner ($SHELL -l -c, names quoted at ParameterExpansion.swift:282-287, ./ guard); CommandLine -l -c (output capped 8 MB, SIGTERM/SIGKILL on cancel); /usr/bin/lpr with absolute paths; osascript with fixed script and argv paths; bsdtar -cf - --format pax @path (never extracts); bzip2 -dc/-c; ssh with forwarding disabled and askpass FIFOs in a 0700 folder; NSWorkspace.open of unpacked member mode 0644 with quarantine copied; viewer open http/https/mailto only; dlopen of fixed libicucore path with matching signatures and bounded buffers

- **Where:** Plugins/Configuration/CommandRunner.swift:244-255; Plugins/SystemTools/CommandLine.swift:153;
  Plugins/SystemTools/SystemToolsPlugin.swift:516; Plugins/FileProperties/FilePropertiesPlugin.swift:98-103;
  Plugins/Archives/OpenArchive.swift:270; Plugins/Archives/Codecs.swift:508; Plugins/Archives/Codecs.swift:588;
  Plugins/Network/SFTPSession.swift:102; Plugins/Network/SFTPChannel.swift:273-280;
  Plugins/Archives/ArchiveCommands.swift:163; Plugins/Viewer/UI/ViewerPane.swift:626;
  Plugins/Viewer/UI/ViewerPane+Actions.swift:495-509; AFMKernel/Panels/Sorting.swift:642-644;
  AFMKernel/Panels/Sorting.swift:521-531; AFMKernel/Panels/Sorting.swift:564
- **Basis:** read
- **Detail:** The shell/LaunchServices rows are by design and bounded by findings 3, 4, 7, 8, 13, 15.
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### G016 [sound, info] Capped whole-file reads: viewer non-local sources 1 GiB; checksum files 64 MiB; .crc 64 KiB; tar pax records 16 MiB; symlink target 64 KiB; descript.ion sizeLimit; tab files/selection readLimit; SFTP packet 64 MiB; command output 8 MiB

- **Where:** Plugins/Viewer/UI/ViewerPane.swift:505; Plugins/Viewer/UI/ViewerPane.swift:535-538;
  Plugins/FileTools/ToolRun.swift:150; Plugins/FileTools/SplitCombine.swift:233; Plugins/Archives/Tar.swift:229-231;
  Plugins/Archives/Unpacker.swift:364; Plugins/FileProperties/Descript.swift:219-245;
  Plugins/FolderTabs/FolderTabsPlugin.swift:404-408; Plugins/Selection/SelectionPlugin.swift:457;
  Plugins/Network/SFTPChannel.swift:367; Plugins/SystemTools/CommandLine.swift:117
- **Basis:** read
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

## Not covered / left behind

### G017 [gap, info] Nothing was profiled in the running app

- **Basis:** read
- **Detail:** Apart from the one micro-benchmark, all durations are estimates.
- **Source:** reports/01-audit-tool-window-plugins.md
- **Status:** open

### G018 [gap, info] Not verified: real stalled network mounts, iCloud dataless folders, and volumes without bulk reads or RENAME_EXCL (exFAT, SMB)

- **Basis:** read
- **Detail:** An SMB share is mounted on the machine; it was not touched.
- **Source:** reports/02-review-local-file-system-plugins.md
- **Status:** open

### G019 [gap, info] Not covered: panel redraw cost after onChange(.selection/.contents) and the cost of tabs.onChange (AFMShell)

- **Basis:** read
- **Detail:**
- **Source:** reports/04-audit-navigation-config-plugins.md
- **Status:** open

### G020 [gap, info] Not covered: bodies of FileJob, Packer, Unpacker, ZipFormat, Tar, Codecs, Transcoding, Hashes, SplitCombine, SFTPChannel and NetStream beyond threading entry points

- **Basis:** read
- **Detail:** They run on job threads.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### G021 [gap, info] No live test against a stalled mount or a hung pasteboard owner

- **Basis:** read
- **Detail:** F1-F3, F6 and F7 durations are from reading the code. Cross-process pasteboard costs may exceed the
  in-process figures measured.
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### G022 [gap, info] Other plugins' main-thread calls to fileSystems.location(from:) (F3 root cause) need checking by their reviewers

- **Basis:** read
- **Detail:**
- **Source:** reports/05-audit-provider-operation-plugins.md
- **Status:** open

### G023 [gap, info] No run of the real app; B1-B6 durations on a stalled mount are inferred, not reproduced

- **Basis:** inferred
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G024 [gap, info] The lazy-pasteboard hang was not reproduced

- **Basis:**
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G025 [gap, info] Low memory and disk full were not exercised

- **Basis:**
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G026 [gap, info] Bodies of job-thread code (FileJob, packers, codecs, network streams) beyond their hops to main were not covered

- **Basis:**
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G027 [gap, info] Not covered: FormDialog and pick-list rendering with very large inputs; PagePrintView; SearchForm; hex and media viewers; the hotlist editor

- **Basis:**
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G028 [gap, info] Other main-thread callers of fileSystems.location(from:) (Navigation cd, command line) share B4's root cause but were not traced

- **Basis:**
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G029 [gap, info] P3, P4, P7, P9 and the fork-reported parts of S7 and S9 were not re-read by the auditor; nothing was profiled in the running app; measurements are swiftc -O micro-benchmarks

- **Basis:**
- **Detail:**
- **Source:** reports/08-audit-main-thread-work-across-codebase.md
- **Status:** open

### G030 [gap, info] Not verified: FSEvents teardown semantics (finding 17) and the exact Network write path into the ask sites of finding 1

- **Basis:**
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### G031 [gap, info] Reviewer gaps: parts of ZipFormat.swift, ArchiveLocation.swift, Hashes.swift, Transcoding.swift and ViewerEncoding.swift only grepped. Two reviewers failed to launch so remaining plugins got a targeted grep-and-read

- **Basis:**
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### G032 [gap, info] No ThreadSanitizer or stress run; the races in findings 3, 4, 5 and 11 are proven by reading, not reproduced; nothing built or run

- **Basis:**
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open

### G033 [gap, info] No dynamic testing of the app itself; only two standalone experiments (webtest.swift, tmpdir.swift); several modules only sampled

- **Basis:**
- **Detail:**
- **Source:** reports/10-audit-security-across-codebase.md
- **Status:** open

### G034 [gap, info] Not reviewed: behaviour on case-sensitive, FAT/exFAT, SMB or spinning volumes and a real full disk; everything ran on local APFS

- **Basis:**
- **Detail:**
- **Source:** reports/11-review-file-operations-second-round.md
- **Status:** open

### G035 [gap, info] Not reviewed: Network and Archives providers' item(at:), interrupt and move(replacing:) behaviour (L13 and M6 depend on it); kernel and other plugins read only where called from scope

- **Basis:**
- **Detail:**
- **Source:** reports/12-review-find-select-rename-again.md
- **Status:** open

### G036 [gap, info] Verifier run side effects

- **Basis:** read
- **Detail:** Regex timing test for claim 16 used about six minutes of CPU; a ksh -l / dash -l probe sourced the user's
  ~/.profile (read only, printed a syntax error); marker files left in c13/ and c16/root/ under the scratch folder. App
  never launched; tests ran on copies of the code.
- **Source:** reports/28-verify-security-findings.md
- **Status:** open

### G037 [gap, info] Not read in full: DirectorySync (SyncPlan, SyncWindowController), CompareContent (TextDiff, window controller), MultiRename (window controller, RenameRun bodies), most of Configuration, Selection, Navigation, FolderTabs and SystemTools UI, plus FileJob.swift 960-1270 and 1490-1640; grepped and read around hits only

- **Where:** Plugins/FileOperations/FileJob.swift
- **Basis:** read
- **Detail:**
- **Source:** reports/09-audit-threading-model-across-codebase.md
- **Status:** open
