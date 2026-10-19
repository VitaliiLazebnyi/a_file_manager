# Wave 100: assignments (2026-10-16)

Goal of the wave: **100% of lines and regions** (branch coverage) of every source file, plus the known issues of
`documentation/quality-gates-continue.md` ("Next steps" 1, 2 and 5) fixed. Functions count too, as far as the
`required_deinit` question allows (see below).

Every agent reads, whole and in this order: `documentation/agent-briefs/quality-brief.md`,
`documentation/agent-briefs/coverage-brief.md`, `documentation/quality-gates-continue.md`, the parts of
`documentation/quality-gates-handover.md` the briefs point to, then its section below. Base commit: `7642e5c` (branch
`quality-gates`) or a descendant. Temporary files go to `/private/tmp/claude-501/sp/<assignment>/`.

Shared rules of this wave:

- Six agents build at once: `swift build --build-tests -j 3`, tests with `--filter`, the whole suite only at the end and
  only while `Scripts/resource-guard.sh status` says `ok`.
- Change only your files (the source folders and test files of your section, new test files with your prefix). A helper
  you need in `Tests/TestSupport` goes into a **new** file whose name starts with your prefix. A change you need
  elsewhere: report it.
- Owner decisions still open (do not decide them yourself; leave the region or function and list it in the report with
  file:line and why no input reaches it): (1) the `deinit` functions of NSObject subclasses that SwiftLint's
  `required_deinit` demands; (3) the impossible optionals of Foundation (`VirtualLocation.url`, `ZipFormat` `DOSTime`).
  Decision (4): use `Tests/TestSupport/CoverageCoreTrap` for exit tests, or make the trap impossible.
- Never a test that ends its process with exit 0 or runs the event loop: no `performClick`, `performClose`,
  `NSApp.stopModal` without a modal loop, `NSApp.nextEvent`, `runModal`; send actions (`sendAction`) and close windows
  directly. After every full run compare the test counts per bundle with the ones before (2,934 plugin, 336 kernel, 309
  shell, plus the ones you added).
- Report: commits, coverage of your files before/after (lines, functions, regions), bugs fixed, code removed, what is
  left and why.

## w100-stability (prefix `Stability`)

Next steps 1 and 2 of the continue notes, plugin and kernel side, and Find Files.

- Make deterministic: `LocalJobs.aFinishedJobIsLetGo` (FileJobTests.swift:160),
  `CoverageLocalWatcherMore.aWatchedFolderThatIsRenamedIsReportedAsChanged`,
  `Review2ConfigARunner.commandsThatCallEachOtherAcrossAWaitAreStopped`,
  `CoverageLocalWatcher.theFiguresArePrintedAtTheEndWhenAskedFor` (the exit test's channel failed with "Socket is not
  connected" under load: find out why, fix the cause or restructure the test so it does not need the channel under
  load), and any other test you see fail under load (run the plugin and kernel bundles several times with `--parallel`
  while the machine is busy). Fix the cause in the code when the code is wrong.
- The PluginTests process that ended with exit 0 after about 630 tests on 2026-10-16 (running then:
  `aButtonBarOfOneLineLoads`, `tabsWithoutTitlesLoad`, `aTransferOnACutConnectionFails`): find the cause (search the
  plugin and kernel tests for the calls listed above and for anything else that can end the process) and fix it.
- Bring back the set-aside Find Files tests from branch `wip/set-aside-tests` (see its
  `documentation/set-aside-tests/`): find the over-release (`SWIFT_BACKTRACE=enable=yes`, Zombies / `MallocScribble`),
  fix it, make the tests pass in the full run.
- Coverage of `Sources/Plugins/FindFiles/**` to 100% lines and regions (`FileSearch.swift` race regions 357/638/703:
  make them deterministic through a seam, or simplify the code so the race arm does not exist).
- Files: `Sources/Plugins/FindFiles/**`, `Sources/AFMKernel/**` (only for the flaky causes), the tests named above,
  `Tests/PluginTests/FindFiles*`, `Tests/PluginTests/CoverageFind*`, `Tests/KernelTests/**`, new files `Stability*`.

## w100-config-sync (prefix `CovConfig`, `CovSync`)

Coverage of `Sources/Plugins/Configuration/**` and `Sources/Plugins/DirectorySync/**` to 100% (next step 3: the beep
seam for `OptionsWindow` and `CommandBrowser`; `CommandBrowser.pick` and the plugin's open/save panels behind seams;
`ChildProcess` shell lookup injectable, `/bin/sh` fallback removed; `ClosureMenuItem.init(coder:)` returns nil;
open-panel seam for the folder buttons; a closed sync window lets go of its list). Files: those folders, their tests
(`Tests/PluginTests/*Config*`, `*DirectorySync*`, `*Sync*` that test these plugins), new files with your prefixes.

