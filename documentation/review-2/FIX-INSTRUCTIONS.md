# Fix round 2 — instructions shared by every fix agent

Project: "A File Manager", a Swift/AppKit macOS dual-pane file manager (SwiftPM, macOS 13+) at
`/Users/cm0k/Claude/Projects/TotalCommander`. It is NOT a git repository: there is no undo, so edit carefully. A backup
of the state before this round is at `build/backups/before-round2-fixes.tgz` (read-only reference).

The owner's requirements: the app must never freeze and the interface must never lag, even under the hardest conditions
(a million entries, dead network shares, hostile servers and archives); threading must be correct; no data loss; no
security holes. Use all cores where it helps.

## Your work list

`documentation/review-2/findings/<area>.md` holds every item reported for your area, each with an ID.

- `finding` entries are defects to fix. The same defect often appears several times (one entry per report that mentioned
  it); fix it once.
- `verdict` entries are an independent verifier's ruling on a finding with the same file reference. Where a verdict
  narrows or refutes a finding, the verdict wins. A REFUTED finding needs no code change.
- `sound` and `gap` entries need no fix; read them for context.
- The original reports are in `documentation/review-2/reports/` if an entry is unclear.
- Reproducers from fuzzing are under `Tests/Fuzz/repro/`; stress logs under `Tests/Stress/results/`.

Fix EVERY finding in your area, including low-severity ones, unless it is refuted, is truly not a defect, or cannot be
fixed inside your area (see "Other areas"). Start with critical and high. Do the real fix at the root cause, not a patch
over the symptom, and prefer one mechanism that removes a class of findings over many spot fixes. Line numbers in the
entries are approximate; other agents are editing other areas at the same time.

## Ownership — edit only your own directories

Each agent owns the source directories named in its brief plus its own NEW test files. Do not edit files owned by
another area, even to fix a compile error (another agent is mid-edit; re-read and retry later). Existing test files that
test your area are yours to update when behaviour deliberately changes.

### Other areas

If a fix needs a change in a directory you do not own (a new kernel API, a shell call site, another plugin):

1. Do everything possible inside your area now, with a safe local fallback.
2. Append a precise request to `documentation/review-2/cross-requests/<your-area>.md`: which file/type, the exact
   signature or behaviour wanted, why, and which of your finding IDs depend on it. Do not wait for it. Kernel APIs only
   ever grow in this round (existing signatures keep working).

## Building and testing

Many agents build at once. Use your own build folder so builds do not block each other:
`swift build --scratch-path .build-<area> ...` and `swift test --scratch-path .build-<area> --filter <Pattern>` (run
from the project root). Never use the default `.build`, never delete another agent's build folder. Delete your
`.build-<area>` folder when you are finished.

- If a build fails in files you do not own, wait a few minutes and retry; do not fix them. If it still fails after
  several tries, finish what you can, and report it.
- Add tests for what you fix in NEW files named `Review2<Area>*Tests.swift` in the right test target
  (`Tests/KernelTests`, `Tests/PluginTests`, `Tests/ShellTests`), matching the style of the neighbouring tests. Test
  fakes are in `Tests/TestSupport` (owned by the kernel agent; request additions through cross-requests).
- Tests must not depend on timing margins that fail on a loaded machine (the machine is loaded now).
- Before finishing, run the tests for your area and make them pass, or state exactly which fail and why.

## Safety

- Never launch the GUI app. Never touch files outside the project and your temp directories. Tests that create files,
  FIFOs, disk images or mounts use unique temp directories and clean up (detach any disk image you attach).
- No connections to outside hosts; network tests use local fake servers.
- Shell experiments use harmless payloads only (e.g. `touch` of a marker file in your temp directory).
- Do not add dependencies. Match the surrounding code's style, naming and comment density.

## Decisions

Where a fix needs a product decision (a default, a wording, a limit), choose the safest sensible behaviour, do not stop
to ask, and record it under "Decisions" in your status file.

## Status file — required

Write `documentation/review-2/status/<area>.md` (for a shared findings file, name it as your brief says) with:

1. A table with one row per `finding` and `verdict` ID in your scope: `| ID | Status | Note |` where Status is one of
   `fixed`, `duplicate of <ID>`, `refuted`, `not a defect`, `needs other area`, `not fixed`; the note names the files
   changed or the reason. Every ID must appear.
2. "Decisions" — product decisions you took.
3. "Tests" — test files added, and the result of your final test run (counts, failures).
4. "Not done" — anything left, plainly.

Your final reply: a short summary — counts per status, the decisions, test results, and what is not done. Be exact: do
not call something fixed that you did not build and test.

---

## Second pass (added after the first pass finished)

The eleven first-pass agents are done. Their results are in `status/<area>.md` (what was fixed, decisions, what is not
done) and their requests to other areas are in `cross-requests/<area>.md`. `OPEN-AFTER-PASS-1.md` lists every ID still
open. Everything above still applies (ownership, own build folder, safety, tests, honesty), with these changes:

- Your work list is: (1) every item in ALL `cross-requests/*.md` files that asks for a change in directories you own;
  (2) every row of `OPEN-AFTER-PASS-1.md` whose remaining work is in directories you own; (3) every "Not done" /
  "partly" item in the first-pass status files of the areas you own; (4) adopting the new kernel APIs described in
  `status/kernel.md` wherever your code still uses the old main-thread-heavy calls (`prepare`/`apply` for sort, filter
  and update; the bulk selection calls and running totals; `BlockingCalls` for provider calls that can block;
  `volume(of:cancellation:)`; `PathSafety`).
- A request you judge unsound: do not implement it; say why in your status file.
- Use your own scratch folder `scratchpad/<your-area>-p2/` for any private copies — never a generic name such as
  `mirror` or `pkg` (three first-pass agents overwrote each other's scratch copies that way).
- The full `PluginTests` run can hang inside the Network tests' fake FTP server; do not wait on it. Run your own test
  classes, and `--skip Network` for wider runs, unless Network is your area.
- Status file: `status/<your-area>-p2.md`, same format; one row per ID or cross-request item you handled. Build folder:
  `.build-<your-area>-p2`.
