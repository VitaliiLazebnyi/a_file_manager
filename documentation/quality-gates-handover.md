# Quality gates: hand-over

State of the work to bring the project under the strictest automatic checks, written on 2026-10-14 when the work moved
from the host Mac into the test VM. Branch: `quality-gates`.

## What the owner asked for

- The strictest rules for testing, coverage, mutation testing, documentation, security testing and every other useful
  automatic scanner.
- Everything runs locally in a Parallels VM (macOS 27), not on the host.
- Decisions taken:
  - **Coverage:** 100% of lines and functions, everything covered (`Scripts/coverage-gate.py`).
  - **Docs:** every non-private declaration documented (SwiftLint `missing_docs` for open, public, package and
    internal), plus DocC without warnings.
  - **Rollout:** fix everything first, then switch the gates on (CI, pre-commit hook).
  - **Mutation testing:** every mutant killed, or listed as equivalent with the reason
    (`Tests/Mutation/equivalent-mutants.txt`); a literal 100% score is impossible because of equivalent mutants.
  - **Formatting:** the whole tree formatted once (done, commit skipped in `git blame`).
  - **SwiftLint:** every rule on; off only where two rules (or SwiftLint and swift-format) contradict each other, each
    with its reason in `.swiftlint.yml`. `no_magic_numbers` off by agreement.
  - **VMs:** newest macOS only for now. All extras wanted (property-based tests, architecture tests, plugin-API
    breaking-change checks, benchmarks with limits, memory-growth tests, UI tests, accessibility audits, snapshot tests,
    logging and diagnostics, settings-migration tests, SBOM, CodeQL).
- Publishing: no Apple Developer Program yet; notarization checks wait for a Developer ID.

## Environment

- Dev VM "AFM macOS 27": user `cm0k`, Xcode 27.0 (`DEVELOPER_DIR` set in `~/.zshenv`, because Homebrew switched
  `xcode-select` to the Command Line Tools once), Homebrew tools from `Scripts/install-tools.sh`.
- SwiftLint 0.65 needs the sourcekitd shim (`swiftlint_env` in `Scripts/check.sh`; `~/.afm-tools/bin/swiftlint` in the
  VM does the same).
- Periphery needs an index store: `swift build --build-system native` with `-index-store-path` (see the deadcode gate).
- SMB test share in the VM: share `afmsmb`, user `afmtest`; the password is in the host file
  `~/Parallels/afm-cache/vm-test-accounts`.
- UI tests: automatic login is on, `automationmodetool` allows automation without authentication, developer mode is on.
  Processes started over SSH cannot read network volumes (TCC); run such tests from the GUI session.
- Parallels snapshots: "01 fresh macOS + ssh", "02 base: Xcode 27 + tools", "03 base: tools complete".

## Done (committed)

1. swift-format over the whole tree (`.swift-format`: 4 spaces, 120 columns, every lint rule on, no trailing commas).
2. CI hardened: actions pinned to commits, read-only token, no persisted credentials, Dependabot.
3. ShellCheck findings fixed; real typos fixed; `.typos.toml` and `.gitleaks.toml` allow-lists.
4. Markdown: Prettier (120 columns) and markdownlint clean; placeholders such as `<name>` put in code spans.
5. SwiftLint automatic fixes, one rule at a time, each build-checked; all 2,161 tests pass.
6. Gate scripts: `Scripts/check.sh` (all gates), `coverage-gate.py`, `leak-check.sh`, `mutation.sh`, `vm-check.sh`,
   `install-tools.sh`; workflows `quality.yml` and `codeql.yml`; `.githooks/pre-commit` (not switched on yet).
7. `Package.swift` for Swift 6: tools 6.2, Swift 6 language mode, warnings as errors, upcoming features
   `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`, and the DocC plugin.
8. **Swift 6 migration (done 2026-10-14).** Swift 6 language mode, every warning an error, `ExistentialAny`,
   `MemberImportVisibility`, `InternalImportsByDefault`; zero diagnostics in sources and tests. The isolation model:
   - `@MainActor`: the kernel (except `nonisolated` members documented "any thread": `fileSystems`, `listingCache`,
     `settings`, `ui`, `columns`, `askUser`, `productName`), every registry, `PanelModel` (its `static` work is
     `nonisolated`), the plugin, shell and service protocols, every UI class.
   - `Sendable`: file systems, readers, writers, settings stores, job monitors, `CancellationFlag`, value types.
     Lock-guarded classes are `@unchecked Sendable` with a doc line naming the lock or the rule that makes them safe.
   - Closures that cross threads are `@Sendable`; those run on the main thread `@MainActor`. `JobMonitor.ask` and
     `Kernel.askUser` take `@MainActor @Sendable` questions; `Plugin.prepareToQuit` a `@Sendable` completion.
   - Kernel `Handover<Value>`: a documented box for values that are safe to hand over but not marked `Sendable` (values
     built on one thread and handed over whole, values one thread at a time uses). Deployment target: macOS 14. The
     pasteboard is read on the main thread only.
   - Every `@unchecked Sendable` and `nonisolated(unsafe)` was audited on 2026-10-15; the races found were fixed (lock
     or `let` via `init`), and each remaining one names the lock or the rule that makes it safe.
   - Shell `MainLoop.queue`: a main-thread block run later from the run loop; `MainLoop`/`MainOwned` are internal to the
     shell (Places and Selection keep a small `performOnMainLoop` of their own).

## Next steps, in order

1. **SwiftLint by hand.** Rules whose automatic fix broke the build: `empty_count`, `prefer_key_path`,
   `redundant_nil_coalescing`, `trailing_closure`, `unneeded_escaping`, `untyped_error_in_catch`. Then every other
   remaining finding (`swiftlint lint --strict`), including the analyzer rules (`swiftlint analyze`).