## w100-fileops-tools (prefix `CovFileOps`, `CovSysTools`, `CovCompare`)

Coverage of `Sources/Plugins/FileOperations/**`, `Sources/Plugins/SystemTools/**`, `Sources/Plugins/CompareContent/**`
to 100% (SystemTools' open, print, quit, minimise through a desktop seam; `CompareLoader` 16/128 MB limits, cancel, read
errors; `CompareSession`, `TextDocument`, `TextDiff`, the plugin). Also the lint of
`Tests/PluginTests/CoverageCompare*.swift` (zero findings). Files: those folders and their tests, new files with your
prefixes. `FileJobTests.swift:160` belongs to w100-stability.

## w100-shell (prefix `Shell` + the module name, e.g. `PanelCov`, `WindowCov`, `InteractionCov`, `AppCov`)

Coverage of `Sources/AFMShell/**` to 100% (the lists of next step 3 for Window, Panel, Interaction, App). Also:

- replace `performClick` in `InteractionQuitProgressTests`, `PanelPathBarTests`, `PanelBarsTests`,
  `WindowDriveBarTests`, `WindowButtonBarTests`, `PanelQuickFilterProgramTests` (and any other shell test that runs the
  event loop or can end the process);
- bring back the set-aside `InteractionProgressWindowTests` (branch `wip/set-aside-tests`; the process ended early with
  exit 0): find the cause, fix it;
- flaky `ApplicationTests.aSlowFolderThatCannotBeReadIsLeftAgain`: deterministic;
- bug: panels and windows are never freed after `Shell` goes away in the program tests (probable window leak): find and
  fix, with a test that checks the windows go (weak references), and `Scripts/check.sh leaks` clean.
- Files: `Sources/AFMShell/**`, `Sources/AFileManager/**`, `Tests/ShellTests/**`, new files with your prefixes.

## w100-network (prefix `CovNet`)

Coverage of `Sources/Plugins/Network/**` to 100% (SFTPSession/SFTPChannel: end the endless loops in `open()`/`start()`,
hold `lock` while the process starts, more `FakeSFTPServer` modes; FTPSession injectable clock; NetStream). Bug: packing
a file over an empty folder of the same name in an archive on a server replaces the folder (find where: Network or
Archives' remote packing; fix with a test; if the fix is in Archives, coordinate by keeping it to the one function and
say so). Also `aTransferOnACutConnectionFails` was running when a PluginTests process ended: check that test for
anything that can end the process. Files: `Sources/Plugins/Network/**`, network tests (`Tests/PluginTests/*Network*`,
`*SFTP*`, `*FTP*`, `CoverageNet*`), new files `CovNet*`.

## w100-viewer-mac-small (prefix `CovView`, `CovMac`, `CovSmall`)

