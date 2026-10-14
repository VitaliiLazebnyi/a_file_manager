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
   - Kernel `Handover<Value>`: a documented box for values that are safe to hand over but not marked `Sendable`
     (values built on one thread and handed over whole, values one thread at a time uses). Deployment target:
     macOS 14. The pasteboard is read on the main thread only.
   - Every `@unchecked Sendable` and `nonisolated(unsafe)` was audited on 2026-10-15; the races found were fixed
     (lock or `let` via `init`), and each remaining one names the lock or the rule that makes it safe.
   - Shell `MainLoop.queue`: a main-thread block run later from the run loop; `MainLoop`/`MainOwned` are internal
     to the shell (Places and Selection keep a small `performOnMainLoop` of their own).

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
5. **Coverage to 100%** (89.4% lines at the start; lowest: Places 62%, MacIntegration 78%, DirectorySync 82%, SystemTools
   82%, AFMShell 84%). UI tests for the AppKit code need an Xcode project (SwiftPM cannot host UI tests); generate it.
6. **Mutation testing.** `Scripts/mutation-gate.py` is still to be written (parse Muter's JSON report, fail on survivors
   not listed as equivalent). A first run on `KeyBindings.swift` scored 50% (survivors at lines 33 and 52). A full run
   takes days: split the files over VM clones.
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
  hashes; checked: no mismatch warnings, +142 lines). `Scripts/coverage-gate.py` does not read them yet: it needs to
  merge `ui.profdata` with the other profiles and pass the program's binary as one more `-object`.
- **Audit findings (open):** the file lists have no accessibility label; the empty cells of the `[..]` row are static
  texts without a value; the Attr column, partly outside the visible panel, fails the contrast check; one element in the
  menu bar area (type 81) has no description. The audit test fails until they are fixed in `AFMShell`.
- **Snapshot tests:** `Tests/ShellTests/Snapshot.swift` draws a view offscreen (light appearance, 2× pixels) and
  compares it with `Tests/Snapshots/<name>.png` (a channel may be 24 of 255 off, 0.2% of the pixels may differ).
  `AFM_RECORD_SNAPSHOTS=1 swift test --filter Snapshots` records; a recording counts as a failure. A mismatch writes
  what was drawn to `.build/snapshots/`. Views in the user's accent colour make poor references.

## Gotchas met so far

- Changing a protocol requirement that has a default implementation (`watch`, `prepareToQuit`) silently leaves
  implementations with the old signature behind: they stop implementing it and the default takes over. Grep for the
  old signature after such a change.
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
