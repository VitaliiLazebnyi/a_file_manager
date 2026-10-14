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

## Lint configuration (checked rule by rule, 2026-10-15)

Every SwiftLint rule with findings was tried: real violations rewritten the way the rule wants, run through
`swift format format`, linted again. Pairs that pull in opposite directions were tried the same way.

**Off: no code satisfies both.** Each line shows what one side wants and what the other does to it.

```swift
// contrasted_opening_brace: `{` on the next line. opening_brace and swift-format: `func f() {`.
// explicit_type_interface: `let tint: NSColor = NSColor.red`. redundant_type_annotation flags exactly that.
// explicit_self (analyzer): `self.value`. redundant_self flags it.
// extension_access_modifier: `public extension A { static let b = 1 }`. no_extension_access_modifier flags
//   it; swift-format (NoAccessLevelOnExtensionDeclaration) moves `public` onto the members.
// pattern_matching_keywords: `case let .pair(a, b):`. `swift format format` (UseLetInEveryBoundCaseVariable)
//   rewrites it to `case .pair(let a, let b):`.
// object_literal: `#colorLiteral(red: 1, green: 0, blue: 0, alpha: 1)` instead of `NSColor(red:...)`.
//   discouraged_object_literal and swift-format (NoPlaygroundLiterals) forbid the literal.
// redundant_string_enum_value: `enum Color: String { case red }`. explicit_enum_raw_value wants
//   `case red = "red"`.
// sorted_imports: `import Testing` before `import TestSupport` (case ignored). `swift format format`
//   (OrderedImports) sorts by character code: `TestSupport` first (127 files).
// no_magic_numbers: off by agreement, not by contradiction.
```

`required_deinit` is now on (it was off for "contradicting `no_empty_block`"): a block holding only a comment satisfies
`no_empty_block`, so `deinit {` + `// Nothing to release.` + `}` satisfies both.

**Configured so SwiftLint and swift-format agree** (`.swiftlint.yml`, `.swift-format`):

- `.swift-format` `lineBreakBeforeEachArgument: true`: when swift-format wraps a call or a declaration it now puts each
  argument on its own line and the `)` on a line of its own, which is what `multiline_arguments`,
  `multiline_arguments_brackets`, `multiline_call_arguments` and `multiline_parameters(_brackets)` want. Formatting the
  tree once removes about 6,600 of their findings; no finding of these rules is left that the formatter makes.
- `.swift-format` `lineBreakAroundMultilineExpressionChainComponents: true`: a chain that wraps gets one call per line
  (`multiline_function_chains` 92 → 58; the rest is layout written by hand and is fixed by hand).
- `opening_brace` ignores the brace after a wrapped condition list, type header or signature: swift-format always puts
  it on a line of its own there (`if a,\n    b\n{`). Elsewhere the rule applies; when a line is too long for its `{`,
  wrap the signature or condition by hand and the brace moves down with it.
- `indentation_width` leaves the lines of multi-line string literals alone: they are text, re-indenting changes it.

**On, but swift-format's own output can violate them; fix by hand, the formatter keeps the fix:**

- `closure_parameter_position`: for a long `call(a, b) { [weak self] x in`, swift-format moves `[weak self] x in` to the
  next line. Break the arguments instead (`call(\n    a,\n    b\n) { [weak self] x in`).
- `strict_fileprivate`: swift-format turns `private extension A { func f() }` into `extension A` with a
  `fileprivate func f()`. Write `private func f()` inside a plain `extension`.
- Together, `explicit_acl`, `lower_acl_than_parent` and `strict_fileprivate` leave no access level for a member of a
  private type that other code in the file uses (`internal` is higher than the type, `fileprivate` is banned, `private`
  hides it). Make such a helper type internal (then `one_declaration_per_file` puts it in a file of its own).
- `prefixed_toplevel_constant` covers `let package = Package(...)` in the three manifests; SwiftPM does not need the
  name (`let kPackage = Package(...)` passes `swift package dump-package`).
- `trailing_closure` on calls that pick an overload by the closure's label (`register(_:parameterized:)` next to
  `register(_:handler:)`): swift-format's AmbiguousTrailingClosureOverload also objects to such overloads; give them
  different base names.

**What the gates look at.** Every Swift file git knows of: swift-format via `git ls-files` (this adds the three
`Package.swift`), SwiftLint by walking the tree. Excluded everywhere: build output, `.claude/` (agent worktrees, now in
`.gitignore`, which also keeps Prettier, jscpd and typos out; markdownlint has its own ignore), and the
`Sources`/`TestSupport` links inside `Tests/Fuzz/pkg` and `Tests/Stress/harness` (`swiftlint analyze` follows links and
reported every `Sources` finding a second time). The fuzz and stress drivers themselves are linted.

**`swiftlint analyze` covers `Sources` and `Tests/TestSupport` only.** On the test targets SourceKit crashes while
expanding Swift Testing's `@Suite` macro (Xcode 27, SwiftLint 0.65.1, with or without the sourcekitd link); the whole
run then dies. The fuzz and stress packages do not build at the moment (`CommandRegistry.swift:56`, main-actor
initializer called from a nonisolated context under their Swift 5 settings), so they have no compile log to analyse.

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

## UI tests, accessibility audit, snapshot tests

- **Project:** `UITests/project.yml` (XcodeGen) generates a project with one target, the UI test bundle; the generated
  `.xcodeproj` is not in git. The program is not built by Xcode: `Scripts/build-app.sh` builds it from the package
  (debug, coverage counting, bundle identifier `local.a-file-manager.uitests`), and the tests start that bundle with
  `XCUIApplication(url:)`. The package stays the one description of the program.
- **Running:** `Scripts/check.sh uitest` (or `UITests/run.sh [xcodebuild options]`), about 1 minute. Only in the
  logged-in session, not over SSH. Not in the default list: it needs the window server and takes over keyboard and
  mouse.
- **Isolation:** the bundle identifier of its own gives the program other preferences and another Application Support
  folder; `run.sh` empties both before and after. Each test makes its folders in the runner's temporary folder and
  passes them on the command line (`-left.tabs <data>`, the argument domain). Xcode always runs the test runner in an
  App Sandbox: the tests can write only in their container and cannot remove preferences themselves.
- **Waits:** condition-based only (`Wait`), at most 30 s; no fixed pauses.
- **Coverage:** the program writes `.build/uitest/codecov/ui-*.profraw` (`LLVM_PROFILE_FILE`), merged into
  `ui.profdata`. The counts merge with those of `swift test --enable-code-coverage` (same compiler flags, same function
  hashes; checked: no mismatch warnings, +142 lines). `Scripts/coverage-gate.py` merges `ui.profdata` with the other
  profiles and passes the program's binary as one more `-object` when a UI run left them.
- **Audit findings (open):** the file lists have no accessibility label; the empty cells of the `[..]` row are static
  texts without a value; the Attr column, partly outside the visible panel, fails the contrast check; one element in the
  menu bar area (type 81) has no description. The audit test fails until they are fixed in `AFMShell`.
- **Snapshot tests:** `Tests/ShellTests/Snapshot.swift` draws a view offscreen (light appearance, 2× pixels) and
  compares it with `Tests/Snapshots/<name>.png` (a channel may be 24 of 255 off, 0.2% of the pixels may differ).
  `AFM_RECORD_SNAPSHOTS=1 swift test --filter Snapshots` records; a recording counts as a failure. A mismatch writes
  what was drawn to `.build/snapshots/`. Views in the user's accent colour make poor references.

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
  gate over all reports. With 8 clones a full run takes about 62 hours per clone (4: about 125). The macOS licence
  allows two macOS VMs running at once on one Mac, so on this host a full run is two shards of about 250 hours each;
  more shards need more Macs.

## Extras (2026-10-15)

New gates in `Scripts/check.sh` (times in the test VM, 8 cores, with other agents' builds running beside):

| Gate           | What                                                                     | Time                                |
| -------------- | ------------------------------------------------------------------------ | ----------------------------------- |
| `architecture` | `Scripts/architecture.py`: module rules on the manifest and every import | 20 s (2 min on a cold module cache) |
| `api`          | `Scripts/api-check.sh`: plugin API against `origin/main`                 | 30 s (2.5 min with a new baseline)  |
| `memory`       | `Tests/PluginTests/MemoryGrowth`, with `AFM_MEMORY_GROWTH=1`             | 40 s after the test build           |
| `benchmarks`   | `Scripts/benchmarks.sh`: hot paths within recorded limits (not in CI)    | 2.5 to 6 min                        |
| `codeql`       | fixed: runs under Rosetta with the native build system                   | 21 min                              |
| `sbom`         | fixed: no build output or worktrees in it; checks every resolved package | 2 s                                 |

- **Architecture.** A script, not a test target: it needs the manifest (`swift package dump-package`) and the compiler's
  symbol graphs, which a test cannot get without building twice. Every `import` line of every file of every target is
  read (comments and string literals blanked out first), `@testable` included; a package module a file imports must be a
  direct dependency (SwiftPM's build finds undeclared ones anyway, checked: a plugin importing another plugin builds).
  "Names only" for AFMContracts is checked on its symbol graph: protocols and their requirements, enums and cases,
  structs, type aliases, `static let` names, stored constants, the `Format` enum (which the header names among the
  contracts), and defaults of its own protocols' requirements. Anything else is behaviour. A plugin that declares the
  shell must import it; a test target must import every module it depends on.
- **API breaks.** `swift package diagnose-api-breaking-changes` cannot be used: it only compares modules of library
  products (this package has none: "Skipping AFMKernel because it does not exist in the baseline") and fails with the
  default build system. The script checks the baseline out into `.build-tools/api/<commit>`, builds it once, dumps both
  APIs with `swift-api-digester -dump-sdk` and diagnoses them. **An intended break** is acknowledged in
  `Scripts/api-breaks.txt`: the line exactly as printed, under a `# reason:` line; a line without a reason, and a line
  that matches no break (stale once the change is on main), fail the gate. On `origin/main` itself the baseline is the
  commit before. Verified on a scratch copy: a renamed function and a defaulted parameter added were reported, a new
  name was not, acknowledged ones passed, a stale one and one without a reason failed.
- **Benchmarks.** `Tests/Benchmarks` (executable target `Benchmarks`, release with `-enable-testing` for the archive
  file system). Each run is a process of its own, so the peak footprint is the benchmark's; 5 runs, medians of clock
  time, processor time (all threads) and peak memory. Limits in `Tests/Benchmarks/limits.json` per kind of machine:
  median × 1.5 + 0.05 s (clock), × 1.3 + 0.05 s (processor), × 1.15 + 32 MB (memory). Over a limit, the benchmark is
  measured again and the lower median counts. A machine whose load is above half its cores is not judged (exit 3).
  **Updating limits:** `Scripts/benchmarks.sh --record` on a quiet machine, look at the diff, commit it with the change
  that caused it. The first run makes a folder of 100,000 files and a ZIP of it in `.build-tools/bench`.
- **Memory growth.** One serialized suite in PluginTests (it reuses the test FTP server and `TestBench`); skipped unless
  `AFM_MEMORY_GROWTH=1`, because the footprint (`Footprint`, `phys_footprint` from `task_info`) is the whole process's.
  One warm-up round, five measured rounds, freed memory handed back (`malloc_zone_pressure_relief`) before each reading;
  the last round may be at most 4 MB above the first. A self-test shows that keeping 256 KB per run is caught.
- **Property tests.** A generator and shrinker of our own in `Tests/TestSupport/Property` (about 200 lines): generators
  draw numbers from a recorded source, and shrinking replays fewer and smaller numbers, so every generator built with
  `map`/`flatMap` shrinks without code of its own. No package: the candidates (SwiftCheck) are unmaintained or would
  bring a dependency into the manifest for a few hundred lines. Seeds come from the test's name (the same on every
  machine); `AFM_PROPERTY_SEED=<n>` and `AFM_PROPERTY_RUNS=<factor>` widen the search. Properties in
  `Tests/KernelTests/Properties`: sorting (permutation, strict and transitive order, stable, independent of input order,
  long lists on all cores, resort, merge, batches), name order and keys, filter then sort equals sort then filter (and
  narrowing, and the reported places), the name index (and after moves, and long lists), `Bitset` against `Set`,
  counting long lists, `Parallel.map`, `FileItem.split`, `FileMask` against a literal reference of the specification,
  saturating arithmetic against 128-bit results, path safety.
- **Settings migration.** Fixtures (raw JSON as written) for every stored key, in `Tests/PluginTests/SettingsMigration`
  and `Tests/ShellTests/SettingsMigration*`; each is loaded by its owner, checked field by field, and written back in
  the same shape (compared as canonical JSON), so a format change fails a test and needs a fixture of its own.
- **CodeQL** needs Rosetta (its Swift extractor is Intel only; `Scripts/install-tools.sh` installs it now), the native
  build system (the tracer does not follow the default build system's build service) and `--disable-sandbox`
  (`sandbox-exec` has no Intel slice). `codeql.yml` builds the same way.

### Logging and diagnostics (proposal, not implemented)

For the module agents to implement in one way everywhere:

- **One subsystem, one category per module.** The kernel offers `public enum Log` with
  `static func logger(_ category: String) -> Logger` (it imports `os`, no UI) and the subsystem, the bundle identifier
  (`local.a-file-manager`). Categories: `Kernel`, `Kernel.Panels`, `Kernel.Jobs`, `Shell`, and the plugin's name for
  each plugin (`Archives`, `Network`, ...). Each module keeps one `private let log = Log.logger("Archives")` per file
  that logs; no `print`, no `NSLog`. An architecture rule can then check that `os.Logger` is made only through `Log`.
- **Levels.** `debug`: traces for development (not kept). `info`: state changes (folder read, job started and ended,
  archive opened). `notice`: what the user would recognise (connected to a server, settings imported). `error`: an
  operation failed (with the error). `fault`: a broken invariant (a bug).
- **Privacy.** Every name, path, URL, host, user name and message from outside is interpolated `privacy: .private` (the
  default for dynamic text; write it out anyway); counts, sizes, durations and error codes `.public`. Passwords,
  keychain items, certificate data and file contents are never logged.
- **Signposts.** An `OSSignposter` per category for the hot paths, with interval names that match the benchmarks
  (`sort`, `filter`, `mark`, `list`, `copy`, `archive-open`), so Instruments shows where the time goes in the real
  program.
- **Threads.** `Logger` is `Sendable`; logging never hops to the main thread and never waits.
- **Diagnostics export.** Help › Export Diagnostics… (in the SystemTools plugin): reads this run's entries of the
  subsystem through `OSLogStore(scope: .currentProcessIdentifier)` (private values stay `<private>`), adds the program
  and macOS versions, the machine model, the plugins, the running jobs and the settings keys with their sizes (no
  values), and writes one text file where the user chooses. Nothing is sent anywhere.
- **Tests.** Key events can be checked by reading `OSLogStore(scope: .currentProcessIdentifier)` filtered by subsystem
  and category; no logging test double is needed.

### Open findings in today's code (for the module agents)

- **Architecture gate, 8 findings.** `FilePropertiesPlugin`, `NetworkPlugin`, `SystemToolsPlugin` declare the shell
  (`needsShell: true`) but none of their files imports it; `AFileManager` declares `AFMKernel` without importing it;
  three PluginTests files (`Review2ViewerPaneTests`, `ViewerAdoptPaneTests`, `ViewerPluginTests`) import `AFMShell`,
  which PluginTests does not depend on; `Kernel.userTyped(location:proposal:relativeTo:)` in
  `AFMContracts/Services.swift:65` is behaviour in the contracts (it belongs to the kernel or the network plugin).
- **API gate, 47 breaks against `origin/main`** (7d0f18e, before the Swift 6 migration): `Sendable` added to the
  protocols `FileReader`, `FileWriter`, `FileSystemProvider`, `JobMonitor`, `SettingsStore`, `UserInteraction` and to
  generic parameters (`Parallel.map`, `JobService.run`, `JobMonitor.ask`, `Kernel.askUser`, `BlockingCalls.answer`);
  `nonisolated` on `Kernel` properties, `PanelModel.prepare`/`rows`/`filtered`, `PanelFilter.mask` and some constants;
  `FileSystemProvider.watch` returns `(any WatchToken)?` instead of `AnyObject?`. All are the migration; they need
  acknowledging with reasons (or vanish once the migration is on main).
- **`PathSafety.isContained`** (kernel): `root//../a` and `root/a//..` count as inside `root`, because
  `URL.standardized` takes the empty name for a folder that `..` leaves; the file system reads `//` as `/`. Recorded as
  a known issue in `PathSafetyProperties`. `location(ofRelativePath:)` refuses empty names first, so archives and
  servers do not reach it there; `Unpacker.lies(_:below:)` and `ArchiveFileSystem` call it directly, and
  `Unpacker.refuseLinks` uses `standardized.pathComponents` the same way.
- **`SortedFileList` (kernel)**: collecting a million entries in batches of 10,000 takes 8 s and 3.5 GB at peak
  (`batches-1m`); every batch merges the whole list and its keys again, and the merged keys keep every block of earlier
  keys. Sorting the same million at once takes 0.2 s and 680 MB.
- **`Package.swift`** is not formatted the way `.swift-format` now wants (`lineBreakBeforeEachArgument`), and has
  SwiftLint findings of its own (`explicit_acl`, `missing_docs`, `prefixed_toplevel_constant` for the helpers); the new
  `Benchmarks` target follows the file's present style.

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
