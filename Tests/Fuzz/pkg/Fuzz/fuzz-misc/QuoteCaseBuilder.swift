import Foundation
import FuzzCore

@testable import ConfigurationPlugin

/// The cases of one set of names: every place a placeholder may stand, and the places it may not.
@MainActor
internal struct QuoteCaseBuilder {
    /// Places where no reference to a value can be written safely: the line must be refused.
    private static let refusedTemplates = [
        "`printf %s %N`", "\"`echo %N`\"", "$'%N'", "echo # %N", "cat <<EOF\n%N\nEOF", "\\%N", "$((%N + 1))",
        "((x = %N))", "echo $[%N]", "${x:-%N}", "$%N", "echo \"\\%N\"", "[[ %N -eq 1 ]]", "[ 1 -lt %N ]",
        "echo $arr[%N]"
    ]

    /// The cursor name.
    private let name: String
    /// The folder of the panel, `/tmp/<dir>/`.
    private let path: String
    /// The value of the variable V.
    private let value: String
    /// The marked names.
    private let selection: [String]
    /// Expands with the names.
    private let real: ParameterExpander
    /// Expands with tame names of the same number.
    private let tame: ParameterExpander
    /// The names, for a report.
    private let inputs: String
    /// The cases so far.
    private var cases: [QuoteCase] = []

    /// A builder for one set of names.
    private init(name: String, dir: String, value: String, selection: [String]) {
        self.name = name
        self.path = "/tmp/" + dir + "/"
        self.value = value
        self.selection = selection
        real = Self.expander(name, path, value, selection)
        tame = Self.expander("n", "/tmp/d/", "v", selection.map { _ in "s" })
        inputs =
            "name=\(name.debugDescription) dir=\(dir.debugDescription) value=\(value.debugDescription) "
            + "selection=\(selection.map(\.debugDescription))"
    }

    /// The cases of one set of names; fails at once when an unsafe place is not refused.
    internal static func cases(name: String, dir: String, value: String, selection: [String]) -> [QuoteCase] {
        var builder = Self(name: name, dir: dir, value: value, selection: selection)
        builder.addNameCases()
        builder.addSelectionCases()
        builder.addCommandFieldCases()
        builder.checkRefusedPlaces()
        return builder.cases
    }

    /// An expander whose left panel shows the names.
    private static func expander(
        _ name: String,
        _ path: String,
        _ value: String,
        _ selection: [String]
    ) -> ParameterExpander {
        ParameterExpander(
            context: ExpansionContext(
                left: PanelSnapshot(path: path, cursorName: name, selection: selection),
                right: PanelSnapshot(path: "/other/", cursorName: "o", selection: []),
                environment: ["V": value],
                listFolder: URL(fileURLWithPath: fzWorkDir + "/lists"),
                listName: "fixed"
            )
        )
    }

    /// Adds the case of one template; its expansion must have no problem.
    private mutating func add(_ template: String, _ expected: [[String]]) {
        let expanded = real.expand(template)
        fzCheck(
            expanded.problem == nil && !expanded.missingName,
            "quote-expansion-problem " + template,
            inputs + " problem \(expanded.problem ?? "missing name")"
        )
        cases.append(
            QuoteCase(
                template: template,
                pieces: QuoteChecks.control(expanded.pieces),
                tamePieces: tame.expand(template).pieces,
                expected: expected,
                detail: "template \(template.debugDescription) " + inputs
            )
        )
    }

    /// The cursor name in every place a placeholder may stand.
    private mutating func addNameCases() {
        let guarded = QuoteChecks.guarded(name)
        add("%N", [[guarded]])
        add("\"%N\"", [[guarded]])
        add("'%N'", [[guarded]])
        add("%P%N", [[path + name]])
        add("\"%P%N\"", [[path + name]])
        add("'%P%N'", [[path + name]])
        add("x%N", [["x" + name]])
        add("--out=%N", [["--out=" + name]])
        add("%N.bak", [[guarded + ".bak"]])
        add("\"pre %N post\"", [["pre " + name + " post"]])
        add("'pre %N post'", [["pre " + name + " post"]])
        add("\"pre%Npost\"", [["pre" + name + "post"]])
        add("'pre%Npost'", [["pre" + name + "post"]])
        add("-o %N", [["-o"], [guarded]])
        add("\"$(printf '%%s' x)\" %N", [["x"], [guarded]])
    }

    /// The marked names, the value of a variable and the other panel's folder.
    private mutating func addSelectionCases() {
        add("%S", selection.map { [QuoteChecks.guarded($0)] })
        add("%P%S", selection.map { [path + $0] })
        add("\"%S\"", selection.map { [QuoteChecks.guarded($0)] })
        add("\"new-%S-old\"", selection.map { ["new-" + $0 + "-old"] })
        add("\"%P%S\"", selection.map { [path + $0] })
        // The value of a variable is data like a name; it is no file name, so nothing is put before a `-`,
        // but a guard there would do no harm either.
        let accepted = [value, QuoteChecks.guarded(value)]
        add("%|V|", [accepted])
        add("\"%|V|\"", [accepted])
        add("'%|V|'", [accepted])
        add("%T%N", [["/other/" + name]])
    }

    /// The Command field, where %NAME% is an environment variable.
    private mutating func addCommandFieldCases() {
        for template in ["%V%", "\"%V%\"", "'%V%'", "x=%V%"] {
            let before = template.hasPrefix("x=") ? "x=" : ""
            cases.append(
                QuoteCase(
                    template: "command-field " + template,
                    pieces: CommandLanguage.environmentPieces(template, ["V": value]),
                    tamePieces: CommandLanguage.environmentPieces(template, ["V": "v"]),
                    expected: [[before + value] + (before.isEmpty ? [QuoteChecks.guarded(value)] : [])],
                    detail: "command field \(template.debugDescription) value=\(value.debugDescription)"
                )
            )
        }
    }

    /// 4. Where no reference is safe, the line is refused whatever the name.
    private func checkRefusedPlaces() {
        for template in Self.refusedTemplates {
            if case .success(let script) = ShellLine.script(real.expand("printf %s " + template).pieces) {
                fzFail(
                    "quote-unsafe-place-not-refused " + template,
                    inputs + "\nline: \(script.line.debugDescription)"
                )
            }
        }
    }
}
