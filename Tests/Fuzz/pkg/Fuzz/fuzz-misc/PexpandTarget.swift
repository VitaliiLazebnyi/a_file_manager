import AFMKernel
import Foundation
import FuzzCore

@testable import ConfigurationPlugin

/// The `pexpand` target: parameter expansion, and what the runner and the command language do with its text.
@MainActor
internal enum PexpandTarget {
    /// Placeholders and the text around them.
    private static let dictionary = [
        "%P", "%T", "%N", "%M", "%O", "%E", "%S", "%R", "%B", "%BT", "%B+", "%B-", "%C1", "%C2", "%C9", "%A", "%A-1",
        "%A1-2", "%A2+", "%L", "%F", "%D", "%UL", "%WF", "%X", "%x", "%q", "%Q", "%Y", "%y", "%Z", "%a", "%V", "%v",
        "%%", "%|HOME|", "%|", ":~", ":~-0,", ":~1,2", ":~-3,-1~", ",", "-", "+", "\"", "'", "\\", "?", " ",
        "9223372036854775807", "99999999999999999999", "%S+1-", "%S-2-1", "%S3", "\"a%Sb%Ec\"", "0", "\n"
    ]

    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget("pexpand", maxLen: 2_048, dict: dictionary, seeds: seeds, run: run)
    }

    /// Templates that use each kind of placeholder.
    private static func seeds() -> [[UInt8]] {
        seedTexts([
            "%P%N %T\n", "?\"%S\" '%N' %O.%E\n", "%N:~1,3 %N:~-0,2 %N:~-4 %S+1-2:~0,1\n",
            "\"pre%Smid%Epost\" %P%S %R\n", "%B %B1 %BT2 %B+1 %B+ %C1 %C2 %C3\n",
            "%A %A1 %A-1 %A2-3 %A1+ %q%A%q\n", "%L %F %UL %WF %D %Y%y%a\n", "%X%P%N%x %|HOME| \"%|HOME|\" %Q%N\n",
            "%N:~9223372036854775807,9223372036854775807\n"
        ])
    }

    /// A name of up to 23 bytes from the input, without `/` and NUL.
    private static func name(from choices: inout Choices) -> String {
        let count = Int(choices.byte() % 24)
        var cleaned = text(choices.take(count))
        cleaned.removeAll { $0 == "/" || $0 == "\0" }
        return cleaned
    }

    /// The panels and arguments the template is expanded with; the flags byte says what the input changes.
    private static func makeContext(_ choices: inout Choices, flags: UInt8) -> ExpansionContext {
        var left = PanelSnapshot(
            path: "/Users/x y/Docs/",
            cursorName: "my file.tar.gz",
            selection: ["a.txt", "b c.txt", "-rf", "é.d"]
        )
        var right = PanelSnapshot(path: "/Volumes/Back up/", cursorName: "other.bin", selection: ["z"])
        if flags & 1 != 0 {
            left.cursorName = flags & 2 != 0 ? nil : name(from: &choices)
        }
        if flags & 4 != 0 {
            left.selection = (0..<Int(choices.byte() % 5)).map { _ in name(from: &choices) }
        }
        if flags & 8 != 0 {
            left.path = flags & 16 != 0 ? "" : "/" + name(from: &choices) + "/"
        }
        if flags & 32 != 0 {
            let path = name(from: &choices)
            right = PanelSnapshot(path: path, cursorName: flags & 64 != 0 ? nil : name(from: &choices), selection: [])
        }
        let arguments = flags & 128 != 0 ? text(choices.take(Int(choices.byte() % 40))) : "one \"two three\" four"
        return ExpansionContext(
            left: left,
            right: right,
            sourceIsRight: flags & 2 != 0,
            environment: ["HOME": "/Users/x y", "E": "a\"b"],
            arguments: arguments,
            listFolder: URL(fileURLWithPath: "/tmp/lists"),
            listName: "fixed"
        )
    }

    /// Expands the template twice and hands the text to everything that reads such text.
    private static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        let template = text(choices.until(0x0A))
        let flags = choices.byte()
        let context = makeContext(&choices, flags: flags)
        let result = ParameterExpander(context: context).expand(template)
        fzCheck(ParameterExpander(context: context).expand(template) == result, "pexpand-unstable")
        // The words around it: what the runner and the command language do with such text.
        _ = ShellWords.split(result.text)
        _ = ShellWords.split(template, at: ",")
        _ = ShellWords.unquoted(template)
        _ = ShellWords.quoted(template)
        _ = CommandLanguage.expandingEnvironment(template, context.environment)
        let steps = CommandLanguage.steps(
            template,
            environment: context.environment
        ) { $0.lowercased().hasPrefix("cm_") ? CommandID(rawValue: $0) : nil }
        for step in steps {
            if case .perform(_, let parameter) = step {
                _ = CommandLanguage.argument(from: parameter) { URL(fileURLWithPath: $0) }
            }
        }
        _ = CommandLanguage.argument(from: template) { URL(fileURLWithPath: $0) }
        _ = UserCommand.name(from: template)
        _ = CommandRunner.applicationLine(for: result.text)
        checkShellLine(result.pieces, text: result.text, template: template)
        _ = CommandLanguage.environmentPieces(template, context.environment)
    }

    /// What a shell would be given, and what the user is shown and may edit.
    private static func checkShellLine(_ pieces: [ExpandedPiece], text: String, template: String) {
        fzCheck(ShellLine.display(pieces) == text, "pexpand-text-is-not-the-display")
        switch ShellLine.script(pieces) {
        case .failure(let refusal):
            _ = refusal.explanation

        case .success(let script):
            // The values are apart from the line: as many references as values, each of the harmless form.
            // (By bytes: a reference may be followed by a combining mark of the user's text, which joins its brace.)
            let line = Data(script.line.utf8)
            for index in script.values.indices {
                let reference = Data(("${" + ShellLine.variable(index) + "}").utf8)
                fzCheck(
                    line.contains(reference),
                    "pexpand-script-value-without-reference",
                    script.line.debugDescription
                )
            }
            _ = script.text
            _ = script.arguments
        }
        let prompt = ShellLine.prompt(pieces)
        _ = ShellLine.script(ShellLine.pieces(fromPrompt: prompt.text, values: prompt.values))
        _ = ShellLine.pieces(fromPrompt: template, values: prompt.values)
        _ = ParameterExpander.usesSelection(pieces)
        if let applicationPieces = CommandRunner.applicationLine(for: pieces) {
            _ = ShellLine.script(applicationPieces)
        }
    }
}
