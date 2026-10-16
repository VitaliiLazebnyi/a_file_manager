# Quality gates: where the work stands and how to continue

State saved on 2026-10-16 (branch `quality-gates`, pushed). The plan, decisions and gotchas are in
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
- Running: **w100-fileops-tools** (still), **w102-shell**, **w102-sweep** (sections in `wave-100.md`).
- Owner questions open: `NetStream.swift:242/444` impossible optionals (documented `!` as in decision 3?); the
  `ArchiveFileSystem:100` race arm; the two TCC prompts on the VM desktop (microphone: from Viewer media tests, being
  fixed; removable volumes: every test that mounts a disk image asks; recommended: Allow, keep the real-image tests).

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
