#!/usr/bin/env python3
"""Fails unless the modules keep to the rules in the header of Package.swift.

Two sources are checked: the manifest's graph of dependencies (`swift package dump-package`) and
the `import` lines of every Swift file of every target, `@testable` ones included. What a module
declares is checked on the symbol graph the compiler writes for it, so the rules for the contracts
and for the list of plugins look at declarations, not at text.

The rules, by kind of target:

  AFMKernel        no dependencies; imports no UI framework (AppKit and the like).
  AFMContracts     depends on the kernel at most; no UI framework. Names only: it declares
                   protocols and their requirements, enums and their cases, value types whose
                   stored properties are constants, `static let` names, type aliases, and the
                   number and date formats of `Format` (the header lists them among the contracts).
                   Function bodies are allowed only inside `Format` and as defaults of its own
                   protocols' requirements. Anything else (a method on a kernel type, a class,
                   a variable) is behaviour and is reported.
  AFMShell         the kernel and the contracts.
  plugins          (`Sources/Plugins/<Name>`, target `<Name>Plugin`) the kernel, the contracts and
                   the shell; never another plugin. A plugin that declares the shell imports it.
  StandardPlugins  the kernel and every plugin, each imported and made (`<Name>Plugin(`) in the
                   list; it declares one enum with constants and functions that make the list.
  AFileManager     the kernel, the shell and the standard plugins.
  TestSupport      the kernel only; no `@testable` import.
  tests and benchmarks (under Tests/)  any module but tests; `@testable` only for modules they
                   depend on.

For every target: each package module a file imports is a direct dependency of the target (not
one reached through another), and each dependency is imported somewhere (a plugin's standard pair,
kernel and contracts, excepted: `plugin()` in the manifest declares both for every plugin).

Usage: Scripts/architecture.py   (builds the package first: the symbol graphs need the modules)
"""

import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / ".build-tools" / "architecture"

KERNEL, CONTRACTS, SHELL = "AFMKernel", "AFMContracts", "AFMShell"
STANDARD, APP, SUPPORT = "StandardPlugins", "AFileManager", "TestSupport"
# Frameworks that draw or need a window server: not for the kernel or the contracts.
UI_FRAMEWORKS = {
    "AppKit", "AVKit", "Carbon", "Cocoa", "MetalKit", "PDFKit", "Quartz", "QuartzCore", "QuickLookThumbnailing",
    "QuickLookUI", "SceneKit", "SpriteKit", "SwiftUI", "UIKit", "WebKit",
}

IMPORT = re.compile(
    r"^[ \t]*(?P<testable>@testable[ \t]+)?(?:(?:public|package|internal|private|fileprivate)[ \t]+)?"
    r"import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|let|var)[ \t]+)?(?P<module>[A-Za-z_]\w*)",
    re.M,
)


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, cwd=ROOT).stdout


