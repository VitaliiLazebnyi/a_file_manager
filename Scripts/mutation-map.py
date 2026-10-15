#!/usr/bin/env python3
"""Which tests run which source lines: the map that lets a mutant run only the tests that reach it.

  mutation-map.py build --products <dir> --root <dir> --files <list> --output <map.json> [--jobs N]
      Runs every Swift Testing test of the test bundles in <dir> (a coverage build: `swift build
      --build-tests --enable-code-coverage`) on its own, each in its own process with its own
      profile, and records the lines of the files in <list> (paths relative to <root>) it ran.
      A test that fails here is recorded as well: its lines count all the same. A test that
      crashes or hangs (more than --limit seconds) leaves no profile; the map then says it is
      incomplete, and no line counts as run by no test.

  mutation-map.py select --map <map.json> --file <path> --line <n>
      Prints, per test target, what a mutant on that line has to run: "<target> all" for the whole
      target, else "<target> <filter>", a regular expression matching exactly its tests. Nothing
      when no test runs the line (the mutant cannot change what any test sees), and "unknown" when
      the line is not in the map (no code the coverage counts begins on it) or when the map is
      incomplete and no test runs the line, which means the whole of every target.

A mutant changes behaviour only where its line runs, so the tests that never run it cannot kill
it, with one exception: a test that runs the line can leave a process-wide state behind that makes
a later test of the same process fail. Scripts/mutation.sh therefore runs the whole of each target
the selected tests belong to before it counts a mutant as survived. The map decides a survival on
its own only for a line that no test runs.
"""

import argparse
import concurrent.futures
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

