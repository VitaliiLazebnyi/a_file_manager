#!/usr/bin/env python3
"""Fails unless every test bundle ran all its tests: reads the output of `swift test` and compares it with the sources.

A test process can end before its tests are done without a failure being reported: anything that stops the main run
loop (`NSApp.stopModal()` outside a modal loop, `CFRunLoopStop` on the main loop) ends a Swift Testing process with
status 0, and `swift test` goes on with the next bundle. A crash of a bundle is reported only in the middle of the
output. So every bundle must end with its summary ("Test run with N tests ... passed"), and N must be the number of
`@Test` functions in its folder under Tests/.

Usage: `swift test ... 2>&1 | tee log; python3 Scripts/test-run-check.py log`
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLES = ("KernelTests", "PluginTests", "ShellTests")
SUMMARY = re.compile(r"Test run with (\d+) tests? in \d+ suites? (passed|failed)")
CRASH = re.compile(r"swiftpm-testing-helper --test-bundle-path \S*/(\w+)\.xctest\S* .*exited with unexpected signal code (\d+)")


def declared(bundle: str) -> int:
    """The `@Test` functions in the bundle's sources, comment lines left out."""
    count = 0
    for path in (ROOT / "Tests" / bundle).rglob("*.swift"):
        for line in path.read_text(errors="replace").splitlines():
            if not line.lstrip().startswith("//"):
                count += len(re.findall(r"@Test\b", line))
    return count


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    log = pathlib.Path(sys.argv[1]).read_text(errors="replace")
    runs = [int(m.group(1)) for m in SUMMARY.finditer(log)]
    # The XCTest summary of a bundle without XCTest cases ("Executed 0 tests") is not one of these.
    expected = {bundle: declared(bundle) for bundle in BUNDLES}
    problems = [f"{name} ended with signal {code}" for name, code in CRASH.findall(log)]
    for bundle, count in expected.items():
        if count not in runs:
            problems.append(f"{bundle}: no summary of {count} tests (summaries seen: {runs})")
    for problem in problems:
        print(problem, file=sys.stderr)
    if not problems:
        print("every bundle ran all its tests: " + ", ".join(f"{b} {n}" for b, n in expected.items()))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
