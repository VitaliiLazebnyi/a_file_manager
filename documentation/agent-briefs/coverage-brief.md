# Coverage work: brief (read after quality-brief.md)

Goal: **100% of lines, functions and regions** of the source files your assignment lists, as
`Scripts/coverage-gate.py` counts them (all test bundles merged). Regions are Swift's branch coverage:
every arm of an `if`, `guard`, `switch`, `catch`, every side of `&&`, `||`, `??`, every closure and
autoclosure (an `assert` message, a `MainThread.assert("…")` message, a lazy default) is a region.

## Measuring

- Whole package: `swift test --parallel --enable-code-coverage`, then
  `python3 Scripts/coverage-gate.py <your source folders>` (prefixes such as `Sources/Plugins/Viewer`
  restrict the report to your files).
- While working, run only the tests that reach your files (`--filter`); the counts of a filtered run are
  lower than the merged ones, never higher, so a file at 100% there is at 100%.
- What is not covered: `xcrun llvm-cov show -instr-profile <bin>/codecov/all.profdata <test binary>
  -sources <file> -show-regions -show-line-counts-or-regions` (`<bin>` is `swift build --show-bin-path`;
  `all.profdata` is written by the gate script; a filtered run needs its own `llvm-profdata merge`).

## How, without compromise

- No exclusions of any kind: no change to the gate, its ignore pattern or the compiler flags, no
  "coverage ignore" comments, no `#if` around code to hide it from the count.
- Every test checks behaviour (the result, the state, what the user sees), not merely that code ran.
  Swift Testing, one suite per subject, test names that read as sentences, the style of the existing
  tests. Deterministic: no fixed sleeps, no timing guesses; use the wait helpers in `Tests/TestSupport`.
- Code no test can reach is a finding, not a gap to paper over:
  - unused: remove it (check with Periphery / a search of the whole repository);
  - an impossible branch (a `?? default` that can never apply, a `catch` of a call that cannot throw
    there, a `guard` that a caller already guarantees): simplify the code so the impossible case does
    not exist, with the types carrying the guarantee where possible; never `try!` / `!` on something
    that can actually fail at run time;
  - `preconditionFailure` / `fatalError` / a crash on a programming error: cover it with an exit test
    (`await #expect(processExitsWith: .failure) { … }`, Swift Testing, available in this toolchain);
  - a failure path of the system (a disk error, a process that cannot start): reach it through the
    seams that already exist (protocols, injected providers, `ScriptedFileSystem`-style fakes, a file
    without permissions, a missing executable). Do not add test-only hooks that weaken the program;
    a seam that improves the design (dependency injection of a provider) is fine.
- Behaviour does not change, except for real bugs you find: fix them with a test and list them in your
  report.
- AppKit code: drive it in unit tests as the existing ShellTests / PluginTests do (create the views and
  controllers, send the actions, check the state). The UI tests (`UITests/`) take over keyboard and mouse:
  do not run them (the coordinator does).
- New and changed files: `swift format format --configuration .swift-format --in-place <files>`, and
  zero SwiftLint findings in them (source the `swiftlint_env` function from `Scripts/check.sh`, then
  `swiftlint lint --strict <files>`). `swift build --build-tests` prints no warning.

## Sharing the machine

Several agents build at once in a VM with 12 cores and 24 GB. Build with `swift build --build-tests -j 3`
and run tests with `--filter` while you work. A resource guard watches the machine
(`Scripts/resource-guard.sh status`); when memory, swap or disk become critical it ends the largest
build or test process. A build or test that dies with signal 9 or 15 for no reason of its own was most
likely ended by it: check the status, wait until it says `ok`, then run it again (with fewer jobs). Run
the whole `swift test --parallel --enable-code-coverage` only at the end, when the status is `ok`.

## Commits and report

Commit in small steps in your worktree (message style of `git log`, no AI attribution, do not push).
The final report: the commits, the coverage numbers of your files before and after (lines, functions,
regions), the bugs found, the code removed or simplified and why, anything left and why, and anything
another assignment must know.
