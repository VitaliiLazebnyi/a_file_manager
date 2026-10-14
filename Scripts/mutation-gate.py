#!/usr/bin/env python3
"""The mutation gate: every mutant is killed by a test, or listed as equivalent with its reason.

  mutation-gate.py collect --muter-report <muter.json> --project <dir> --files <list> --output <mutants.json>
      Turns Muter's JSON report into one record per mutant with its source text: the file, the
      line, the operator, the statement before and after the change and the declaration it is in.
      Muter's report has only positions, so this reads the sources from <dir>, the copy Muter
      ran on (its own copy, "<dir>_mutated", holds the per-mutant logs).

  mutation-gate.py check <mutants.json>... [--equivalents <file>]
      Judges one run, or the shards of a split run together. Fails on every mutant that survived
      and is not listed in Tests/Mutation/equivalent-mutants.txt, on every mutant whose outcome
      is not a kill (a build error, no coverage), on listed mutants that a test now kills and on
      listed mutants that are no longer produced (stale entries), so the list cannot rot.

A mutant is identified by its file, operator, enclosing declaration and the text of the statement
before and after the change (with an occurrence number when the same change appears more than
once in one declaration), never by its line number, so unrelated edits do not disturb the list.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parent.parent
EQUIVALENTS = ROOT / "Tests" / "Mutation" / "equivalent-mutants.txt"

KILLED = {"failed", "runtimeError", "timeout"}
NOT_INSERTED = "not inserted"  # what the test command prints for a mutant missing from the source
SURVIVED = "passed"
OPPOSITES = {
    "==": "!=", "!=": "==", ">=": "<=", "<=": ">=", ">": "<", "<": ">",  # RelationalOperatorReplacement
    "&&": "||", "||": "&&",  # ChangeLogicalConnector
}
REMOVED = "(statement removed)"
DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|fileprivate|internal|package|open|static|class|final|override|mutating|nonmutating"
    r"|nonisolated|convenience|required|lazy|dynamic|indirect|isolated|consuming|borrowing)(?:\([a-z]+\))?\s+)*"
    r"(?:func|init[?!]?|deinit|subscript|var)\b"
)
ENTRY_KEYS = ("file", "operator", "in", "before", "after", "occurrence", "reason")
REQUIRED_KEYS = ("file", "operator", "in", "before", "after", "reason")
MIN_REASON = 20


# --- Reading Swift source ------------------------------------------------------------------------------------------


COMMENT, CODE, STRING = 0, 1, 2


def code_mask(text: str) -> list[int]:
    """What each character is: COMMENT (comments), STRING (string literals) or CODE (the rest,
    string interpolations included)."""
    mask = [COMMENT] * len(text)
    size = len(text)

    def block_comment(i: int) -> int:
        depth = 0
        while i < size:
            if text.startswith("/*", i):
                depth, i = depth + 1, i + 2
            elif text.startswith("*/", i):
                depth, i = depth - 1, i + 2
                if depth == 0:
                    return i
            else:
                i += 1
        return i

    def string(i: int) -> int:
        end = string_end(i)
        for index in range(i, end):
            if mask[index] == COMMENT:
                mask[index] = STRING
        return end

    def string_end(i: int) -> int:
        hashes = 0
        while text[i + hashes] == "#":
            hashes += 1
        i += hashes
        quote = '"""' if text.startswith('"""', i) else '"'
        i += len(quote)
        close = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        while i < size:
            if text.startswith(close, i):
                return i + len(close)
            if text.startswith(escape, i):
                i += len(escape)
                if i < size and text[i] == "(":
                    # The parentheses of an interpolation are code: brackets in it match up.
                    mask[i] = CODE
                    i = code(i + 1, inside_interpolation=True)
                    if i < size:
                        mask[i] = CODE
                    i += 1
                else:
                    i += 1
            elif quote == '"' and text[i] == "\n":
                return i
            else:
                i += 1
        return i

    raw_string = re.compile(r'#+"')

    def code(i: int, inside_interpolation: bool = False) -> int:
        depth = 0
        while i < size:
            if text.startswith("//", i):
                end = text.find("\n", i)
                i = size if end < 0 else end
            elif text.startswith("/*", i):
                i = block_comment(i)
            elif text[i] == '"' or (text[i] == "#" and raw_string.match(text, i)):
                i = string(i)
            else:
                if inside_interpolation and text[i] == "(":
                    depth += 1
                elif inside_interpolation and text[i] == ")":
                    if depth == 0:
                        return i
                    depth -= 1
                mask[i] = CODE
                i += 1
        return i

    code(0)
    return mask


@dataclass
class Source:
    text: str
    mask: list[int]
    line_starts: list[int]

    @classmethod
    def read(cls, path: pathlib.Path) -> "Source":
        text = path.read_text(encoding="utf-8")
        starts = [0] + [m.end() for m in re.finditer("\n", text)]
        return cls(text, code_mask(text), starts)

    def index(self, line: int, column: int) -> int:
        """The character index of a 1-based line and UTF-8 column, as SwiftSyntax counts them."""
        start = self.line_starts[line - 1]
        end = self.line_starts[line] if line < len(self.line_starts) else len(self.text)
        prefix = self.text[start:end].encode("utf-8")[: column - 1]
        return start + len(prefix.decode("utf-8", errors="ignore"))

    def line_of(self, index: int) -> int:
        low, high = 0, len(self.line_starts) - 1
        while low < high:
            middle = (low + high + 1) // 2
            if self.line_starts[middle] <= index:
                low = middle
            else:
                high = middle - 1
        return low + 1

    def lines(self, first: int, last: int) -> tuple[int, int]:
        """The character range of whole lines first...last."""
        end = self.line_starts[last] - 1 if last < len(self.line_starts) else len(self.text)
        return self.line_starts[first - 1], end

    def is_code(self, index: int) -> bool:
        return 0 <= index < len(self.text) and self.mask[index] == CODE


def inline(text: str) -> str:
    """One line: each source line stripped, joined by single spaces."""
    return " ".join(part.strip() for part in text.splitlines() if part.strip())


def back_over_trivia(source: Source, index: int) -> int:
    """The index of the last character before `index` that is neither white space nor a comment."""
    index -= 1
    while index >= 0 and (source.mask[index] == COMMENT or source.text[index].isspace()):
        index -= 1
    return index


def matching_open(source: Source, index: int, stops: str) -> int:
    """Walks back from `index` over balanced brackets to the first code character in `stops` at depth 0."""
    depth = 0
    while index >= 0:
        char = source.text[index]
        if source.is_code(index):
            if char in ")]}":
                depth += 1
            elif char in "([{":
                if depth == 0:
                    return index
                depth -= 1
            elif depth == 0 and char in stops:
                return index
        index -= 1
    return -1


def statement_start(source: Source, end: int) -> int:
    """The first character of the statement that ends at `end`, which may span several lines."""
    index = end
    depth = 0
    while index >= 0:
        char = source.text[index]
        if source.is_code(index):
            if char in ")]}":
                depth += 1
            elif char in "([{":
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and char == ";":
                break
            elif depth == 0 and char == "\n":
                following = source.text[index + 1 : end + 1].lstrip()
                previous = source.text[: index].rstrip()
                continues = following[:1] in (".", "?", ":", "{") or following[:2] in ("&&", "||", "??")
                continues = continues or re.match(r"(==|!=|<|>|\+ |- |\* |/ |% |&|\|)", following) is not None
                continues = continues or re.match(r"else\b", following) is not None
                continues = continues or previous.endswith(("=", ",", "&&", "||", "??", "+", "-", "*", "->"))
                continues = continues or re.search(r"\bin$", previous) is not None
                if not continues:
                    break
        index -= 1
    index += 1
    while index < end and source.text[index].isspace():
        index += 1
    return index


def expression_start(source: Source, end: int) -> int:
    """The first character of the expression that ends at `end`: its statement, or the part of an
    argument list or collection after the last comma."""
    start = statement_start(source, end)
    comma = matching_open(source, end, ",")
    if comma >= start and source.text[comma] == ",":
        start = comma + 1
        while start < end and source.text[start].isspace():
            start += 1
    return start


def spaced(source: Source, index: int) -> bool:
    """Whether a character has white space on both sides, as a ternary's "?" and ":" have."""
    return 0 < index < len(source.text) - 1 and source.text[index - 1].isspace() and source.text[index + 1].isspace()


