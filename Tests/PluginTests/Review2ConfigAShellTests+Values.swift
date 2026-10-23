import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Quoting the user turns off, values kept whole, numbers, dashes, list files, the prompt and real programs.
extension Review2ConfigAShellTests {
    /// `%Q` turns quoting off when the user writes it; a name that reads `%Q` cannot.
    @Test
    internal func quotingOffIsTheUsersChoiceAndDataCannotMakeIt() throws {
        // %Q: the name is pasted as it is and the shell splits it, as documented.
        let off = expand("%Q%N", name: "a b")
        #expect(off.pieces == [.raw("a b")] && off.text == "a b")
        #expect(try run([off.pieces], shell: "/bin/zsh").arguments == [["a", "b"]])
        // A name that reads `%Q` is a name: handed on to another command, it is still not read for codes.
        let outer = expand("%N", name: "%Q$(touch M) %N")
        var context = context(name: "inner", selection: [])
        context.argumentPieces = outer.pieces
        for inner in [
            ParameterExpander(context: context).expand(outer.pieces),
            ParameterExpander(context: context).expand("-v %A"),
            ParameterExpander(context: context).expand("%A1")
        ] {
            #expect(
                inner.pieces.contains(.value("%Q$(touch M) %N"))
                    && !inner.pieces.contains { piece in
                        guard case .raw = piece else {
                            return false
                        }
                        return true
                    }
            )
            let outcome = try run([inner.pieces], shell: "/bin/zsh")
            #expect(outcome.created.isEmpty && outcome.arguments.first?.last == "%Q$(touch M) %N")
        }
        // `%%Q` is a percent sign and a Q, not the code.
        #expect(expand("%%Q %N", name: "a b").pieces == [.text("%Q "), .value("a b")])
    }

    /// A value keeps every character, also blanks at its ends; an empty value stays a word.
    @Test
    internal func aValueKeepsEveryCharacter() throws {
        // Only blanks the user wrote go from the ends of the line.
        #expect(expand("  %N  ", name: "a\u{A0}").pieces == [.value("a\u{A0}")])
        #expect(expand("%N", name: "report\u{3000}").pieces == [.value("report\u{3000}")])
        #expect(expand("%N", name: " x ").pieces == [.value(" x ")])
        #expect(expand("ls\u{A0}", name: nil).pieces == [.text("ls\u{A0}")])
        // An empty value is a word of its own where it stands alone, and none where it is glued to text.
        #expect(expand("a %|NONE| b", name: nil).text == "a \"\" b" && expand("a%|NONE| b", name: nil).text == "a b")
        #expect(try ShellLine.script(expand("a %|NONE| b", name: nil).pieces).get().values == [""])
    }

    /// Numbers the user types, however large, never trap; they are limited.
    @Test
    internal func numbersTheUserTypesNeverTrap() {
        let huge = "9223372036854775807"
        let beyond = "99999999999999999999999999"
        for template in [
            "%N:~6,\(huge)", "%N:~\(huge),\(huge)", "%N:~-\(huge),-\(huge)", "%N:~\(beyond),\(beyond)",
            "%N:~-0,\(huge)", "%N:~-0,-\(beyond)",
            "%S\(huge)", "%S+\(huge)-", "%S-\(huge)-\(huge)", "%S+\(beyond)-\(beyond)", "%S-\(huge)-", "%A\(huge)",
            "%A-\(huge)-\(beyond)",
            "%A\(beyond)+", "%B9", "%C9", "%S:~\(huge),\(huge)"
        ] {
            _ = expand(template, name: "my file.txt", selection: ["a", "b", "c"])
        }
        #expect(expand("%N:~6,\(huge)", name: "my file.txt").pieces == [.value("e.txt")])
        #expect(expand("%N:~3,\(beyond)", name: "my file.txt").pieces == [.value("file.txt")])
        #expect(expand("%S+2-\(huge)", name: nil, selection: ["a", "b", "c"]).text == "b c")
        #expect(
            CommandLanguage.steps("cm_wait 99999999999999999999, cm_wait \(huge)", environment: [:]) { _ in nil }
                == [.wait(milliseconds: 0), .wait(milliseconds: CommandLanguage.longestWait)]
        )
    }

    /// A leading dash is guarded with `./` only where a word begins.
    @Test
    internal func aLeadingDashIsGuardedOnlyWhereAWordBegins() {
        #expect(
            expand("%N", name: "-x").pieces == [.value("./-x")] && expand("\"%N\"", name: "-x").text == "\"./-x\""
        )
        // After a blank inside the user's quotes the name is no argument of its own.
        #expect(
            expand("'pre %N post'", name: "-x").text == "'pre -x post'"
                && expand("\"pre %N\"", name: "-x").text == "\"pre -x\""
        )
        // A dash with a combining mark is a dash to the program that reads it.
        #expect(expand("%N", name: "-\u{301}x").pieces == [.value("./-\u{301}x")])
        // Names in the user's quotes get the guard too, each of them.
        #expect(expand("\"%S\"", name: nil, selection: ["-a", "b"]).text == "\"./-a\" \"b\"")
        #expect(expand("%S", name: nil, selection: ["-a", "-b"]).text == "./-a ./-b")
        // The user's own text inside the quotes is not touched: `$HOME` stays a variable.
        let quoted = expand("\"$HOME/%S\"", name: nil, selection: ["a b", "c"])
        #expect(quoted.pieces == [.text("\"$HOME/"), .value("a b"), .text("\" \"$HOME/"), .value("c"), .text("\"")])
        // An escaped quote does not end the user's quotes.
        #expect(expand("\"%S \\\" x\"", name: nil, selection: ["a"]).text == "\"a \\\" x\"")
    }

    /// A list file refuses names that would be two lines and guards names that begin with a dash.
    @Test
    internal func listFilesRefuseNamesThatWouldBeTwoLines() {
        let broken = expand("xargs rm < %L", name: nil, selection: ["x\n/Users/me/important", "b"])
        #expect(broken.problem?.contains("line break") == true)
        #expect(
            expand("%F", name: nil, selection: ["a\rb"]).problem != nil
                && expand("%L", name: nil, selection: ["a", "b"]).problem == nil
        )
        // Without a path, a name that begins with a dash would be an option to whoever reads the list.
        #expect(expand("%F", name: nil, selection: ["-rf", "b"]).listFile?.contents == Data("./-rf\nb\n".utf8))
        #expect(expand("%L", name: nil, selection: ["-rf"]).listFile?.contents == Data("/tmp/A dir/-rf\n".utf8))
    }

    /// The prompt shows plain names as they are and hostile ones as references, and takes them back.
    @Test
    internal func thePromptShowsNamesAndTakesThemBack() {
        let pieces = expand("-v %N %P%N '%N'", name: "my file.txt").pieces
        let shown = ShellLine.prompt(pieces)
        #expect(
            shown.text == "-v \"my file.txt\" \"/tmp/A dir/my file.txt\" 'my file.txt'" && shown.values.isEmpty
                && shown.legend.isEmpty
        )
        // A name a shell could read as something else is shown as the reference the shell gets.
        let hostileName = "a\"\u{301};touch M;\"\u{301}"
        let guarded = ShellLine.prompt(expand("-v %N \"%N\" '%N'", name: hostileName).pieces)
        // Inside the user's single quotes the quote is closed, the reference written, and the quote opened again.
        #expect(
            guarded.text == "-v \"${__afm_1}\" \"${__afm_2}\" ''\"${__afm_3}\"''"
                && guarded.values == [hostileName, hostileName, hostileName]
        )
        #expect(guarded.legend.contains("${__afm_1} = ") && !guarded.legend.contains("\n\n"))
        // What the user makes of it: the references are the values again, the rest is the user's text.
        let edited = ShellLine.pieces(fromPrompt: "--new \"${__afm_2}\" ${__afm_9} ${__afm_x", values: guarded.values)
        #expect(edited == [.text("--new \""), .value(hostileName), .text("\" ${__afm_9} ${__afm_x")])
        #expect(ShellLine.prompt(expand("%N", name: "line\nbreak").pieces).legend == "${__afm_1} = line\\nbreak")
    }

    /// Text for messages shows line breaks and control characters escaped, and is cut at its limit.
    @Test
    internal func textForMessagesHasNoLineBreaksOrControlCharacters() {
        #expect(
            DisplayText.oneLine("a\nb\rc\td\u{1B}[31m\u{202E}x\u{7}", limit: 200)
                == "a\\nb\\rc\\td\\u{1B}[31m\\u{202E}x\\u{7}"
        )
        #expect(DisplayText.oneLine("caf\u{e9} 👨‍👩‍👧 ok", limit: 200) == "caf\u{e9} 👨‍👩‍👧 ok")
        #expect(
            DisplayText.oneLine(String(repeating: "x", count: 500), limit: 10) == String(repeating: "x", count: 10)
                + "…"
        )
    }

    /// A program started by the runner gets its arguments byte for byte; one that cannot start says so.
    @Test
    internal func aProgramGetsItsArgumentsByteForByte() async throws {
        // `é` in one character: Foundation's `Process` would hand it over as `e` and an accent.
        let name = "caf\u{e9} a\u{A0}.txt"
        let out = box.url("run/bytes.bin")
        let script = try ShellLine.script([.text("printf '%s' "), .value(name), .text(" > "), .value(out.path)]).get()
        for shell in Self.shells {
            try? FileManager.default.removeItem(at: out)
            let pid =
                try ChildProcess.spawn(
                    executable: shell,
                    arguments: ["-c"] + script.arguments,
                    environment: ["PATH": "/usr/bin:/bin"],
                    directory: box.url("run").path,
                    calls: .system
                )
                .get()
            let table = ChildTable()
            let status: Int32? = await withCheckedContinuation { continuation in
                table.watch(pid, waitedFor: true) { continuation.resume(returning: $0.status) }
            }
            #expect(status == 0)
            #expect(try Data(contentsOf: out) == Data(name.utf8), "\(shell)")
        }
        // A program that cannot be started says so.
        guard
            case .failure = ChildProcess.spawn(
                executable: "/nonexistent/afm-shell",
                arguments: [],
                environment: [:],
                directory: "/",
                calls: .system
            )
        else {
            Issue.record("a missing program was started")
            return
        }
    }
}