2. **Documentation:** about 8,160 non-private declarations lack doc comments; swift-format also wants a one-line summary
   first. Split by module; DocC with `--warnings-as-errors`.
3. **Dead code (Periphery, 886 incl. public), complexity (lizard, 379 functions), duplicates (jscpd).**
4. **Leaks** found by `leaks` on the test suites: Kernel ↔ CommandRegistry retain cycle (command closures capture the
   kernel strongly), FileJob cycle, Places `TreeScanner` subfolder arrays, QuitProgress, FileSystemRegistry, ToolRun,
   VirtualFileSystem, ViewerPlugin cycles; NSPasteboard, SyncComparison, SessionEnvironment leaks.
5. **Coverage to 100%** (89.4% lines at the start; lowest: Places 62%, MacIntegration 78%, DirectorySync 82%,
   SystemTools 82%, AFMShell 84%). UI tests for the AppKit code need an Xcode project (SwiftPM cannot host UI tests);
   generate it.
6. **Mutation testing.** The gate works (see "Mutation testing" below); the tests that kill the survivors are still to
   be written, module by module. A full run: 11,884 mutants, about 500 hours on one VM; split over VM clones.
7. **Extras** listed above; then switch every gate on (CI, `git config core.hooksPath .githooks`).

## Mutation testing

- **Muter is built from source:** `Scripts/build-muter.sh` installs `~/.afm-tools/bin/muter` (Muter's development branch
  at a fixed commit, plus `Scripts/muter.patch`). Homebrew's Muter 16 must not be used: its old parser crashes on Swift
  6 code (`Shell.swift`), and it loses every mutant inside a block that holds a mutant itself (22% of them); a lost
  mutant "survives" without having been tested (the 50% of the first `KeyBindings.swift` run was partly that). The
  development branch writes no mutant into the sources at all. The patch fixes both, keeps files of the same name apart,
  swaps a ternary with operators in its second choice as a whole, removes only call statements (not declarations,
  `return` or `if`), and leaves out mutants in stored-property initial values (they cannot be switched at file scope).
  With it, the whole tree with all 11,884 mutants compiles.
- **Running:** `Scripts/mutation.sh` (files changed since the branch left `origin/main`), `Scripts/mutation.sh <files>`
  or `--all`. It copies the checkout to `.build/mutation/project` (warnings are not errors in that copy only: a mutant
  may leave a value unused), and Muter runs `Scripts/mutation.sh --run-tests` per mutant: the test target of the mutated
  module first (Kernel and Contracts: KernelTests; plugins: PluginTests; shell and app: ShellTests), the others only if
  it passes, each stopped after 3 × its baseline time + 60 s (a hang counts as a kill). Reports in
  `.build/mutation/report`: Muter's `muter.json`, `mutants.json` (one record per mutant with its source text),
  per-mutant test logs in `logs/`.
- **The gate:** `Scripts/mutation-gate.py check <mutants.json>...` fails on every survivor not in
  `Tests/Mutation/equivalent-mutants.txt`, on outcomes that are not a kill, on listed mutants a test kills and on stale
  entries. An entry names file, operator, enclosing declaration and the statement before and after (no line number),
  with a mandatory reason; the gate prints a ready entry per survivor. Its source-text reading agrees with Muter's own
  snapshot on all 11,884 mutants.
- **Cost:** a mutant killed by its first target takes about 35 s (kernel), 125 s (shell) or 165 s (plugins); a survivor
  runs all three targets (about 300 s). Plugins hold 9,762 of the mutants, so the whole tree takes about 500 hours on
  one VM while survivors are rare, more before.
- **Split runs:** `Scripts/mutation-shard.sh plan <n>` counts every file's mutants (Muter's own count, a few minutes)
  and splits the files into `n` shards of equal estimated time; every machine computes the same plan at the same commit.
  On each of `n` linked clones of the snapshot "03 base: tools complete" (one per VM, 8 cores each; the clones need the
  same commit checked out and `Scripts/build-muter.sh` run once): `Scripts/mutation-shard.sh run <i> <n>`. A shard runs
  in chunks of about 2 hours (`MUTATION_CHUNK_HOURS`) and skips chunks done before, so after a restart the same command
  continues. When all are done, copy each clone's `.build/mutation/shard-<i>-of-<n>` to one checkout at that commit and
  run `Scripts/mutation-shard.sh merge <folders>`: it checks that every file under `Sources` was mutated and runs the
  gate over all reports. With 8 clones a full run takes about 62 hours per clone (4: about 125).

## Gotchas met so far

- Changing a protocol requirement that has a default implementation (`watch`, `prepareToQuit`) silently leaves
  implementations with the old signature behind: they stop implementing it and the default takes over. Grep for the old
  signature after such a change.
- The build cache goes by file content: `touch` does not force a recompile. Use `swift package clean` (or delete the
  target's folder under `.build/out/Intermediates.noindex`) to see every diagnostic; an incremental build reports only
  the files it compiled, and errors stop the build at the first module.
- Swift 6 mode checks main-actor isolation at run time inside main-actor code: a test double that is reached from a
  job's helper thread must not be main-actor-isolated (`ScriptedInteraction` is `nonisolated` and lock-guarded).

- Running all SwiftLint autocorrections at once produced code that does not compile; apply them one rule at a time.
- `MallocStackLogging` is inherited by the tools the tests start and breaks their output checks; `leak-check.sh` leaves
  it off.
- Prettier once turned `^.*?a.*?a` into emphasis and split tables at `|` inside code; check rendered text after a
  Markdown reformat.
- Homebrew's `lizard` is a compressor; the complexity tool is installed with `pipx`.
- Homebrew asks to trust third-party taps by name (`brew trust --formula ...`).