def enclosing_declaration(source: Source, line: int) -> str:
    """The signature of the nearest function, initializer, subscript or property around a line."""
    text_line = source.text[slice(*source.lines(line, line))]
    indent = len(text_line) - len(text_line.lstrip())
    for number in range(line, 0, -1):
        candidate = source.text[slice(*source.lines(number, number))]
        stripped = candidate.strip()
        own_indent = len(candidate) - len(candidate.lstrip())
        if stripped.startswith((")", "{", "where ", "->", "throws", "async")):
            continue  # the end of a signature that spans lines: its start comes further up
        if stripped and (own_indent < indent or number == line) and DECLARATION.match(stripped):
            return stripped.split(" {")[0].rstrip("{").strip()
        if stripped and own_indent < indent:
            indent = own_indent
    return ""


@dataclass
class Change:
    first_line: int
    before: str
    after: str


def describe(source: Source, operator: str, line: int, column: int) -> Change:
    """The statement a mutant changes, before and after, from Muter's position of it."""
    position = source.index(line, column)
    if operator in ("RelationalOperatorReplacement", "ChangeLogicalConnector"):
        # Muter points at the operator token (or the white space just before it).
        start = position
        while start < len(source.text) and source.text[start].isspace():
            start += 1
        token = re.match(r"[=!<>&|]+", source.text[start:])
        if token and token.group() in OPPOSITES:
            first, last = source.lines(line, source.line_of(start))
            changed = (
                source.text[first:start] + OPPOSITES[token.group()] + source.text[start + len(token.group()) : last]
            )
            return Change(line, inline(source.text[first:last]), inline(changed))
    elif operator == "SwapTernary":
        # Muter points just after the ternary expression; for a chain (`a ? x : b ? y : z`) it swaps
        # the outermost one. Its "?" is the first spaced one of the expression, its ":" the one that
        # closes it.
        end = back_over_trivia(source, position)
        start = expression_start(source, end)
        question = colon = -1
        nesting = depth = 0
        for index in range(start, end + 1):
            char = source.text[index]
            if not source.is_code(index):
                continue
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
            elif depth == 0 and char in "?:" and spaced(source, index):
                if char == "?":
                    question = index if nesting == 0 and question < 0 else question
                    nesting += 1
                elif nesting > 0:
                    nesting -= 1
                    if nesting == 0:
                        colon = index
                        break
        if 0 <= question < colon:
            first, last = source.lines(source.line_of(start), source.line_of(end))
            when_true = source.text[question + 1 : colon].strip()
            when_false = source.text[colon + 1 : end + 1].strip()
            changed = (
                source.text[first : question + 1] + " " + when_false + " : " + when_true + source.text[end + 1 : last]
            )
            return Change(source.line_of(start), inline(source.text[first:last]), inline(changed))
    elif operator == "RemoveSideEffects":
        # Muter points just after the removed statement.
        end = back_over_trivia(source, position)
        start = statement_start(source, end)
        return Change(source.line_of(start), inline(source.text[start : end + 1]), REMOVED)
    first, last = source.lines(line, line)
    return Change(line, inline(source.text[first:last]), "(not recognised: " + operator + ")")