def code_only(text: str) -> str:
    """The text with comments and string literals blanked out (line breaks kept), so that an
    `import` inside a comment or a string (a script a test writes) is not taken for one."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif text[i] == '"' or (text[i] == "#" and re.match(r'#+"', text[i:])):
            hashes = len(re.match(r"#*", text[i:]).group(0))
            start = i + hashes
            quote = '"""' if text.startswith('"""', start) else '"'
            close = quote + "#" * hashes
            j = start + len(quote)
            while j < n and not text.startswith(close, j):
                j += 2 if text[j] == "\\" and not hashes else 1
            j = min(n, j + len(close))
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def target_path(target: dict) -> str:
    if target.get("path"):
        return target["path"]
    return ("Tests/" if target["type"] == "test" else "Sources/") + target["name"]


def dependencies(target: dict) -> list:
    names = []
    for dependency in target["dependencies"]:
        (kind, value), = dependency.items()
        names.append(value[0])
    return names


def kind_of(target: dict, path: str) -> str:
    name = target["name"]
    if name in (KERNEL, CONTRACTS, SHELL, STANDARD, APP, SUPPORT):
        return name
    if path.startswith("Sources/Plugins/"):
        return "plugin"
    if path.startswith("Tests/"):
        return "test"
    return "unknown"


def symbol_graph(module: str) -> list:
    """The declarations of a module, private ones included, as the compiler sees them."""
    OUT.mkdir(parents=True, exist_ok=True)
    bin_path = run("swift", "build", "--show-bin-path").strip()
    sdk = run("xcrun", "--show-sdk-path").strip()
    run(
        "xcrun", "swift-symbolgraph-extract", "-module-name", module, "-I", bin_path,
        "-target", "arm64-apple-macosx14.0", "-sdk", sdk, "-minimum-access-level", "private",
        "-module-cache-path", str(OUT / "module-cache"), "-output-dir", str(OUT),
    )
    symbols = []
    for graph in OUT.glob(f"{module}*.symbols.json"):
        data = json.loads(graph.read_text())
        targets_of = {}
        for relation in data["relationships"]:
            targets_of.setdefault(relation["source"], []).append((relation["kind"], relation["target"]))
        for symbol in data["symbols"]:
            symbol["relations"] = targets_of.get(symbol["identifier"]["precise"], [])
            symbol["graph"] = graph.name
            symbols.append(symbol)
        graph.unlink()
    return symbols


def where(symbol: dict) -> str:
    location = symbol.get("location")
    if not location:
        return ".".join(symbol["pathComponents"])
    path = location["uri"].removeprefix("file://").removeprefix(str(ROOT) + "/")
    return f"{path}:{location['position']['line'] + 1}"


def declaration(symbol: dict) -> str:
    return "".join(fragment["spelling"] for fragment in symbol.get("declarationFragments", []))


def contracts_findings() -> list:
    """Behaviour in the contracts: everything that is not a name, a shape or a format."""
    findings = []
    symbols = symbol_graph(CONTRACTS)
    own_protocols = {
        s["identifier"]["precise"] for s in symbols if s["kind"]["identifier"] == "swift.protocol"
    }
    own_requirements = {
        s["identifier"]["precise"]
        for s in symbols
        if any(k in ("requirementOf", "optionalRequirementOf") and t in own_protocols for k, t in s["relations"])
    }
    for symbol in symbols:
        kind = symbol["kind"]["identifier"]
        path = symbol["pathComponents"]
        relations = symbol["relations"]
        text = declaration(symbol)
        if path[0] == "Format" and symbol["graph"] == f"{CONTRACTS}.symbols.json":
            continue  # the number and date formats
        if kind in ("swift.protocol", "swift.enum", "swift.enum.case", "swift.struct", "swift.typealias"):
            continue
        if any(k in ("requirementOf", "optionalRequirementOf") and t in own_protocols for k, t in relations):
            continue
        if any(k == "defaultImplementationOf" and t in own_requirements for k, t in relations):
            continue  # a default for a requirement added later, so that existing plugins still build
        if kind == "swift.func.op" and symbol.get("swiftExtension", {}).get("extendedModule") == "Swift":
            continue  # `!=` that Equatable gives every type
        if kind == "swift.type.property" and re.search(r"\blet\b", text):
            continue  # a name
        if kind == "swift.property" and re.search(r"\blet\b", text) and "{" not in text:
            continue  # a stored constant of a value type
        findings.append(f"{where(symbol)}: AFMContracts holds names only, but declares `{text.strip()}` ({kind})")
    return findings


def standard_findings(plugins: list, files: list) -> list:
    """The list of plugins and nothing else."""
    findings = []
    for symbol in symbol_graph(STANDARD):
        kind = symbol["kind"]["identifier"]
        path = symbol["pathComponents"]
        text = declaration(symbol)
        if len(path) == 1 and kind == "swift.enum" and path[0] == STANDARD:
            continue
        if len(path) == 2 and path[0] == STANDARD and (
            kind == "swift.type.method" or (kind == "swift.type.property" and re.search(r"\blet\b", text))
        ):
            continue
        findings.append(f"{where(symbol)}: StandardPlugins only lists plugins, but declares `{text.strip()}` ({kind})")
    source = "".join(code_only(f.read_text()) for f in files)
    for plugin in plugins:
        if not re.search(rf"\b{plugin}\s*\(", source):
            findings.append(f"Sources/{STANDARD}: plugin {plugin} is a dependency but not made in the list")
    return findings


def main() -> int:
    run("swift", "build")
    manifest = json.loads(run("swift", "package", "dump-package"))
    targets = {t["name"]: t for t in manifest["targets"]}
    paths = {name: target_path(t) for name, t in targets.items()}
    kinds = {name: kind_of(t, paths[name]) for name, t in targets.items()}
    plugins = sorted(name for name, kind in kinds.items() if kind == "plugin")
    findings = []

    allowed = {
        KERNEL: set(),
        CONTRACTS: {KERNEL},
        SHELL: {KERNEL, CONTRACTS},
        "plugin": {KERNEL, CONTRACTS, SHELL},
        STANDARD: {KERNEL, *plugins},
        APP: {KERNEL, SHELL, STANDARD},
        SUPPORT: {KERNEL},
        "test": {name for name, kind in kinds.items() if kind != "test" and targets[name]["type"] != "executable"},
    }
    for name, target in sorted(targets.items()):
        kind = kinds[name]
        declared = dependencies(target)
        where_manifest = f"Package.swift ({name})"
        if kind == "unknown":
            findings.append(f"{where_manifest}: a target the architecture rules do not know; add it to them")
            continue
        for dependency in declared:
            if dependency not in allowed[kind]:
                findings.append(f"{where_manifest}: may not depend on {dependency}")
        if kind == "plugin":
            folder = paths[name].removeprefix("Sources/Plugins/")
            if name != folder + "Plugin":
                findings.append(f"{where_manifest}: a plugin in Sources/Plugins/{folder} is named {folder}Plugin")
            if KERNEL not in declared:
                findings.append(f"{where_manifest}: a plugin depends on the kernel")
        if kind == STANDARD:
            for plugin in plugins:
                if plugin not in declared:
                    findings.append(f"{where_manifest}: the standard plugins leave out {plugin}")

        files = sorted((ROOT / paths[name]).rglob("*.swift"))
        imported = set()
        for file in files:
            relative = file.relative_to(ROOT)
            code = code_only(file.read_text())
            for match in IMPORT.finditer(code):
                module = match.group("module")
                line = code.count("\n", 0, match.start()) + 1
                at = f"{relative}:{line}"
                imported.add(module)
                if match.group("testable") and kind not in ("test",):
                    findings.append(f"{at}: `@testable import {module}` outside a test target")
                if match.group("testable") and module not in declared:
                    findings.append(f"{at}: `@testable import {module}`, which {name} does not depend on")
                if module in targets and module not in declared and module != name:
                    findings.append(f"{at}: imports {module}, which {name} does not depend on directly")
                if kind in (KERNEL, CONTRACTS) and module in UI_FRAMEWORKS:
                    findings.append(f"{at}: {name} imports the UI framework {module}")
        for dependency in declared:
            exempt = kind == "plugin" and dependency in (KERNEL, CONTRACTS)
            if dependency not in imported and not exempt:
                findings.append(f"{where_manifest}: depends on {dependency}, which none of its files imports")
        if kind == STANDARD:
            findings += standard_findings(plugins, files)
    findings += contracts_findings()

    for finding in findings:
        print(finding)
    print(f"architecture: {len(findings)} finding(s) in {len(targets)} targets", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
