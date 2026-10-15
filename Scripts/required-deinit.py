#!/usr/bin/env python3
"""SwiftLint's `required_deinit`, limited to the classes where a `deinit` can be counted.

Every Swift class (one that does not descend from an Objective-C class) declares a `deinit`, as SwiftLint's
`required_deinit` demands. An Objective-C subclass (NSObject, NSView, NSWindowController, ...) declares one only when
it has something to do there: a `deinit` that holds only a comment is never counted as run in an Objective-C subclass,
even when the object is freed (one with code in it is), so coverage could not reach 100%. Such an empty `deinit` is
reported, so it goes.

Arguments, if any, are the files or folders to check; by default every Swift file git tracks under Sources and Tests.
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Superclasses from Apple's Objective-C frameworks the code subclasses, by prefix.
OBJC_PREFIXES = ("NS", "QL", "WK", "CA", "PDF", "AV", "UN", "MK", "XC")
CLASS = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate|open|final)\s+)*"
    r"class\s+(\w+)\s*(?:<[^>{]*>)?\s*(?::\s*([^{]+?))?\s*(?:where\s[^{]*)?\{",
    re.MULTILINE,
)
DEINIT = re.compile(r"\bdeinit\s*\{")


def strip(source: str) -> str:
    """The source with comments and string contents blanked out (same length, so offsets stay)."""
    out = list(source)
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
        elif source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif source.startswith('"""', i):
            j = source.find('"""', i + 3)
            j = n if j < 0 else j + 3
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] not in '"\n':
                j += 2 if source[j] == "\\" else 1
            j += 1
        else:
            i += 1
            continue
        for k in range(i, min(j, n)):
            if out[k] != "\n":
                out[k] = " "
        i = j
    return "".join(out)


def body_end(code: str, start: int) -> int:
    """The index of the `}` that closes the `{` at `start`."""
    depth = 0
    for i in range(start, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return len(code)


def top_level(code: str, start: int, end: int) -> str:
    """The body between `start` and `end` with every nested `{ ... }` blanked out."""
    out, depth = [], 0
    for ch in code[start + 1 : end]:
        if ch == "}":
            depth -= 1
        out.append(ch if depth == 0 else " ")
        if ch == "{":
            depth += 1
    return "".join(out)


def files(arguments: list[str]) -> list[pathlib.Path]:
    if not arguments:
        listed = subprocess.run(
            ["git", "ls-files", "Sources/*.swift", "Tests/*.swift"], check=True, capture_output=True, text=True,
            cwd=ROOT,
        ).stdout.split()
        return [ROOT / name for name in listed]
    paths = [pathlib.Path(a).resolve() for a in arguments]
    return [f for p in paths for f in (sorted(p.rglob("*.swift")) if p.is_dir() else [p])]


def main() -> int:
    classes = []  # (file, line, name, first inherited type, has deinit, deinit is only a comment)
    for path in files(sys.argv[1:]):
        source = path.read_text()
        code = strip(source)
        for match in CLASS.finditer(code):
            opening = match.end() - 1
            end = body_end(code, opening)
            body = top_level(code, opening, end)
            deinit = DEINIT.search(body)
            empty = False
            if deinit:
                at = opening + 1 + deinit.end() - 1
                empty = code[at + 1 : body_end(code, at)].strip() == ""
            parent = (match.group(2) or "").split(",")[0].strip().split("<")[0].split(".")[-1]
            line = source.count("\n", 0, match.start(1)) + 1
            classes.append((path.relative_to(ROOT), line, match.group(1), parent, bool(deinit), empty))

    parents = {name: parent for _, _, name, parent, _, _ in classes}

    def objc(name: str, seen: frozenset = frozenset()) -> bool:
        parent = parents.get(name, "")
        if not parent or name in seen:
            return False
        if parent in parents:
            return objc(parent, seen | {name})
        prefix = next((p for p in OBJC_PREFIXES if parent.startswith(p)), None)
        return prefix is not None and parent[len(prefix) : len(prefix) + 1].isupper()

    findings = []
    for path, line, name, _, has_deinit, empty in classes:
        if objc(name):
            if empty:
                findings.append(f"{path}:{line}: `{name}` descends from an Objective-C class; its empty deinit goes")
        elif not has_deinit:
            findings.append(f"{path}:{line}: `{name}` declares no deinit (required_deinit)")
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
