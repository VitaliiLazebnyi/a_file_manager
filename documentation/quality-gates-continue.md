# Quality gates: where the work stands and how to continue

State saved on 2026-10-21 (branch `quality-gates`, pushed). The plan, decisions and gotchas are in
`documentation/quality-gates-handover.md`; the briefs every agent follows are in `documentation/agent-briefs/`
(`coverage-brief.md` for the coverage work).

## Prompt to continue

Paste this into a new Claude Code session in `/Users/cm0k/Claude/Projects/TotalCommander` (inside the VM "AFM macOS
27"):

> Read `documentation/quality-gates-continue.md`, `documentation/quality-gates-handover.md` and the briefs in
> `documentation/agent-briefs/`, then continue the quality-gates work where the "State" section of
> `quality-gates-continue.md` leaves it, with "Next steps" in order. Check `Scripts/resource-guard.sh status` first. Use
> subagents in worktrees for module work (at most as many as the machine bears; each builds with `-j 3`); merge, verify
> (clean build, `swift test --parallel --enable-code-coverage`, `python3 Scripts/coverage-gate.py`,
> `Scripts/check.sh leaks`, the gates of the files touched), commit and push after each finished piece. The bar is code
> quality without compromise: no weakened gates, no ignores.

## State

### Running (started 2026-10-16 05:00)

Wave 100 (`documentation/agent-briefs/wave-100.md`): six agents in worktrees, branches `w100-stability`,
`w100-config-sync`, `w100-fileops-tools`, `w100-shell`, `w100-network`, `w100-viewer-mac-small`, base `05c77ed`, the
deinit rule change `5b13f75` cherry-picked. If the session ended before they were merged: look at each branch's commits,
merge what is finished, and restart the rest with the same section of `wave-100.md`.

- Merged: **w100-config-sync** (`d90172f`): Configuration 25 / 15 / 27 and DirectorySync 13 / 5 / 10 uncovered lines /
  functions / regions left: the `.system` effects and `present` defaults (UI tests), list row clicks (UI tests),
  `ConfigurationPlugin.storedKeys(of:)` for `UserDefaultsSettings` (passed to w100-shell), `ChildProcess` 5 regions
  (spawn attribute init failing, EINTR retry, a reap race), one race branch each in `CommandRunner:562` and
  `SyncSession:576`.
- Merged: **w100-viewer-mac-small** (`2ed15d9`): AFMKernel 100%; Viewer, MacIntegration, Archives, Places,
  VirtualFolders, MultiRename, FileProperties, LocalFileSystem 145 / 45 / 70 left, mostly system adapters (UI tests);
  races in `ViewerPane.stripHTML` and `ArchiveFileSystem:100`; `Codecs:218` (`compression_stream_init` failing); the
  `Unpacker` path-traversal guard (~520, owner's call, kept); `MultiRenameWindowController:785` `?? []`.
- Merged: **w100-stability** (`bd653d1`): Find Files 1 / 1 / 2 left (open-panel adapter, a Spotlight stop race,
  `FileSearch.claim` firmlink arm); set-aside tests back; flaky tests fixed. Not found by it: "Socket is not connected"
  and early SIGSEGV.
- Found 07:39: **FSEvents closes fd 0** when `FSEventStreamCreate` fails (EXC_GUARD crash report
  `swiftpm-testing-helper-2026-10-16-073947.ips`, from `DirectoryWatcher.startedStream`); the likely cause of the socket
  error, the early crashes and EBADF / ECONNREFUSED failures in full runs. Agent **w101-fsevents** on it.
- To do after the wave (from the reports): `Deflater` ignores `deflateInit2_` / `Z_STREAM_ERROR`; one-pass unpack of a
  compressed TAR does not read to the checksum; many tests still wait 60 s instead of `Wait.ceiling`;
  `PluginCommandTests` builds `ViewerPlugin()` with windows shown; `TextPattern("\\x81")` throws under TSan; TSan run on
  the `ProcessStream` lock, the Archives quit port and the Viewer key monitor.
- Merged: **w100-network** (`64a286c`), **w100-shell** (`ff22b56`, AFMShell 203 / 29 / 80 left), **w101-archives**
  (`3224e64`, Archives 100% but `openInApplication`), **w101-fsevents** (`2750aa9`, root cause in
  `documentation/FSEvents-descriptor-zero.md`), the Compare window part of **w100-fileops-tools** (`9bd4b6a`); the
  program raises its open-file limit at start (`99566b9`). Full suite at `2750aa9`: 349 shell, 3,328 plugin, 336 kernel,
  all passed.
- Merged: **w102-sweep** (`9aef05a`): waits at `Wait.ceiling`, flaky tests fixed, race regions covered through seams;
  left: `MultiRenameWindowController:785` `?? []` (impossible optional, owner), `:50` sheet adapter (UI tests),
  `NetStream:317/326` framer callbacks never called, `FTPConnection:580` (no seam into `NWConnection`).
- Merged: **w100-fileops-tools** (`52a2623`): FileOperations 1 / 1 / 1, SystemTools 26 / 11 / 14, CompareContent 11 / 6
  / 8 left, all system adapters; printing over 4,096 files no longer ends the program.
- **Whole suite with coverage at `52a2623`:** all passed (355 shell, 3,426 plugin, 336 kernel); lines 99.55% (428 left),
  functions 99.24% (115), regions 99.49% (210); 58 files below 100%: system adapters (UI tests), the Panel regions
  w102-shell is on, and regions the non-atomic counters lose or that tests skipping on a failed `hdiutil attach` miss.
- Atomic-counter run of `52a2623` (`documentation/agent-briefs/w103/`): the same totals; the gaps outside the adapters
  differ between runs because some tests reach them only now and then (wave 103).
- Merged: **w102-shell** (`b089625`): AFMShell 34 regions left (adapters, key-window checks). Found: test processes
  ending early with status 0 (a stopped main run loop) or SIGSEGV, unreported by `swift test`.
- `45dea79`: `StandardPlugins.make(launchesApplications: false)` passes it on (no real modal loop or tool window in the
  program tests). `a58cca3`: `Scripts/test-run-check.py` makes the test gate fail when a bundle did not run all its
  `@Test` functions.
- Merged: **w103-determinism** (`93f1338`): rare arms moved where they have their own counters, impossible arms gone,
  timing replaced by deterministic tests; finding: the plain counters both lose counts (ran, read 0) and wrap below zero
  (never ran, read covered), so only atomic counters measure 100% (owner question). Left: timing-only arms that need
  seams (`FTPSession:229/506`, `TextRows:615`, `ViewerPane:660`, `FTPConnection:773`, `LocalSupport:66`), and the
  adapters (list in its report, `documentation/agent-briefs/w103/`).
- Merged: **w104-crashes** (`f8fa15e`): the PluginTests SIGSEGV (locale notifications posted from 16 threads to the
  default center reached other tests' date pickers off the main thread); unowned references fixed; window watches name
  their windows; a wrong old-style ZIP password that decrypts to valid data is asked for again. Two full runs: every
  test ran and passed (337 / 3,438 / 388). Open: a main-thread stall of ~300 s about once in ten runs.
- Merged: **w105-stall** (`a42de8d`): the stall was a test turning the main run loop itself; no synchronous spin loops
  left in the tests; the timing arms tested deterministically. `Scripts/check.sh test` at `a42de8d`: every test ran and
  passed (388 / 3,444 / 337); lines 99.67%, functions 99.28%, regions 99.61%; 43 files below 100%, nearly all system
  adapters. UI test baseline: 3 passed, the accessibility audit failed (file-list cells without a role, the type-81
  element without a description).
- Merged: **w106-uitests** (`c91244e`): the accessibility audit passes; Choose Command no longer runs a command while
  the filter is typed; 44 UI tests. `Scripts/check.sh test` with the UI counts at `c91244e`: every test ran and passed
  (389 / 3,447 / 337); lines 99.92%, functions 99.88%, regions 99.91%; 20 files below 100%
  (`documentation/agent-briefs/w103/gate-c91244e.txt`). The local-network prompt came from the print panel looking for
  printers. Accessibility gaps outside the audit: the rename box, the Brief and Thumbnail views.
- Merged: **w107-last** (`2cebda6`): 8 files below 100% left (lines 99.98%, functions 99.96%, regions 99.97%, 54 UI
  tests): `AppleScript.run` (Finder automation prompt), `NetStream`, `MultiRenameWindowController:785` (owner),
  `Place.swift` (counter wrap-around: atomic counters), `FileGridView+Drop` (XCUITest cannot drag there; CGEvents need
  the Accessibility permission), `SystemDesktop:45`, `SystemPreviewPanel:20`, `SystemDialogs:31` (millisecond windows,
  real cases kept). `UITests/run.sh` attaches a disk image of its own (`AFM_VOLUME`).
- Gate at `2cebda6`: the UI tests passed; the unit tests stopped the gate on the flaky
  `AppShellLifetimeTests.aUsedProgramGoesAsWell` (parts not freed in 311 s; about one full run in three).
- Merged: **w108-lifetime** (`9e6fb67`): the lifetime tests' parts sat in an autorelease page nothing empties (the run
  loop releases a block it ran outside any pool; a control dying there autoreleases every live window); a test main-loop
  pool (`Tests/TestSupport/LifetimeMainLoopPools.swift`) empties it; the command-line edge test cancels the combo box's
  pending popup, whose event loop ended ShellTests with status 0. `a8095e2`: plugins use `NSApplication.shared` (NSApp
  traps before the application object exists); `LastTabsTests` without the cache.
- **Gate at `a8095e2`** (`UITests/run.sh`, then `Scripts/check.sh test`): every test ran and passed (391 / 3,447 / 337,
  54 UI tests); lines 99.98%, functions 99.96%, regions 99.97%; 9 files below 100%
  (`documentation/agent-briefs/w103/gate-a8095e2.txt`): the owner's questions and counts that come and go with the
  non-atomic counters (`ChecksumFiles`, `LocalFileSystem` this run; `Place` the run before).
- Merged: **w109-timing-arms** (`8678a90`): share and Quick Look take their window when the command starts, the Lister
  prints as a sheet of the window it was asked from; the three millisecond arms are tested. Gate: every test ran and
  passed (391 / 3,452 / 337, 54 UI tests); lines 99.98%, functions 99.96%, regions 99.98%; 5 files below 100%:
  `FileGridView+Drop`, `AppleScript`, `MultiRenameWindowController:785`, `NetStream`, and `ZipFormat:175–176` (lost
  counts of the non-atomic counters).
- **100% reached (2026-10-21):** `UITests/run.sh` (55 UI tests and the two desktop checks of AFM UI Mouse: the drag from
  the thumbnails, Finder Info), then `Scripts/check.sh test`: every test ran and passed (394 / 3,454 / 337); lines
  94,639 / 94,639, functions 15,244 / 15,244, regions 40,997 / 40,997. The owner's four decisions taken: atomic counters
  in the gate's coverage run, documented `!` in `NetStream` and the rename list, Finder automation for the program and
  Accessibility for the helper (both signed by `UITests/identity.sh`). Found on the way: Finder on macOS 27 resolves no
  file path it is handed (Finder Info now walks Finder's own references); a grid in no window trapped on its visible
  rows; XCUITest's drags do not arrive in the VM (see the hand-over, UI tests). A posted key event that only carries a
  modifier's flag leaves that modifier held for the whole system (a unit test of drop operations then saw Cmd held): the
  helper presses and releases modifier keys itself.
- Next: lint step 6 (the touched files are clean, the rest of the repository is not), the mutation runs, gates repo-wide
  at zero, benchmarks re-recorded, CI and pre-commit.
- **Mutation, `Sources/Plugins/Navigation` (2026-10-23, branch of the Navigation agent): gate passed.** 31 mutants (17
  relational, 6 logical, 5 ternary, 3 removed calls), all killed, none equivalent. First run: 30 killed, 1 survived
  (`ClipboardText.path` kept an empty answer: no test put text on the clipboard after its change count moved). Second
  run: the removed `toolbar.setSymbol` of the standard places survived; the first run had counted it killed only because
  `PanelReadAheadProgramTests.theFolderUnderTheCursorIsReadAheadAfterAMoment` (ShellTests) failed by timing in that run.
  Two tests in `CoverageNavigation` kill both; every other kill was checked to come from a Navigation test. Time: 718 s
  and 700 s for the first runs (23 s per mutant), 366 s for the passing run (12 s per mutant, all killed by the selected
  PluginTests), plus about 10 minutes for the map and builds each run. Found on the way: `mutation.sh` nested a run's
  logs inside the last run's (`report/logs/logs`), fixed; tests that failed when run alone for the map, differently each
  run (`StallFTPLinks/theResolverPutsItsLinksBackWhileACommandHoldsTheConnection`,
  `CoverageFindSpotlight/aQuestionStartedTwiceAnswersOnce`,
  `AppFileWorkTests/changesMadeByOtherProgramsAppearByThemselves`,
  `PanelRememberedVisitTests/aFreshListingThatComesFirstIsShownInstead`): flaky under load, they make the map incomplete
  and can kill a mutant that no real test notices, so a kill by an unrelated test needs a look. Full suite after it
  (`swift test --parallel --enable-code-coverage -j 3`): 394 / 3,456 / 337, all passed; Navigation 100% lines,
  functions, regions.
- **Waiting for the owner** (before 2026-10-21; decided since, kept for the record): atomic counters for the coverage
  run; a documented `!` for `NetStream:242/444`, `MultiRenameWindowController:785`; `AppleScript.run` (Finder automation
  prompt); the drop on the thumbnail grid (Accessibility for the UI test runner); `SystemDesktop:45`,
  `SystemPreviewPanel:20`, `SystemDialogs:31` (millisecond windows: accept, or restructure). Then: lint step 6 and the
  mutation runs.
- Coverage measurement (fileops-tools finding): Swift Testing runs tests on several threads in one process and the
  profile counters are not atomic, so regions counted as expressions of other counters (a `catch` arm, a `guard`'s
  `else`) come out 0 now and then. Built with `-Xswiftc -Xllvm -Xswiftc -instrprof-atomic-counter-update-all` the counts
  are stable. Owner question whether the gate's coverage run takes that flag.
- Owner questions open: atomic counters for the coverage run (above); `NetStream.swift:242/444` impossible optionals
  (documented `!` as in decision 3?); the `ArchiveFileSystem:100` race arm; the two TCC prompts on the VM desktop
  (microphone: from Viewer media tests, being fixed; removable volumes: every test that mounts a disk image asks;
  recommended: Allow, keep the real-image tests).

### Done and pushed

- Swift 6 migration, thread-safety audits, leak fixes, the gates (lint config, mutation, UI tests, architecture, API,
  benchmarks, memory, fuzz and stress smoke tests, SBOM, CodeQL): see the hand-over.
- Kernel and contracts wave (core-tests, core-panels, core-api) merged earlier.
- **Coverage gate counts regions** (Swift's branch coverage: each arm of `if`/`guard`/`switch`/`catch`, each side of
  `&&`/`||`/`??`), besides lines and functions; `python3 Scripts/coverage-gate.py <folders>` reports on some folders.
- **Coverage wave (2026-10-15/16), eight agents, all merged:** shell-panel and shell-app (the stopped shell wave,
  finished: split, lint-clean, documented), cov-viewer, cov-places-config, cov-archives-network (with its helpers
  cov-archives-fs, cov-archives-formats, cov-network, cov-network-2), cov-rename-find-sync, cov-core-plugins,
  cov-small-plugins. Stopped on request after their current step; each report's "what is left" is below.
  - Full suite: 3,579 tests (2,934 plugin, 336 kernel, 309 shell). Last run (`fe7b47a` plus the click changes): all
    three bundles ran to the end, one failure (the exit-test channel, see Next steps 1); one run before that lost the
    PluginTests process part-way (Next steps 2).
  - Coverage (all bundles merged, no UI tests): lines 89.3% → 96.1%, functions 85.4% → 95.0%, regions 83.3% → 94.6%.
  - About 30 real bugs fixed with tests (see the merge commits and the agents' commits), among them: a copy to a full
    disk retried for ever; a rename waited behind a long archive write; `Unpacker.refuseLinks` looked at the wrong
    folder for targets with `..`; the SFTP start raced a disconnect (crashed the test process); dropping on the Full
    view could end the program; settings lists (`selection.types`, `multirename.saved`, `findFiles.searches`,
    `directorySync.sets`) emptied on one bad entry; the pager dropped a place looked up while the index was finishing.
- **No test reaches the real desktop** (rule in `coverage-brief.md`): opening, Finder, sounds, modal panels and alerts
  go through seams; the one-line system adapters are left to the UI tests.
- **Resource guard** (`Scripts/resource-guard.sh`, launchd agent `com.afm.resource-guard`, installed in the VM): warns
  on memory pressure, any swap, a 5-minute load over 4× the cores, disk under 15 GiB; at critical (swap ≥ 1 GiB, free
  memory < 8%, disk < 5 GiB) it ends the largest development process. Log `~/Library/Logs/afm-resource-guard.log`.
- **Set-aside tests** (they misbehave, kept for fixing): branch `wip/set-aside-tests`, `documentation/set-aside-tests/`
  (Find Files window/form/plugin/Spotlight tests: one over-releases on the main queue's pool; the shell's
  `InteractionProgressWindowTests`: the process ends early with exit 0).

### Uncovered after the wave (files / lines / functions / regions, full suite, no UI tests)

| Module                                                                                    | Files | Lines | Functions | Regions |
| ----------------------------------------------------------------------------------------- | ----- | ----- | --------- | ------- |
| Plugins/Configuration                                                                     | 13    | 737   | 212       | 499     |
| Plugins/DirectorySync                                                                     | 5     | 501   | 108       | 300     |
| Plugins/FileOperations                                                                    | 11    | 215   | 65        | 267     |
| AFMShell/Window                                                                           | 19    | 501   | 70        | 242     |
| Plugins/FindFiles                                                                         | 5     | 492   | 89        | 213     |
| Plugins/SystemTools                                                                       | 6     | 393   | 61        | 186     |
| Plugins/Network                                                                           | 8     | 140   | 22        | 138     |
| Plugins/CompareContent                                                                    | 6     | 131   | 17        | 117     |
| AFMShell/Panel                                                                            | 26    | 161   | 22        | 72      |
| AFMShell/Interaction                                                                      | 8     | 150   | 23        | 52      |
| Plugins/Viewer                                                                            | 6     | 56    | 13        | 37      |
| Plugins/MacIntegration                                                                    | 4     | 70    | 18        | 31      |
| AFMShell/App                                                                              | 6     | 58    | 18        | 19      |
| Archives, Places, VirtualFolders, MultiRename, AFMKernel, FileProperties, LocalFileSystem | 15    | 36    | 11        | 20      |

Covered completely: AFMContracts, StandardPlugins, FileTools, Selection, FolderTabs, Clipboard, Navigation, ViewOptions.
A good part of what is left in the shell, Viewer, MacIntegration, Places and Archives is the one-line system adapters
that only the UI tests reach (their coverage is merged by the gate once `UITests/run.sh` has run).

## Decisions for the owner

1. **`required_deinit` against function coverage**: decided 2026-10-16, the rule goes for NSObject subclasses
   (`Scripts/required-deinit.py`, see the hand-over's lint section).
2. **lizard misreads Swift**: a `set` or `init` token outside a declaration (`private(set) var`, `super.init(frame:)`,
   `.init(rawValue:)`) makes it treat the rest of the class as one function. False findings in the shell and plugins;
   the gate needs a fix (pre-processing or another tool), not the code.
3. **Impossible optionals of Foundation**: decided 2026-10-16, a documented `!` is allowed in exactly those places.
4. Exit tests: a process ended by a trap writes no coverage; `Tests/TestSupport/CoverageCoreTrap` (test-only) turns a
   trap into `exit(1)` so the counts are written. Use it, or return nil from `init?(coder:)` as the agents did.

## Next steps, in order

1. **Flaky under load:** `LocalJobs.aFinishedJobIsLetGo` (FileJobTests.swift:160) failed in the full run after the
   cov-core-plugins fix; `CoverageLocalWatcherMore.aWatchedFolderThatIsRenamedIsReportedAsChanged`,
   `ApplicationTests.aSlowFolderThatCannotBeReadIsLeftAgain` and
   `Review2ConfigARunner.commandsThatCallEachOtherAcrossAWaitAreStopped` failed once each;
   `CoverageLocalWatcher.theFiguresArePrintedAtTheEndWhenAskedFor` failed once with Swift Testing's own "Socket is not
   connected" (the exit test's channel to its child, under load). Make them deterministic.
2. **Tests that end the process with exit 0** (the run looks passed while later tests never ran):
   `NSButton.performClick`, `NSWindow.performClose`, `NSApp.stopModal` without a modal loop, `NSApp.nextEvent`, ending
   an `NSOpenPanel` sheet. The plugin tests send button actions directly now (`sendAction`); the shell tests still call
   `performClick` in `InteractionQuitProgressTests`, `PanelPathBarTests`, `PanelBarsTests`, `WindowDriveBarTests`,
   `WindowButtonBarTests`, `PanelQuickFilterProgramTests` (they passed so far). On 2026-10-16 one full run's PluginTests
   process ended this way after about 630 tests (no crash report; running then: `aButtonBarOfOneLineLoads`,
   `tabsWithoutTitlesLoad`, `aTransferOnACutConnectionFails`). Then bring back the set-aside tests. Always compare the
   test counts of a run with the previous one (2,934 plugin, 336 kernel, 309 shell).
3. **Coverage, per the agents' reports** (seams first, then tests, as in `coverage-brief.md`):
   - Configuration (not started): beep seam for `OptionsWindow` (8) and `CommandBrowser`; `CommandBrowser.pick` and the
     plugin's open/save panels behind seams; `ChildProcess` shell lookup injectable, `/bin/sh` fallback removed.
   - DirectorySync (not started): `ClosureMenuItem.init(coder:)` returns nil; open-panel seam for the folder buttons; a
     closed sync window lets go of its list.
   - FileOperations and SystemTools (not started): SystemTools' open, print, quit, minimise through a desktop seam.
   - FindFiles: the set-aside window/form/plugin/Spotlight tests (find the over-release with
     `SWIFT_BACKTRACE=enable=yes`, probably a form test that puts `form.tabView` into a throwaway `NSWindow`);
     `FileSearch.swift` 357/638/703 race regions.
   - AFMShell/Window: `ButtonBarView+Dragging`, `CommandLineView`, `DriveBarView`, `MainWindowController`, `ToolWindow`,
     `BarCommandButton`, `FolderWatches`, `MissedChanges`, `PlacesStore`.
   - AFMShell/Panel: quick filter branches, `PanelReadingRun`, `PanelPieceStream` (sort changed while reading),
     `ReadAhead` (clock), long remembered lists, `PathBarView` text area, `tableScrolled`.
   - AFMShell/Interaction: `ProgressDisplay` (after the set-aside suite), `FormList.rowDoubleClicked`,
     `ProgressJobService` idle callback.
   - Network: SFTPSession/SFTPChannel (107 regions: end the endless loops in `open()`/`start()`, hold `lock` while the
     process starts, more `FakeSFTPServer` modes), FTPSession (injectable clock), NetStream (5).
   - CompareContent: `CompareLoader` (16/128 MB, cancel, read errors), `CompareSession`, `TextDocument`, `TextDiff`, the
     plugin; lint of `Tests/PluginTests/CoverageCompare*.swift`.
   - Viewer: `ViewerPane.swift` (~23 regions, listed in the cov-viewer report: rich-mode results, late folder/HTML
     results, `setMode` Quick Look arms); the pager's "index finished while looked up" branch needs a deterministic test
     (the index build needs the main thread, so holding it does not work).
   - MacIntegration: `MacIntegrationPlugin` 95/132, `QuickLook` `toggle([])`, `VolumeProbe.system` edges.
4. **UI tests** (`Scripts/check.sh uitest`, takes over the screen of the logged-in session; mute first): they cover the
   system adapters (Viewer `SystemDialogs`/`SystemLinks`, MacIntegration `SystemDesktop`/`SystemPreviewPanel`,
   `AppleScript.run`, the shell's alerts, quit reply, table clicks, `showVolumeList`, drags, Places' editor `run` and
   tree beep, Archives `openInApplication`); write `UITests/AFileManagerUITests/Panel*.swift` for the panel's; rerun the
   accessibility audit (the type-81 element: XCUITest's TouchBar type).
5. **Bugs reported, not fixed:** testing a `.tar.gz` stops before the gzip checksum (a damaged middle goes unnoticed);
   packing a file over an empty folder of the same name in an archive on a server replaces the folder; `ProcessStream`
   read after close raises; closing a `QLPreviewView` outside a window ends the process; panels and windows are never
   freed after `Shell` goes away in the program tests (probable window leak).
6. **Lint of the touched files** (the coverage agents left older findings in the plugin sources; their new test files
   are mostly clean, except CompareContent, FindFiles, some Archives formats tests), then the mutation runs (panel run,
   core-api hot files, the shell with the map), as in the hand-over.
7. Then: every gate repo-wide at zero, the full mutation run, re-record the benchmark limits on a quiet VM, switch the
   gates on in CI and in the pre-commit hook (`git config core.hooksPath .githooks`).

## Environment notes

- Work runs inside the Parallels VM "AFM macOS 27" (macOS 27, Xcode 27, Swift 6.4); it pushes to GitHub with
  `~/.ssh/afm_github`. Never reset the dev VM to a snapshot.
- `/private/tmp` is wiped when the VM restarts: keep nothing there that must survive (the agents' helper scripts in
  `/private/tmp/claude-501/sp/` will be gone; `Scripts/coverage-gate.py <folders>` and `xcrun llvm-cov show` do the
  same).
- The VM's alert volume is 0 and its output muted, so tests that still beep are not heard.
- Muter's source is cloned in `.build-tools/muter` (ignored by git); `Scripts/build-muter.sh` rebuilds and installs it.
- Agent worktrees under `.claude/worktrees/` are all merged and can be deleted (their branches are in `quality-gates`).
