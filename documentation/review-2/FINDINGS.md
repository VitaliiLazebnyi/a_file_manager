# Review 2 — full findings index

Second code review of A File Manager (13 Oct 2026): 15 reviewers, stress and sanitizer runs, parser fuzzing, 5
independent verifiers.

- `reports/` — the 31 agent reports, verbatim.
- `findings/<area>.md` — every item extracted from them, one entry each, with an ID. The same defect reported by several
  agents appears once per report, next to each other; verifier rulings appear as `verdict` entries.
- `extracted/` — the same items as JSON lines.

| Area      | File                 | Items | Findings | Verdicts | Critical/high | Sound | Gaps |
| --------- | -------------------- | ----- | -------- | -------- | ------------- | ----- | ---- |
| kernel    | findings/kernel.md   | 85    | 39       | 17       | 9             | 23    | 6    |
| localfs   | findings/localfs.md  | 74    | 38       | 9        | 4             | 23    | 4    |
| shell     | findings/shell.md    | 106   | 59       | 14       | 10            | 25    | 8    |
| fileops   | findings/fileops.md  | 98    | 71       | 10       | 18            | 17    | 0    |
| archives  | findings/archives.md | 167   | 87       | 17       | 20            | 51    | 12   |
| network   | findings/network.md  | 162   | 94       | 14       | 8             | 43    | 11   |
| viewer    | findings/viewer.md   | 150   | 82       | 9        | 12            | 45    | 14   |
| find      | findings/find.md     | 92    | 60       | 12       | 17            | 16    | 4    |
| tools     | findings/tools.md    | 106   | 60       | 14       | 17            | 20    | 12   |
| config    | findings/config.md   | 170   | 113      | 16       | 26            | 28    | 13   |
| tests     | findings/tests.md    | 53    | 8        | 0        | 0             | 1     | 44   |
| general   | findings/general.md  | 37    | 5        | 0        | 1             | 11    | 21   |
| **total** |                      | 1300  | 716      | 132      | 142           | 303   | 149  |

**Outcome of every ID after the fix round:** `OUTCOMES.md` (each entry in `findings/*.md` also carries an "Outcome"
line). Fix agents' accounts: `status/`; closing account: `status/integration.md`, `status/harnesses.md`.
