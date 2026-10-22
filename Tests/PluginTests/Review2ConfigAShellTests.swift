import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// File names against real shells (review 2, C002 and its kin): a name is handed to the shell
/// as data and referred to, so whatever it is made of, it arrives as one argument and nothing
/// of it runs.
///
/// Every payload only tries to `touch` a marker file in the test's own folder.
@Suite
struct Review2ConfigAShell {
    static let shells = ["/bin/zsh", "/bin/sh"]

    /// Names that ran commands before, and their relatives.
    ///
    /// The marks after a quote, a backtick, a backslash and a dollar sign are U+0301: one
    /// `Character` with what they follow.
    static let hostile: [String] = [
        "a\"\u{301};touch M1;\"\u{301}", "`\u{301};touch M2;`\u{301}", "\\\u{301}", "$\u{301}(touch M3)",
        "'\u{301};touch M4;'\u{301}",
        "a\"\u{FE0F};touch M5;\"\u{FE0F}", "';touch M6;'", "a;touch M7", "$(touch M8)", "`touch M9`",
        "line\nbreak;touch M10\n;touch M11",
        "-rf", "-\u{301}x", "g x;touch M12", "e\";touch M13;\"", "f$(touch M14)", "h\\';touch M15;'", "\\';touch M16;#",
        "a\\", "a\u{A0}",
        "report\u{3000}", " lead and trail ", "!bang", "~", "*", "#c", "x=1", "a&b|c>d<e", "tab\there",
        "${IFS}touch${IFS}M17", "$0", "%N%Q",
        "\u{1B}[31mred", "a\rb"
    ]

    let box: Sandbox

    init() throws {
        box = try Sandbox()
        try box.folder("run")
    }

    func context(name: String?, selection: [String] = []) -> ExpansionContext {
        ExpansionContext(
            left: PanelSnapshot(path: "/tmp/A dir/", cursorName: name, selection: selection),
            right: PanelSnapshot(path: "/B/", cursorName: nil),
            environment: ["EVIL": "e'v\"\u{301}il $x `touch M18`;touch M19"],
            listFolder: box.url("lists"),
            listName: "t"
        )
    }

    func expand(_ template: String, name: String?, selection: [String] = []) -> ExpandedParameters {
        ParameterExpander(context: context(name: name, selection: selection)).expand(template)
    }

    struct Outcome {
        /// The arguments of each case, as the shell made them.
        var arguments: [[String]]
        var created: [String]
    }

