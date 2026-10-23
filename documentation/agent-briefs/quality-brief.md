# A File Manager: quality work, shared brief (read fully before starting)

## Project

Swift package, macOS 14+, AppKit. A kernel (`Sources/AFMKernel`), the shared vocabulary (`Sources/AFMContracts`), the
window shell (`Sources/AFMShell`), one module per plugin (`Sources/Plugins/<Name>`, target `<Name>Plugin`),
`Sources/StandardPlugins`, the app `Sources/AFileManager`. Tests: `Tests/KernelTests`, `Tests/PluginTests`,
`Tests/ShellTests`, helpers `Tests/TestSupport`; separate packages `Tests/Fuzz/pkg`, `Tests/Stress/harness`. Read
`documentation/quality-gates-handover.md` first (decisions, environment, gotchas, the isolation model in "Done" item 8).
The gate runner is `Scripts/check.sh <gate>`.

## The bar: no compromise

The owner expects code quality without compromise. That means:

- every gate in `Scripts/check.sh` passes with zero findings, never by weakening a gate, raising a limit, adding an
  ignore/exclusion or a `// swiftlint:disable` (none is allowed, unless your assignment says otherwise and the reason is
  a real contradiction between two tools);
- behaviour does not change unless your assignment is to fix a bug; every refactor keeps the tests green;
- Swift 6 language mode with every warning an error stays clean (`swift build --build-tests` prints no warning or
  error);
- threading stays as careful as it is: file-system work off the main thread, isolation as described in the hand-over
  note. No new `@unchecked Sendable` / `nonisolated(unsafe)` without a comment naming the lock or rule; prefer designs
  that need neither;
- code reads like the surrounding code: plain, short English comments (the owner's style, see existing files), 4 spaces,
  120 columns; `swift format format --configuration .swift-format --in-place <files>` on every file you change;
- real bugs you notice are fixed (with a test) or, if outside your files, reported.

## Base and workflow

- First `git log --oneline -1`. You must start from the commit named in your assignment (or a descendant). If not:
  `git checkout -b <your-branch> <commit>`. The rtk hook may block plain `git`; then use `/usr/bin/git`.
- Change only the files your assignment gives you. If you need a change elsewhere, report it.
- Commit in small, meaningful steps in your worktree. Git config as-is; no Co-Authored-By, no "Generated with", no AI
  attribution anywhere. Message style: `<Module>: <what changed>` in plain English (see `git log`). Do not push.
- Temporary files: the scratchpad is shared with other agents; put yours in
  `/private/tmp/claude-501/sp/<your-assignment-name>/ (create it)`.

## Verifying

- The build cache goes by file content; an incremental build reports only what it compiled. For a full picture use
  `swift package clean` (or delete `.build/out/Intermediates.noindex/AFileManager.build/Debug/<Target>-t.build`).
- Before you finish: a clean `swift build --build-tests` with no output lines that are warnings or errors, the tests of
  the modules you touched, and once the whole `swift test --parallel` (it takes ~4 minutes; all must pass). For
  threading changes also `--sanitize=thread` on your modules' tests.
- SwiftLint needs the sourcekitd shim: run it through `Scripts/check.sh lint`, or source the `swiftlint_env` function
  from that script first.

## Final report (your last message; short and factual)

What you changed (per module), the commit hashes, numbers before/after for your gate(s), every bug you found, everything
you could not do and why, anything another assignment must know.