# --- collect -----------------------------------------------------------------------------------------------------


def relative_path(path: str, project: pathlib.Path) -> str:
    """Muter reports paths inside its copy, "<project>_mutated/..."; this gives them relative to the project."""
    for prefix in (str(project) + "_mutated/", str(project.resolve()) + "_mutated/"):
        if path.startswith(prefix):
            return path[len(prefix) :]
    marker = "_mutated/"
    return path[path.index(marker) + len(marker) :] if marker in path else path


def test_log(project: pathlib.Path, point: dict) -> str:
    """The last line our test command printed for a mutant (who killed it, how long it took)."""
    position = point["position"]
    name = "{}_{}_{}_{}_{}.log".format(
        pathlib.Path(point["filePath"]).name,
        point["mutationOperatorId"],
        position["utf8Offset"],
        position["line"],
        position["column"],
    )
    log = pathlib.Path(str(project) + "_mutated") / name
    if not log.exists():
        return ""
    lines = [line for line in log.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    return lines[-1] if lines else ""


def collect(arguments: argparse.Namespace) -> int:
    project = pathlib.Path(arguments.project)
    report = json.loads(pathlib.Path(arguments.muter_report).read_text(encoding="utf-8"))
    files = [line.strip() for line in pathlib.Path(arguments.files).read_text().splitlines() if line.strip()]
    sources: dict[str, Source] = {}
    mutants = []
    for file_report in report.get("fileReports", []):
        for applied in file_report.get("appliedOperators", []):
            point = applied["mutationPoint"]
            outcome = applied["testSuiteOutcome"]
            if not point.get("filePath"):
                mutants.append({"file": file_report["fileName"], "line": 0, "column": 0, "operator": "",
                                "outcome": outcome, "in": "", "before": "", "after": "", "log": ""})
                continue
            path = relative_path(point["filePath"], project)
            if path not in sources:
                sources[path] = Source.read(project / path)
            source = sources[path]
            position = point["position"]
            change = describe(source, point["mutationOperatorId"], position["line"], position["column"])
            log = test_log(project, point)
            snapshot = applied.get("mutationSnapshot") or {}
            mutants.append({
                "file": path,
                "line": change.first_line,
                "column": position["column"],
                "operator": point["mutationOperatorId"],
                "outcome": "notInserted" if NOT_INSERTED in log else outcome,
                "in": enclosing_declaration(source, change.first_line),
                "before": change.before,
                "after": change.after,
                "log": log,
                "muter": {"before": snapshot.get("before", ""), "after": snapshot.get("after", "")},
            })
    mutants.sort(key=lambda m: (m["file"], m["line"], m["column"], m["operator"]))
    output = {
        "files": files,
        "seconds": arguments.seconds,
        "commit": arguments.commit,
        "mutants": mutants,
    }
    pathlib.Path(arguments.output).write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print("{} mutants in {} file(s) written to {}".format(len(mutants), len(files), arguments.output))
    if arguments.counts:
        counts = {path: 0 for path in files}
        for mutant in mutants:
            counts[mutant["file"]] = counts.get(mutant["file"], 0) + 1
        lines = ["{} {}".format(count, path) for path, count in sorted(counts.items())]
        pathlib.Path(arguments.counts).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


# --- check -------------------------------------------------------------------------------------------------------


@dataclass
class Entry:
    values: dict[str, str]
    line: int
    used: bool = False

    def key(self) -> tuple:
        return (
            self.values["file"],
            self.values["operator"],
            self.values["in"],
            self.values["before"],
            self.values["after"],
            int(self.values.get("occurrence", "1")),
        )


@dataclass
class Problems:
    lines: list[str] = field(default_factory=list)

    def add(self, text: str) -> None:
        self.lines.append(text)


def read_equivalents(path: pathlib.Path, problems: Problems) -> list[Entry]:
    """Blocks of "key: value" lines separated by blank lines; "#" starts a comment line. A line
    that starts with white space continues the previous value (for long reasons)."""
    entries: list[Entry] = []
    current: Entry | None = None
    last_key = ""
    if not path.exists():
        return entries
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if raw.startswith("#"):
            continue
        if not raw.strip():
            current = None
            continue
        if raw[0].isspace():
            if current is None or not last_key:
                problems.add("{}:{}: a continuation line outside an entry".format(path, number))
            else:
                current.values[last_key] += " " + raw.strip()
            continue
        key, separator, value = raw.partition(": ")
        if not separator and raw.endswith(":"):
            key, value = raw[:-1], ""
        elif not separator:
            problems.add("{}:{}: expected \"key: value\"".format(path, number))
            continue
        if key not in ENTRY_KEYS:
            problems.add("{}:{}: unknown key {!r} (keys: {})".format(path, number, key, ", ".join(ENTRY_KEYS)))
            continue
        if current is None:
            current = Entry({}, number)
            entries.append(current)
        if key in current.values:
            problems.add("{}:{}: {!r} given twice in one entry".format(path, number, key))
        current.values[key] = value.rstrip()
        last_key = key
    valid = []
    for entry in entries:
        missing = [key for key in REQUIRED_KEYS if key not in entry.values]
        reason = entry.values.get("reason", "")
        if missing:
            problems.add("{}:{}: entry without {}".format(path, entry.line, ", ".join(missing)))
        elif len(reason) < MIN_REASON or reason.upper().startswith("TODO"):
            problems.add("{}:{}: the reason must say why no test can tell the mutant apart".format(path, entry.line))
        elif not entry.values.get("occurrence", "1").isdigit() or entry.values.get("occurrence") == "0":
            problems.add("{}:{}: occurrence must be a number from 1".format(path, entry.line))
        else:
            valid.append(entry)
    seen: dict[tuple, int] = {}
    for entry in valid:
        if entry.key() in seen:
            problems.add("{}:{}: the same mutant as the entry at line {}".format(path, entry.line, seen[entry.key()]))
        seen[entry.key()] = entry.line
    return valid


def entry_text(mutant: dict) -> str:
    lines = [
        "file: " + mutant["file"],
        "operator: " + mutant["operator"],
        "in: " + mutant["in"],
        "before: " + mutant["before"],
        "after: " + mutant["after"],
    ]
    if mutant["occurrence"] > 1:
        lines.append("occurrence: {}".format(mutant["occurrence"]))
    lines.append("reason: <why no test can tell this mutant from the original>")
    return "\n".join("        " + line for line in lines)


def show(mutant: dict) -> str:
    where = "{}:{}".format(mutant["file"], mutant["line"])
    text = "{}  {}".format(where, mutant["operator"])
    if mutant["in"]:
        text += "  in " + mutant["in"]
    text += "\n        {}\n      → {}".format(mutant["before"], mutant["after"])
    if mutant.get("log"):
        text += "\n        (" + mutant["log"] + ")"
    return text


def check(arguments: argparse.Namespace) -> int:
    problems = Problems()
    mutants: list[dict] = []
    files: set[str] = set()
    commits: set[str] = set()
    seconds = 0
    for report_path in arguments.reports:
        report = json.loads(pathlib.Path(report_path).read_text(encoding="utf-8"))
        mutants.extend(report["mutants"])
        files.update(report["files"])
        seconds += report.get("seconds") or 0
        if report.get("commit"):
            commits.add(report["commit"])
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if commits - {head}:
        problems.add("the reports test commit(s) {}, the checkout is at {}: judge them at the commit they tested"
                     .format(", ".join(sorted(commits)), head))

    # Same change in the same declaration more than once: number them in source order.
    counts: dict[tuple, int] = {}
    for mutant in sorted(mutants, key=lambda m: (m["file"], m["line"], m["column"])):
        base = (mutant["file"], mutant["operator"], mutant["in"], mutant["before"], mutant["after"])
        counts[base] = counts.get(base, 0) + 1
        mutant["occurrence"] = counts[base]
    entries = read_equivalents(ROOT / arguments.equivalents, problems)
    by_key = {entry.key(): entry for entry in entries}

    killed = equivalent = 0
    survivors, untested, killed_but_listed = [], [], []
    for mutant in mutants:
        key = (mutant["file"], mutant["operator"], mutant["in"], mutant["before"], mutant["after"],
               mutant["occurrence"])
        entry = by_key.get(key)
        if entry:
            entry.used = True
        if mutant["outcome"] in KILLED:
            killed += 1
            if entry:
                killed_but_listed.append((mutant, entry))
        elif mutant["outcome"] == SURVIVED and entry:
            equivalent += 1
        elif mutant["outcome"] == SURVIVED:
            survivors.append(mutant)
        else:
            untested.append(mutant)

    stale = [
        entry for entry in entries
        if not entry.used and (entry.values["file"] in files or not (ROOT / entry.values["file"]).exists())
    ]
    not_run = sum(1 for entry in entries if not entry.used and entry not in stale)

    for mutant in survivors:
        problems.add("survived:\n    " + show(mutant))
    for mutant in untested:
        problems.add("not tested ({}):\n    {}".format(mutant["outcome"], show(mutant)))
    for mutant, entry in killed_but_listed:
        problems.add("{}:{}: listed as equivalent, but a test kills it; remove the entry:\n    {}".format(
            arguments.equivalents, entry.line, show(mutant)))
    for entry in stale:
        problems.add("{}:{}: stale entry, no such mutant any more ({}: {} → {}); update or remove it".format(
            arguments.equivalents, entry.line, entry.values["file"], entry.values["before"], entry.values["after"]))

    total = len(mutants)
    score = 100.0 * killed / (total - equivalent) if total > equivalent else 100.0
    for line in problems.lines:
        print(line)
    if survivors:
        print("\nKill each survivor with a test. Only if no test can tell it apart from the original (it behaves the")
        print("same), add it to {} with the reason:\n".format(arguments.equivalents))
        for mutant in survivors:
            print(entry_text(mutant) + "\n")
    print("{} mutants in {} file(s): {} killed, {} equivalent, {} survived, {} not tested; score {:.1f}%{}".format(
        total, len(files), killed, equivalent, len(survivors), len(untested), score,
        "; {} s, {:.1f} s per mutant".format(seconds, seconds / total) if seconds and total else ""))
    if not_run:
        print("{} listed equivalent mutant(s) are in files this run did not mutate".format(not_run))
    if problems.lines:
        print("mutation gate: FAILED ({} problem(s))".format(len(problems.lines)))
        return 1
    print("mutation gate: passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    collect_parser = commands.add_parser("collect", help="turn Muter's report into mutants.json")
    collect_parser.add_argument("--muter-report", required=True)
    collect_parser.add_argument("--project", required=True, help="the folder Muter ran in")
    collect_parser.add_argument("--files", required=True, help="the list of files Muter was given")
    collect_parser.add_argument("--output", required=True)
    collect_parser.add_argument("--seconds", type=int, default=0, help="how long the run took")
    collect_parser.add_argument("--commit", default="", help="the commit the run tested")
    collect_parser.add_argument("--counts", help="also write \"<mutants> <path>\" per file here")
    check_parser = commands.add_parser("check", help="judge one or more mutants.json reports")
    check_parser.add_argument("reports", nargs="+")
    check_parser.add_argument("--equivalents", default=str(EQUIVALENTS.relative_to(ROOT)))
    arguments = parser.parse_args()
    return collect(arguments) if arguments.command == "collect" else check(arguments)


if __name__ == "__main__":
    sys.exit(main())