DEVELOPER = pathlib.Path(subprocess.run(
    ["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip())
PLATFORM = DEVELOPER / "Platforms" / "MacOSX.platform" / "Developer"
# Above this share of a target's tests, one run of the whole target costs less than the filter.
WHOLE_TARGET_SHARE = 0.6
# What the Swift Testing runner exits with when its filter selects no test (EX_UNAVAILABLE).
NO_TEST_MATCHED = 69


def tool(name: str) -> str:
    """The path of a developer tool, found once."""
    return subprocess.run(["xcrun", "--find", name], capture_output=True, text=True, check=True).stdout.strip()


class Runner:
    """Runs the tests of a bundle in the build's products folder, one process per test."""

    def __init__(self, products: pathlib.Path) -> None:
        self.products = products
        self.helper = str(pathlib.Path(tool("swift")).parent.parent / "libexec" / "swift" / "pm"
                          / "swiftpm-testing-helper")
        self.environment = dict(os.environ)
        self.environment["DYLD_FRAMEWORK_PATH"] = os.pathsep.join(
            [str(products), str(products / "PackageFrameworks"), str(PLATFORM / "Library" / "Frameworks")])
        self.environment["DYLD_LIBRARY_PATH"] = os.pathsep.join([str(products), str(PLATFORM / "usr" / "lib")])

    def binary(self, target: str) -> str:
        """The executable of a test target's bundle."""
        return str(self.products / f"{target}.xctest" / "Contents" / "MacOS" / target)

    def tests(self, target: str) -> list[str]:
        """The identifiers of a target's tests, as Swift Testing filters them."""
        result = subprocess.run(
            [self.helper, "--test-bundle-path", self.binary(target), "--testing-library", "swift-testing",
             "--list-tests"], capture_output=True, text=True, env=self.environment, check=True)
        return [line for line in result.stdout.splitlines() if line.startswith(target + ".")]

    def run(self, target: str, test: str, profile: pathlib.Path, limit: int) -> bool:
        """Runs one test alone, writing its profile; true when it passed within `limit` seconds."""
        environment = dict(self.environment, LLVM_PROFILE_FILE=str(profile))
        filter_text = "^" + escape(test)
        try:
            result = subprocess.run(
                [self.helper, "--test-bundle-path", self.binary(target), "--testing-library", "swift-testing",
                 "--filter", filter_text], capture_output=True, text=True, env=environment, check=False,
                timeout=limit)
        except subprocess.TimeoutExpired:
            profile.unlink(missing_ok=True)
            return False
        if result.returncode == NO_TEST_MATCHED:
            raise RuntimeError(f"the filter {filter_text} matches no test")
        return result.returncode == 0


def escape(test: str) -> str:
    """A test identifier as a regular expression that, after `^`, matches only it.

    Swift Testing matches no filter that ends in `$`; none is needed, since an identifier ends in
    the function's parameter list, `)`, which no other identifier continues.
    """
    return "".join("\\" + c if c in ".^$*+?()[]{}|\\" else c for c in test)


class Coverage:
    """Reads which lines a profile counted, with the LLVM tools of the selected Xcode."""

    def __init__(self) -> None:
        self.profdata = tool("llvm-profdata")
        self.cov = tool("llvm-cov")

    def counts(self, binary: str, profile: pathlib.Path, sources: list[str]) -> dict[str, dict[int, int]]:
        """How often each counted line of `sources` ran, per file."""
        with tempfile.TemporaryDirectory() as folder:
            merged = pathlib.Path(folder) / "test.profdata"
            subprocess.run([self.profdata, "merge", "-sparse", str(profile), "-o", str(merged)], check=True)
            result = subprocess.run(
                [self.cov, "export", "-format=lcov", "-instr-profile", str(merged), binary, *sources],
                capture_output=True, text=True, check=True)
        files: dict[str, dict[int, int]] = {}
        current: dict[int, int] = {}
        for record in result.stdout.splitlines():
            if record.startswith("SF:"):
                current = files.setdefault(record[3:], {})
            elif record.startswith("DA:"):
                number, count = record[3:].split(",")[:2]
                current[int(number)] = max(current.get(int(number), 0), int(count))
        return files


def ranges(numbers: list[int]) -> list[list[int]]:
    """Sorted line numbers as [first, last] runs."""
    runs: list[list[int]] = []
    for number in numbers:
        if runs and runs[-1][1] == number - 1:
            runs[-1][1] = number
        else:
            runs.append([number, number])
    return runs


def build(arguments: argparse.Namespace) -> int:
    root = pathlib.Path(arguments.root).resolve()
    products = pathlib.Path(arguments.products).resolve()
    relative = [line.strip() for line in pathlib.Path(arguments.files).read_text().splitlines() if line.strip()]
    sources = [str(root / path) for path in relative]
    runner = Runner(products)
    coverage = Coverage()
    targets = [path.stem for path in sorted(products.glob("*.xctest"))]
    work = pathlib.Path(tempfile.mkdtemp(prefix="mutation-map-"))
    try:
        jobs = [(target, test) for target in targets for test in runner.tests(target)]

        def one(index: int, target: str, test: str) -> tuple[str, str, bool, dict[str, list[int]]]:
            profile = work / f"{index}.profraw"
            passed = runner.run(target, test, profile, arguments.limit)
            if not profile.exists():
                return target, test, passed, None
            counts = coverage.counts(runner.binary(target), profile, sources)
            lines = {path: sorted(n for n, count in found.items() if count > 0) for path, found in counts.items()}
            return target, test, passed, {path: numbers for path, numbers in lines.items() if numbers}

        tests: dict[str, dict] = {}
        failed = []
        unrecorded = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.jobs) as pool:
            futures = [pool.submit(one, index, target, test) for index, (target, test) in enumerate(jobs)]
            for future in concurrent.futures.as_completed(futures):
                target, test, passed, lines = future.result()
                if not passed:
                    failed.append(test)
                if lines is None:
                    unrecorded.append(test)
                    continue
                tests[test] = {
                    "target": target,
                    "lines": {os.path.relpath(path, root): ranges(numbers) for path, numbers in lines.items()},
                }
        any_profile = next(work.glob("*.profraw"))
        instrumented = {}
        for target in targets:
            for path, found in coverage.counts(runner.binary(target), any_profile, sources).items():
                instrumented.setdefault(os.path.relpath(path, root), set()).update(found)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    totals = {target: sum(1 for owner, _ in jobs if owner == target) for target in targets}
    pathlib.Path(arguments.output).write_text(json.dumps({
        "targets": totals,
        "complete": not unrecorded,
        "instrumented": {path: ranges(sorted(numbers)) for path, numbers in instrumented.items()},
        "tests": tests,
    }))
    print(f"map: {len(tests)} tests in {len(targets)} targets, {len(relative)} files; {len(failed)} failed alone")
    for test in sorted(failed):
        print(f"  failed alone: {test}")
    for test in sorted(unrecorded):
        print(f"  no profile (crashed or hung): {test}")
    return 0


def contains(runs: list[list[int]], line: int) -> bool:
    return any(first <= line <= last for first, last in runs)


def select(arguments: argparse.Namespace) -> int:
    data = json.loads(pathlib.Path(arguments.map).read_text())
    if not contains(data["instrumented"].get(arguments.file, []), arguments.line):
        print("unknown")
        return 0
    chosen: dict[str, list[str]] = {}
    for test, record in data["tests"].items():
        if contains(record["lines"].get(arguments.file, []), arguments.line):
            chosen.setdefault(record["target"], []).append(test)
    if not chosen and not data["complete"]:
        print("unknown")
        return 0
    for target, tests in sorted(chosen.items()):
        if len(tests) > WHOLE_TARGET_SHARE * data["targets"][target]:
            print(f"{target} all")
        else:
            print(target, "^(" + "|".join(escape(test) for test in sorted(tests)) + ")")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    making = commands.add_parser("build")
    making.add_argument("--products", required=True)
    making.add_argument("--root", required=True)
    making.add_argument("--files", required=True)
    making.add_argument("--output", required=True)
    making.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    making.add_argument("--limit", type=int, default=600)
    choosing = commands.add_parser("select")
    choosing.add_argument("--map", required=True)
    choosing.add_argument("--file", required=True)
    choosing.add_argument("--line", type=int, required=True)
    arguments = parser.parse_args()
    return build(arguments) if arguments.command == "build" else select(arguments)


if __name__ == "__main__":
    sys.exit(main())
