# Quality gates: where the work stands and how to continue

State saved on 2026-10-15 at commit `be5feb3` + this file (branch `quality-gates`, pushed). The plan, decisions and
gotchas are in `documentation/quality-gates-handover.md`; the briefs every agent follows are in
`documentation/agent-briefs/`.

## Prompt to continue

Paste this into a new Claude Code session in `/Users/cm0k/Claude/Projects/TotalCommander` (inside the VM "AFM macOS
27"):

> Read `documentation/quality-gates-continue.md`, `documentation/quality-gates-handover.md` and the briefs in
> `documentation/agent-briefs/`, then continue the quality-gates work exactly where the "State" section of
> `quality-gates-continue.md` leaves it. First check what is still running or left over (the shell-panel and
> shell-app worktrees, the panel mutation run in `.build/mutation/panels`), then go on with "Next steps" in order.
> Use subagents in worktrees for module work as before; merge, verify (clean build, `swift test --parallel`,
> `Scripts/check.sh leaks`, the gates of the files touched), commit and push after each finished piece. The bar is
> code quality without compromise: no weakened gates, no ignores.

## State

### Done and pushed

- Swift 6 migration, thread-safety audits, leak fixes, the gates (lint config, mutation, UI tests, architecture, API,
  benchmarks, memory, fuzz and stress smoke tests, SBOM, CodeQL): see the hand-over.
- **Kernel and contracts wave:** core-tests, core-panels (`35e4ace`) and core-api (`1fec36c`) merged. Their files are
  clean on SwiftLint, the analyzer, swift-format, lizard, jscpd, Periphery (but 4 "redundant public" on `Log`, which
  go once the shell and plugins use it) and DocC, with 100% line and function coverage (but 2 lines of a deliberate
  `preconditionFailure` in `Kernel.attachedShell`). `PathSafety` reads paths as the file system does; `Log` exists;
  `SortedFileList` is no longer quadratic. At `203576a`: 2,355 tests pass, leak gate and API gate pass (368 breaks,
  all acknowledged in `Scripts/api-breaks.txt`).
- **Mutation tooling:** the mutant switch is one comparison with a name read once per file (`Scripts/muter.patch`,
  rebuilt with `Scripts/build-muter.sh`); each mutant runs first the tests that run its line, from the map that
  `Scripts/mutation-map.py` builds in about 4 minutes, then the whole of their targets before it counts as survived.
  A trial on `SortedFileList.swift`: 8 of 8 killed, about 10 to 20 s per mutant instead of 2.3 minutes.

### Running when this was saved (check whether it finished)

- **Panel mutation run:** `Scripts/mutation.sh --report-dir .build/mutation/panels <the 63 files under
  Sources/AFMKernel/Panels>`, 523 mutants, log `.build/mutation/panels.log`, Muter's log
  `.build/mutation/panels/muter.log`. If it finished: survivors get a killing test (in `Tests/KernelTests/Panels*`) or
  an entry in `Tests/Mutation/equivalent-mutants.txt` with a real reason; then the gate
  (`python3 Scripts/mutation-gate.py check .build/mutation/panels/mutants.json`) must pass. If it was killed: remove
  `.build/mutation/lock` (only when no `muter` process runs) and start it again.
- **Shell wave, two agents** (assignments in `documentation/agent-briefs/shell-panel.md` and `shell-app.md`, base
  `203576a`, mutation left to the coordinator):
  - shell-panel, worktree `.claude/worktrees/agent-ab0b327b2e7d0b7e8`, branch `shell-panel`: `Sources/AFMShell/Panel/**`
    and the panel test files, the file-list accessibility findings, the only one that runs `Scripts/check.sh uitest`.
    When saved: no commit yet, about 100 files changed, work in progress.
  - shell-app, worktree `.claude/worktrees/agent-ac064839e3432db2b`, branch `shell-app` (its commits so far are also
    pushed as `wip/shell-app`): `Sources/AFMShell/{App,Interaction,Window}/**`, `Sources/AFileManager/**`, the other
    shell tests, the menu-bar accessibility finding (type 81). When saved: 4 commits (unused code removed, the shell's
    commands hold panels and kernel weakly to break a retain cycle, formatting, one declaration per file and docs),
    more in progress.
  - If the agents are gone (a new session): resume each in its worktree with a new agent given its assignment file
    plus "continue from the work already in this worktree (commits and uncommitted changes); keep everything that is
    right, finish the rest, report as the briefs say".

## Next steps, in order

1. Finish the panel mutation run (above).
2. Mutation for core-api's hot files, never run because of the old switch: `Sources/AFMKernel/Support/**`,
   `Sources/AFMKernel/FileSystem/FileItem*.swift`, `URL+Locations`, and `Sources/AFMContracts/**`. Same handling of
   survivors. Known: PluginTests timing tests (`FindRenameFixRenameTests:79`, `DirectorySyncCommandTests:356`) failed in
   a mutated baseline; make them deterministic if they block the baseline.
3. Merge the shell agents when they report: check their reports, merge into `quality-gates`, verify, acknowledge any
   API breaks, commit, push. Then run the UI tests and the accessibility audit once more, and mutation over
   `Sources/AFMShell/**` with the map.
4. Plugin waves (split by plugin into several agents, same briefs, assignment files like the shell ones). Open items
   for them: Network TSan crash (`NSFileHandleOperationException` in `SFTPSession.connect`); `Unpacker.refuseLinks` reads
   `standardized.pathComponents` itself (check against `PathSafety`); settings lists that empty on one bad element
   (`multirename.saved`, `findFiles.searches`, `directorySync.sets`, `selection.types`, `network.connections` without
   id); archive rename waiting behind a long write (`OpenArchive.move`); architecture findings (FileProperties, Network
   and SystemTools declare AFMShell unused; `Review2ViewerPaneTests`, `ViewerAdoptPaneTests`, `ViewerPluginTests`
   import AFMShell); `unowned` kernel references; duplicated wait helpers in PluginTests; regenerate
   `HTMLReference.swift` after the Viewer test clean-up; StressArchives deep mode; fuzz-kernel surrogate inputs; tests
   seen flaky under load (`LocalJobs.aFinishedJobIsLetGo`, `Review2ConfigARunnerTests` 60 s wait, a FindFiles
   `NSDatePicker` exception, one "unowned reference already destroyed" crash); `MainThread.assert` closures;
   `LocalSupport.deviceID(of:)`, `isMountPoint` and `DirectoryWatcher`'s recursive mode are dead; FilePropertiesTests
   lint.
5. Then: every gate repo-wide at zero, the full mutation run (now much cheaper with the map; two VMs possible with
   `Scripts/mutation-shard.sh`), re-record the benchmark limits on a quiet VM, switch the gates on in CI and in the
   pre-commit hook (`git config core.hooksPath .githooks`).

## Environment notes

- Work runs inside the Parallels VM "AFM macOS 27" (macOS 27, Xcode 27, Swift 6.4); it pushes to GitHub with
  `~/.ssh/afm_github`. Never reset the dev VM to a snapshot.
- `/private/tmp` is wiped when the VM restarts: keep nothing there that must survive.
- Muter's source is cloned in `.build-tools/muter` (ignored by git); `Scripts/build-muter.sh` rebuilds and installs it.
- Old agent worktrees under `.claude/worktrees/` from earlier waves are merged and can be deleted.
