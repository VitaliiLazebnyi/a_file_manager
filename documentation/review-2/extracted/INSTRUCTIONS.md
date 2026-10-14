# Extraction instructions

You are given a list of review report files in `documentation/review-2/reports/`. Read each one completely and extract EVERY distinct item into one JSON object per line (JSONL) in the output file you were given. Do not skip anything because it is small, low severity, "also noted", "unproven", a nit, a test flake, or a duplicate of something in another report: completeness is the whole point. Do not summarise several findings into one line. Do not invent anything that is not in the report. Do not read source code; this is pure extraction.

Each line is an object with exactly these fields:
- "report": the report file's two-digit number, e.g. "13"
- "kind": one of
  - "finding"  — a defect, risk or performance problem
  - "verdict"  — a verifier's ruling on someone else's claim (reports 26-31); put the ruling in "basis"
  - "sound"    — something checked and found correct
  - "gap"      — something not covered / not run / left behind
- "area": chosen by the PRIMARY source file the item is about:
  - "kernel"   Sources/AFMKernel, Sources/AFMContracts
  - "localfs"  Sources/Plugins/LocalFileSystem
  - "shell"    Sources/AFMShell, Sources/AFileManager, Sources/StandardPlugins, Scripts, Resources, signing/packaging
  - "fileops"  Plugins/FileOperations, Clipboard, FileProperties
  - "archives" Plugins/Archives
  - "network"  Plugins/Network
  - "viewer"   Plugins/Viewer
  - "find"     Plugins/FindFiles, Selection, MultiRename
  - "tools"    Plugins/DirectorySync, CompareContent, FileTools
  - "config"   Plugins/Configuration, Places, SystemTools, FolderTabs, Navigation, VirtualFolders, MacIntegration, ViewOptions
  - "tests"    test code, flaky tests, harnesses
  - "general"  none of the above
- "severity": "critical" | "high" | "medium" | "low" | "info" as the report states it (for a verdict: the severity after the ruling; if not stated, your best reading of the report's wording)
- "title": one plain sentence naming the problem
- "where": file paths with line numbers exactly as given, joined by "; " (empty string if none)
- "detail": everything else the report says about it: mechanism, trigger steps, consequence, measurements with their numbers. Keep all numbers and names. Several sentences are fine.
- "basis": how it is known: "reproduced", "measured", "read", "inferred", or for verdicts "CONFIRMED (ran)", "CONFIRMED (read)", "PARTLY CONFIRMED", "REFUTED", "UNPROVEN", plus any narrowing the verifier stated
- "fix": the fix the report proposes (empty string if none)

Write valid JSON, one object per line, UTF-8, no trailing commas, no markdown fences. When finished, validate with:
`python3 -c "import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()];print('ok')" <your output file>`
and fix any error. Then, for each report, re-scan its headings and bullet lists once more and confirm every one is represented; add what is missing. Reply with only: the number of lines written per report.
