import Foundation
import FuzzCore

@testable import ConfigurationPlugin

/// The checks of the shell-quoting property, and its positive control.
@MainActor
internal enum QuoteChecks {
    /// Whether the positive control is on (FZ_QUOTE_CONTROL=1).
    ///
    /// The values are then pasted into the line as text, the way a program without the protection would
    /// do it. The checks must then fail for a hostile name; if they pass, the oracle is blind.
    internal static let controlIsOn = ProcessInfo.processInfo.environment["FZ_QUOTE_CONTROL"] != nil

    /// The pieces as the program makes them, or, with the positive control on, with every value pasted in.
    internal static func control(_ pieces: [ExpandedPiece]) -> [ExpandedPiece] {
        guard controlIsOn else {
            return pieces
        }
        return pieces.map { piece in
            guard case .value(let value) = piece else {
                return piece
            }
            return .text(value)
        }
    }

    /// A name that begins with `-` and is a word of its own arrives as `./-name`: the same file.
    internal static func guarded(_ name: String) -> String {
        name.unicodeScalars.first == "-" ? "./" + name : name
    }

    /// Each argument as text and as bytes, for a report.
    internal static func describeBytes(_ groups: [[UInt8]]) -> String {
        groups.map { text($0).debugDescription + " \($0)" }.joined(separator: ", ")
    }

    /// Checks one set of cases in both shells.
    internal static func check(_ cases: [QuoteCase]) {
        if !controlIsOn {
            for one in cases {
                checkLine(one)
            }
        }
        for shell in ["/bin/zsh", "/bin/sh"] {
            checkInShell(shell, cases)
        }
    }

    /// 3. The text for the shell is the same whatever the names are.
    private static func checkLine(_ one: QuoteCase) {
        guard case .success(let script) = ShellLine.script(one.pieces) else {
            fzFail("quote-refused " + one.template, one.detail)
        }
        guard case .success(let tame) = ShellLine.script(one.tamePieces) else {
            fzFail("quote-refused-tame " + one.template, one.detail)
        }
        fzCheck(
            script.line == tame.line && script.values.count == tame.values.count,
            "quote-line-depends-on-the-names " + one.template,
            "\(one.detail)\nline: \(script.line.debugDescription)\nwith tame names: \(tame.line.debugDescription)"
        )
    }

    /// 1. Nothing of a name ran, and 2. the arguments are the names, byte for byte.
    private static func checkInShell(_ shell: String, _ cases: [QuoteCase]) {
        // The first case of every set goes to a program of its own.
        let run = cases.enumerated()
            .map { entry in
                (pieces: entry.element.pieces, external: entry.element.template == "%N" && entry.offset < 200)
            }
        guard case .success(let outcome) = ShellRunner.run(shell, run) else {
            fzFail("quote-refused-in-script", shell)
        }
        fzCheck(
            outcome.created.isEmpty,
            "quote-command-ran " + shell,
            "created \(outcome.created)\n" + details(cases)
        )
        fzCheck(
            outcome.cases.count == cases.count,
            "quote-script-broken " + shell,
            "\(outcome.cases.count) cases came back of \(cases.count)\n" + details(cases)
        )
        for (one, got) in zip(cases, outcome.cases) {
            checkArguments(one, got, shell: shell)
        }
    }

    /// The arguments of one case are among the accepted values.
    private static func checkArguments(_ one: QuoteCase, _ got: [[UInt8]], shell: String) {
        let fits =
            got.count == one.expected.count
            && zip(one.expected, got)
                .allSatisfy { accepted, bytes in
                    accepted.contains { Array($0.utf8) == bytes }
                }
        if !fits {
            let expected = one.expected.map { values in values.map { $0.debugDescription + " \(Array($0.utf8))" } }
            fzFail(
                "quote-argument-differs \(one.template) \(shell)",
                "\(one.detail)\nexpected: \(expected)\ngot: \(describeBytes(got))"
            )
        }
    }

    /// The first cases' templates and names, for a report.
    private static func details(_ cases: [QuoteCase]) -> String {
        cases.prefix(40).map(\.detail).joined(separator: "\n")
    }
}
