# Module work: brief (read after quality-brief.md)

You own a set of files (your assignment lists them). Bring every gate to zero findings for
them, in this order (later steps rewrite less if earlier ones are done first):

1. **Dead code** (Periphery, `Scripts/check.sh deadcode`; strict, public declarations included).
   Remove what is unused. If something is unused only because a test is missing, it is still
   dead unless the feature is used by the program; if a declaration is part of the plugin API
   used by other modules, Periphery sees that. Run Periphery over the whole package and act on
   the findings in your files only.
2. **Bugs and lifetimes**: while reading your code, fix real bugs (with a test). Review every
   `unowned` reference in your files (a recent leak fix introduced many `unowned let kernel`):
   `unowned` is right only when the referenced object provably outlives the holder on every
   path (including background work finishing after a window closed or a test ended); otherwise
   use `weak` and handle nil. Every `@unchecked Sendable` / `nonisolated(unsafe)` must name its
   lock or rule; prefer a design that needs neither.
3. **Complexity** (lizard, `--CCN 10 --length 60 --arguments 5`, per function) and
   **duplicates** (jscpd, `.jscpd.json`): restructure, never by splitting a function into
   meaningless parts: extract named steps, types, tables; parameters over 5 become a value type
   when that is the natural model.
4. **Lint**: `swiftlint lint --strict` and `swiftlint analyze --strict` (see check.sh for the
   compile log) and `swift format lint --strict`, all zero for your files. Read the
   "Lint configuration" section of the hand-over: what is satisfiable and how
   (e.g. `required_deinit` with a commented body, `strict_fileprivate`, `closure_parameter_position`,
   `explicit_acl`, `one_declaration_per_file` — nest private helper types inside the type that
   uses them rather than widening access, `type_contents_order`, `identifier_name`). Run
   `swift format format` first (the formatter settings changed). Autocorrect only the rules the
   hand-over lists as safe, one rule at a time, build after each. A rename of a public or
   package API is allowed when a rule demands it; then fix every caller in the whole repository
   in the same commit, and list the rename in your report.
5. **Documentation**: every declaration that `missing_docs` reports gets a doc comment that says
   something true and useful (what, when, on which thread, what it returns or throws), in the
   owner's plain style, with a one-line summary first (swift-format's
   BeginDocumentationCommentWithOneLineSummary) — never filler like "The foo." for `foo`.
   Your modules' DocC builds without a warning:
   `swift package generate-documentation --target <Target> --warnings-as-errors`.
6. **Coverage**: 100% of lines and functions of your source files (measure with
   `swift test --enable-code-coverage` and `xcrun llvm-cov report/export` filtered to your
   files, as `Scripts/coverage-gate.py` does). Write meaningful tests that check behaviour, in
   the style of the existing tests (Swift Testing, one suite per subject, names that read as
   sentences). Code that cannot be reached by any test is either dead (remove it) or a sign the
   design needs a seam; do not add test-only hooks that weaken the code.
7. **Mutation**: every mutant in your source files killed, or listed in
   `Tests/Mutation/equivalent-mutants.txt` with a real reason (see `Scripts/mutation.sh` and
   `Scripts/mutation-gate.py` once they are in your base; if they are not, skip this step and
   say so).

Tests you add go into new files or the test files your assignment gives you; the lint and doc
rules apply to them too. Commit after each step (or more often). Keep the whole package green
at every commit (`swift build --build-tests` clean, tests passing).
