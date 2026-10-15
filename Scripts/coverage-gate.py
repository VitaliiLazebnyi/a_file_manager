#!/usr/bin/env python3
"""Fails unless every source file is fully covered by the tests: lines, functions and regions.

Regions are Swift's branch coverage: each arm of an `if`, `guard`, `switch` or `catch`, each side of `&&`, `||` and
`??` is a region of its own (the Swift compiler writes no LLVM branch counts).

Run after `swift test --enable-code-coverage`. SwiftPM writes one profile per test bundle and its
own summary covers only one of them, so this merges every profile and reports over all bundles.
"""

import json
import pathlib
import subprocess
import sys

REQUIRED = 100.0
ROOT = pathlib.Path(__file__).resolve().parent.parent
# Written by UITests/run.sh: the counts of the program the UI tests drove, and the program.
UI_PROFILE = ROOT / ".build" / "uitest" / "codecov" / "ui.profdata"
UI_PROGRAM = ROOT / ".build" / "uitest" / "app" / "A File Manager.app" / "Contents" / "MacOS" / "AFileManager"


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, cwd=ROOT).stdout


def main() -> int:
    bin_dir = pathlib.Path(run("swift", "build", "--show-bin-path").strip())
    profiles = sorted((bin_dir / "codecov").glob("*.profraw"))
    if not profiles:
        print("no coverage profiles: run `swift test --enable-code-coverage` first", file=sys.stderr)
        return 2
    # The UI tests count too, when they ran on the sources the unit tests were built from.
    with_ui = UI_PROFILE.exists() and UI_PROGRAM.exists()
    if with_ui:
        profiles.append(UI_PROFILE)
    merged = bin_dir / "codecov" / "all.profdata"
    run("xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles), "-o", str(merged))

    bundles = sorted(bin_dir.glob("*Tests.xctest"))
    binaries = [str(b / "Contents" / "MacOS" / b.stem) for b in bundles] + ([str(UI_PROGRAM)] if with_ui else [])
    objects = [arg for binary in binaries[1:] for arg in ("-object", binary)]
    report = json.loads(
        run(
            "xcrun", "llvm-cov", "export", "-summary-only", "-instr-profile", str(merged),
            binaries[0], *objects, "-ignore-filename-regex", r"(\.build|/Tests/)",
        )
    )

    short = []
    totals = {"lines": [0, 0], "functions": [0, 0], "regions": [0, 0]}
    for entry in report["data"][0]["files"]:
        name = entry["filename"]
        if f"{ROOT}/Sources/" not in name:
            continue
        summary = entry["summary"]
        for kind in totals:
            totals[kind][0] += summary[kind]["covered"]
            totals[kind][1] += summary[kind]["count"]
        missing = {
            kind: summary[kind]["count"] - summary[kind]["covered"]
            for kind in ("lines", "functions", "regions")
            if summary[kind]["percent"] < REQUIRED
        }
        if missing:
            short.append((name.split(f"{ROOT}/")[1], missing))

    for kind, (covered, count) in totals.items():
        print(f"{kind:9} {covered:7} / {count:7}  {100 * covered / max(count, 1):6.2f}%")
    if short:
        print(f"\n{len(short)} files below {REQUIRED:.0f}% (uncovered lines / functions / regions):", file=sys.stderr)
        for name, missing in sorted(short):
            detail = ", ".join(f"{n} {kind}" for kind, n in missing.items())
            print(f"  {name}: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
