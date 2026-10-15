# Quality gates: where the work stands and how to continue

State saved on 2026-10-15 (work stopped at 22:45 JST) (branch `quality-gates`, pushed). The plan, decisions and
gotchas are in `documentation/quality-gates-handover.md`; the briefs every agent follows are in
`documentation/agent-briefs/`.

## Prompt to continue

Paste this into a new Claude Code session in `/Users/cm0k/Claude/Projects/TotalCommander` (inside the VM "AFM macOS
27"):

> Read `documentation/quality-gates-continue.md`, `documentation/quality-gates-handover.md` and the briefs in
> `documentation/agent-briefs/`, then continue the quality-gates work exactly where the "State" section of
> `quality-gates-continue.md` leaves it. The shell agents and the panel mutation run were stopped part-way;
> resume them as that section says, then go on with "Next steps" in order.
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

### Stopped on request (2026-10-15, 22:45 JST)

Nothing runs any more; the work below was stopped part-way and is kept as it was.

- **Panel mutation run** (523 mutants in the 63 files under `Sources/AFMKernel/Panels`): stopped after about 30
  mutants, so it has no report; the per-mutant logs of those are in `.build/mutation/project_mutated/.mutation/logs`
  until the next run replaces that folder. Start it again from scratch:
  `Scripts/mutation.sh --report-dir .build/mutation/panels $(find Sources/AFMKernel/Panels -name '*.swift' | sort)`
  (remove `.build/mutation/lock` first if it exists and no `muter` process runs). It took about 88 s per mutant while
  the shell agents loaded the machine; alone, expect 30 to 50 s, about 5 to 7 hours. Then: survivors get a killing test
  (in `Tests/KernelTests/Panels*`) or an entry in `Tests/Mutation/equivalent-mutants.txt` with a real reason, and
  `python3 Scripts/mutation-gate.py check .build/mutation/panels/mutants.json` must pass.
- **Shell wave, two agents** (assignments in `documentation/agent-briefs/shell-panel.md` and `shell-app.md`, base
  `203576a`, mutation left to the coordinator), stopped mid-work. Everything they had, committed or not, is committed
  on their branches and pushed as backup branches; the last commit of each is a work-in-progress snapshot that may not
  build:
  - shell-panel: worktree `.claude/worktrees/agent-ab0b327b2e7d0b7e8`, branch `shell-panel`, pushed as
    `wip/shell-panel` (`5873ee2`): one snapshot commit of about 100 changed files (`Sources/AFMShell/Panel/**` split
    and lint work, its test files, ScriptedFileSystem being rewritten when stopped).
  - shell-app: worktree `.claude/worktrees/agent-ac064839e3432db2b`, branch `shell-app`, pushed as `wip/shell-app`
    (`3326f8b`): 4 finished commits (unused code removed; the shell's commands hold panels and kernel weakly, which
    broke a retain cycle; formatting; one declaration per file, docs, long functions split, failed settings writes
    logged) and a snapshot commit (the button-bar files being split when stopped).
  - To resume: start one agent per assignment in its worktree (or in a new worktree checked out from its `wip/`
    branch), with its assignment file plus "continue from the work already on this branch: the last commit is an
    unverified snapshot; check it, keep what is right, finish the rest, report as the briefs say".

## Next steps, in order

1. Run the panel mutation again and finish it (above), and resume the two shell agents (above), in parallel or one
   after the other (the mutation run is faster on an otherwise idle machine).
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