    /// Runs `printf` with the pieces of every case as its arguments, all cases in one script,
    /// exactly as the runner hands a line to a shell.
    ///
    /// Returns what arrived and which files appeared in the folder the script ran in.
    func run(_ cases: [[ExpandedPiece]], shell: String) throws -> Outcome {
        var pieces: [ExpandedPiece] = []
        for one in cases { pieces += [.text("printf '%s\\0' ")] + one + [.text("\nprintf '\\001\\0'\n")] }
        let script = try ShellLine.script(pieces).get()
        let folder = box.url("run/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c"] + script.arguments
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var arguments: [[String]] = [[]]
        for word in String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)
            .dropLast()
        {
            if word == "\u{1}" { arguments.append([]) } else { arguments[arguments.count - 1].append(String(word)) }
        }
        return Outcome(
            arguments: Array(arguments.dropLast()),
            created: try FileManager.default.contentsOfDirectory(atPath: folder.path)
        )
    }

    /// The same bytes whatever form the test process or the shell prefers for accents.
    func same(_ a: [[String]], _ b: [[String]]) -> Bool {
        a.map { $0.map(\.decomposedStringWithCanonicalMapping) }
            == b.map { $0.map(\.decomposedStringWithCanonicalMapping) }
    }

    func protected(_ name: String) -> String { name.unicodeScalars.first == "-" ? "./" + name : name }

    /// Every template in which a placeholder may stand, with what the shell must make of it.
    static let templates: [(template: String, expected: @Sendable (String, String) -> [String])] = [
        ("%N", { _, guarded in [guarded] }),
        ("x%Ny", { name, _ in ["x" + name + "y"] }),
        ("--out=%N", { name, _ in ["--out=" + name] }),
        ("\"%N\"", { _, guarded in [guarded] }),
        ("\"pre %N post\"", { name, _ in ["pre " + name + " post"] }),
        ("'%N'", { _, guarded in [guarded] }),
        ("'pre %N post'", { name, _ in ["pre " + name + " post"] }),
        ("%P%N", { name, _ in ["/tmp/A dir/" + name] }),
        ("\"%P%N\" %N", { name, guarded in ["/tmp/A dir/" + name, guarded] }),
        ("\"$(printf '%%s' %N)\"", { _, guarded in [guarded] }),
        ("\"$(printf '%%s' \"%N\")\"", { _, guarded in [guarded] }),
        ("$(printf 'ok') %N", { _, guarded in ["ok", guarded] }),
        ("a # it's a comment\nprintf '%%s\\0' %N", { _, guarded in ["a", guarded] }),
        ("%S", { _, guarded in [guarded, "b c"] }),
        ("\"new-%S-old\"", { name, _ in ["new-" + name + "-old", "new-b c-old"] }),
        ("%|EVIL|", { _, _ in ["e'v\"\u{301}il $x `touch M18`;touch M19"] }),
        ("'%|EVIL|' \"%|EVIL|\"", { _, _ in Array(repeating: "e'v\"\u{301}il $x `touch M18`;touch M19", count: 2) })
    ]

    @Test
    func aNameIsOneArgumentAndNothingOfItRunsInAnyPlaceAndShell() throws {
        for shell in Self.shells {
            for (template, expected) in Self.templates {
                // Command substitution takes the line breaks off the end; such names are checked elsewhere.
                let names = Self.hostile.filter { !template.contains("$(printf '%%s' ") || $0.last?.isNewline != true }
                let cases = names.map { expand(template, name: $0, selection: [$0, "b c"]).pieces }
                let outcome = try run(cases, shell: shell)
                #expect(outcome.created.isEmpty, "\(shell) \(template): created \(outcome.created)")
                let wanted = names.map { expected($0, protected($0)) }
                #expect(
                    outcome.arguments.count == wanted.count,
                    "\(shell) \(template): \(outcome.arguments.count) cases"
                )
                for (index, name) in names.enumerated() where index < outcome.arguments.count {
                    #expect(
                        same([outcome.arguments[index]], [wanted[index]]),
                        "\(shell) \(template) \(name.debugDescription): got \(outcome.arguments[index].map(\.debugDescription))"
                    )
                }
            }
        }
    }

    /// Names put together from everything a shell gives a meaning to, always the same ones.
    @Test
    func namesMadeOfShellCharactersArriveUnchanged() throws {
        let parts: [String] = [
            " ", "\t", "\n", "\"", "'", "\\", "$", "`", "!", "*", "?", "[", "]", "(", ")", "{", "}", "<", ">", "|", "&",
            ";", "~", "#",
            "=", "%", "-", "\u{301}", "\u{FE0F}", "\u{A0}", "a", "touch MX", "$(", "${", "<<", "$'", "\r"
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let names = (0..<400).map { _ in (0..<(1 + next(7))).map { _ in parts[next(parts.count)] }.joined() }
        for shell in Self.shells {
            for template in ["%N", "\"a %N b\"", "'a %N b'", "x%Ny"] {
                let outcome = try run(names.map { expand(template, name: $0).pieces }, shell: shell)
                #expect(outcome.created.isEmpty, "\(shell) \(template): created \(outcome.created)")
                let wanted = names.map { name -> [String] in
                    switch template {
                    case "%N":
                        return [protected(name)]

                    case "x%Ny":
                        return ["x" + name + "y"]

                    default:
                        return ["a " + name + " b"]
                    }
                }
                #expect(same(outcome.arguments, wanted), "\(shell) \(template)")
            }
        }
    }

    @Test
    func aPlaceWhereNoReferenceIsSafeIsRefused() {
        let refused = [
            "`printf %s %N`", "\"`cmd %N`\"", "$'%N'", "echo # %N", "cat <<EOF\n%N\nEOF", "cat << 'EOF' %N", "\\%N",
            "$((%N + 1))", "echo $((1 + %N))",
            "((x = %N))", "echo $[%N]", "${x:-%N}", "echo ${x:-y} %N", "$%N", "echo \"\\%N\"",
            "echo \"$(case x in a) echo;; esac; echo %N)\"",
            // Where a shell works a value out as arithmetic, the value is read as an expression again.
            "[[ %N -eq 1 ]]", "[ 1 -lt %N ]", "test %N -ge 2 && echo", "if [[ 5 -gt \"%N\" ]]; then echo; fi",
            "echo $arr[%N]",
            "echo \"$arr[%N]\"", "echo $a1_b[1+%N]"
        ]
        for template in refused {
            let result = ShellLine.script(expand("printf %s " + template, name: "n;touch M").pieces)
            guard case .failure = result else {
                Issue.record("\(template.debugDescription) was not refused")
                continue
            }
        }
        // What only looks like one of those is run.
        for template in [
            "echo \\\\ %N", "echo $HOME %N", "echo ${HOME} %N", "echo $(date) %N", "cat <<<x %N", "(cd /; ls %N)",
            "a=1; case $a in 1) echo %N;; esac",
            "echo '#' %N", "echo a#b %N", "echo \"$(date)\" %N", "[[ -f %N ]] && echo", "[ -d %N ] || echo",
            "[[ %N == *.txt ]]",
            "[ 1 -eq 1 ]; echo %N", "[[ 1 -lt 2 ]] && echo %N", "test 1 -eq 1 && echo %N", "echo $a [%N]", "echo $1 %N"
        ] {
            guard case .success = ShellLine.script(expand(template, name: "n").pieces) else {
                Issue.record("\(template.debugDescription) was refused")
                continue
            }
        }
    }

    @Test
    func noValueIsEverPartOfTheScript() throws {
        for name in Self.hostile {
            for template in ["%N", "\"%N\"", "'%N'", "%P%N", "%S", "%|EVIL|"] {
                let script = try ShellLine.script(expand("cmd " + template, name: name, selection: [name]).pieces).get()
                // The text holds the user's words and references, and the references are all of the same harmless form.
                let withoutReferences = script.text.replacingOccurrences(
                    of: #"__afm_[0-9]+"#,
                    with: "",
                    options: .regularExpression
                )
                #expect(
                    withoutReferences.unicodeScalars.allSatisfy {
                        "cmd \"'${}=\n0123456789".unicodeScalars.contains($0)
                    },
                    "\(template) \(name.debugDescription): \(script.text.debugDescription)"
                )
                #expect(script.values.contains { $0.hasSuffix(name) || $0.contains("e'v") })
            }
        }
    }

    @Test
    func quotingOffIsTheUsersChoiceAndDataCannotMakeIt() throws {
        // %Q: the name is pasted as it is and the shell splits it, as documented.
        let off = expand("%Q%N", name: "a b")
        #expect(off.pieces == [.raw("a b")] && off.text == "a b")
        #expect(try run([off.pieces], shell: "/bin/zsh").arguments == [["a", "b"]])
        // A name that reads `%Q` is a name: handed on to another command, it is still not read for codes.
        let outer = expand("%N", name: "%Q$(touch M) %N")
        var context = context(name: "inner")
        context.argumentPieces = outer.pieces
        for inner in [
            ParameterExpander(context: context).expand(outer.pieces),
            ParameterExpander(context: context).expand("-v %A"),
            ParameterExpander(context: context).expand("%A1")
        ] {
            #expect(
                inner.pieces.contains(.value("%Q$(touch M) %N"))
                    && !inner.pieces.contains {
                        guard case .raw = $0 else {
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

    @Test
    func aValueKeepsEveryCharacter() {
        // Only blanks the user wrote go from the ends of the line.
        #expect(expand("  %N  ", name: "a\u{A0}").pieces == [.value("a\u{A0}")])
        #expect(expand("%N", name: "report\u{3000}").pieces == [.value("report\u{3000}")])
        #expect(expand("%N", name: " x ").pieces == [.value(" x ")])
        #expect(expand("ls\u{A0}", name: nil).pieces == [.text("ls\u{A0}")])
        // An empty value is a word of its own where it stands alone, and none where it is glued to text.
        #expect(expand("a %|NONE| b", name: nil).text == "a \"\" b" && expand("a%|NONE| b", name: nil).text == "a b")
        #expect(try! ShellLine.script(expand("a %|NONE| b", name: nil).pieces).get().values == [""])
    }

    @Test
    func numbersTheUserTypesNeverTrap() {
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
            CommandLanguage.steps("cm_wait 99999999999999999999, cm_wait \(huge)") { _ in nil }
                == [.wait(milliseconds: 0), .wait(milliseconds: CommandLanguage.longestWait)]
        )
    }

    @Test
    func aLeadingDashIsGuardedOnlyWhereAWordBegins() {
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

    @Test
    func listFilesRefuseNamesThatWouldBeTwoLines() {
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

    @Test
    func thePromptShowsNamesAndTakesThemBack() {
        let pieces = expand("-v %N %P%N '%N'", name: "my file.txt").pieces
        let shown = ShellLine.prompt(pieces)
        #expect(
            shown.text == "-v \"my file.txt\" \"/tmp/A dir/my file.txt\" 'my file.txt'" && shown.values.isEmpty
                && shown.legend.isEmpty
        )
        // A name a shell could read as something else is shown as the reference the shell gets.
        let hostile = "a\"\u{301};touch M;\"\u{301}"
        let guarded = ShellLine.prompt(expand("-v %N \"%N\" '%N'", name: hostile).pieces)
        // Inside the user's single quotes the quote is closed, the reference written, and the quote opened again.
        #expect(
            guarded.text == "-v \"${__afm_1}\" \"${__afm_2}\" ''\"${__afm_3}\"''"
                && guarded.values == [hostile, hostile, hostile]
        )
        #expect(guarded.legend.contains("${__afm_1} = ") && !guarded.legend.contains("\n\n"))
        // What the user makes of it: the references are the values again, the rest is the user's text.
        let edited = ShellLine.pieces(fromPrompt: "--new \"${__afm_2}\" ${__afm_9} ${__afm_x", values: guarded.values)
        #expect(edited == [.text("--new \""), .value(hostile), .text("\" ${__afm_9} ${__afm_x")])
        #expect(ShellLine.prompt(expand("%N", name: "line\nbreak").pieces).legend == "${__afm_1} = line\\nbreak")
    }

    @Test
    func textForMessagesHasNoLineBreaksOrControlCharacters() {
        #expect(DisplayText.oneLine("a\nb\rc\td\u{1B}[31m\u{202E}x\u{7}") == "a\\nb\\rc\\td\\u{1B}[31m\\u{202E}x\\u{7}")
        #expect(DisplayText.oneLine("caf\u{e9} 👨‍👩‍👧 ok") == "caf\u{e9} 👨‍👩‍👧 ok")
        #expect(
            DisplayText.oneLine(String(repeating: "x", count: 500), limit: 10) == String(repeating: "x", count: 10)
                + "…"
        )
    }

    @Test
    func aProgramGetsItsArgumentsByteForByte() async throws {
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
                    directory: box.url("run").path
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
                directory: "/"
            )
        else {
            Issue.record("a missing program was started")
            return
        }
    }
}