Coverage to 100% of `Sources/Plugins/Viewer/**`, `Sources/Plugins/MacIntegration/**` and the remaining small ones:
`Archives`, `Places`, `VirtualFolders`, `MultiRename`, `FileProperties`, `LocalFileSystem` (and `AFMKernel` lines
outside what w100-stability touches: coordinate through the report). Viewer: `ViewerPane.swift` (rich-mode results, late
folder/HTML results, `setMode` Quick Look arms); the pager's "index finished while looked up" branch needs a
deterministic test (a seam for the index's completion, not holding the main thread). MacIntegration:
`MacIntegrationPlugin` 95/132, `QuickLook` `toggle([])`, `VolumeProbe.system` edges. Bugs:

- testing a `.tar.gz` stops before the gzip checksum (a damaged middle goes unnoticed);
- `ProcessStream` read after close raises (Archives `Codecs.swift` / `OpenArchive.swift`);
- closing a `QLPreviewView` outside a window ends the process (Viewer `ViewerPane.swift` / `RichViews.swift`).

The one-line system adapters (`SystemDialogs`, `SystemLinks`, `SystemDesktop`, `SystemPreviewPanel`, `AppleScript.run`,
Archives `openInApplication`, Places' editor `run`) stay for the UI tests: list what is left there. Files: those source
folders, their tests, new files with your prefixes.

# Wave 102: what the wave-100 reports left (2026-10-16)

Base: `quality-gates` at `99566b9` or later. Same reading and shared rules as wave 100.

## w102-shell (prefix `ShellFix`)

- The 80 uncovered regions of `Sources/AFMShell/**` the w100-shell report lists that are not system adapters:
  `PanelRememberedVisit` (9), `ReadAhead` (8: the stall/join path, the pause limit), `+QuickFilter` (8), `+Rereading`
  (4), `+Rename` (3), `+Tabs` (3), `+Keys` size-arrival races (3), `+Layout` (2), `+Reading` (2), `PanelReadingRun` (2),
  `PanelPieceStream` (1), `+Table` (1). Races between a background answer and a panel that moved on: hold-and-release
  tests through the seams (the reading-order test shows how), or simplify the code so the arm does not exist.
- Flaky: `AppShellLifetimeTests.aUsedProgramGoesAsWell` waited 310 s for the parts to go in a full parallel run (alone
  it passes): find what keeps them (another suite's autoreleased objects on the main thread's outer pool, a
  notification, a timer) and make it deterministic.
- `Shell` / `MainWindowController` checks of a key window or an active app: through a seam if that improves the design.
- Files: `Sources/AFMShell/**`, `Tests/ShellTests/**`.

## w102-sweep (prefix `Sweep`)

- Tests that wait a fixed 60 s (or 10, 20, 30, 90) where the condition can take longer under load: `Wait.ceiling`
  everywhere (search `Tests/` for literal timeouts in waits; not timeouts that are part of what a test checks).
- Flaky under load (from the reports): `CoverageNetworkConnecting.aSavedConnectionTakesTheOtherPanelToItsLocalFolder`,
  `NetworkPluginTests.disconnectCanSaveTheQuickConnection`,
  `ViewerPluginTests.aTextIsLaidOutOnceWhenItsWindowKeepsItsSize`,
  `FilePropertiesParallelWork.changesAttributesOfATreeOnAllCores` ("couldn't be saved"),
  `KernelFixLocalTests.placesAndVolumesAnswerFromWhatIsKnown` (free-space check),
  `Review2PluginsA2.theFuzzerReproducersOfTheRenameMasksEnd`, `ViewerAdoptPane` tests (300 s under double load),
  `CovSmallArchiveTestTests.aDamagedMiddleIsFound`.
- `PluginCommandTests` builds `ViewerPlugin()` with windows shown: through the present seam.
- `TextPattern("\\x81")` with the Western encoding throws under the thread sanitizer only
  (`longLinesAreCutBetweenCharacters`): find why.
- Race-only and unreachable regions left by the wave: `ChildProcess` (5: spawn attribute init failing, EINTR retry, the
  reap race), `CommandRunner:562`, `SyncSession:576`, `ViewerPane.stripHTML` (~639), `ArchiveFileSystem:100`,
  `SpotlightSearch.finished` nil arm, `FileSearch.claim` deeper-then-nearer arm (a thread-count setting in `Tuning`),
  `MultiRenameWindowController:785` `?? []`, `FTPConnection:580`, Network's timing-dependent regions (`FTPSession:1066`,
  `NetStream:590`, `RemoteFileSystem`). For each: a deterministic test through a seam, or a simplification that removes
  the arm; report what is left and why.
- Not: FileOperations, SystemTools, CompareContent (w100-fileops-tools is still on them), AFMShell (w102-shell).

# Wave 103: coverage that does not depend on the run (2026-10-16)

## w103-determinism (prefix `Determ`)

Two whole-suite coverage runs of `52a2623` (`documentation/agent-briefs/w103/`: a plain one and one with atomic
counters, script `atomic-run.sh`) left different regions uncovered outside the system adapters: covered in one, not the
other, e.g. `OpenArchive:1386` (wrong password), `LocalFileSystem:1610` (browsable volume places, from a disk image test
that skips when `hdiutil attach` fails), `TextPattern:445`, `FileJob`, `Sorter`, `SelectionType`, `FileIdentity`,
`ViewerEncoding` (5 lines), `ByteSource:145`, `ConfigurationViews:192`, `NetworkPlugin:120`, `FTPConnection:437`. A test
that reaches a region only sometimes (timing, a skip, load) makes the gate fail at random.

- For every region uncovered in either run, outside `Sources/AFMShell/**` (w102-shell is there) and outside the system
  adapters (the `.system` sides of the effects seams, `System*.swift`, `ToolsDesktop.system`, `AppleScript.run`,
  `openInApplication`, the `present` defaults, `SavedConnections`' Keychain store, `HotlistEditorWindowController.run`,
  `VolumeEjection`'s real unmount): find the test that should reach it, and make it reach it on every run (deterministic
  order through a seam, no skip: a test that cannot make its disk image fails instead of skipping, or the case goes
  through a fake volume), or a new deterministic test. Run the whole suite with coverage at least three times (plain, as
  the gate does) and once with atomic counters; the regions outside the adapters must be covered in all of them.
- Report the adapters left (they are for the UI tests) and anything else with file:line and why.
- Owner questions you must not decide: `NetStream:242/444`, `MultiRenameWindowController:785` (impossible optionals),
  `ArchiveFileSystem:100`.
