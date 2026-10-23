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
internal struct Review2ConfigAShellTests {
    /// What a script of cases did.
    internal struct Outcome {
        /// The arguments of each case, as the shell made them.
        internal var arguments: [[String]]
        /// The names of the files that appeared in the folder the script ran in.
        internal var created: [String]
    }

    /// The shells a line may be handed to.
    internal static let shells = ["/bin/zsh", "/bin/sh"]

    /// Names that ran commands before, and their relatives.
    ///
    /// The marks after a quote, a backtick, a backslash and a dollar sign are U+0301: one
    /// `Character` with what they follow.
    internal static let hostile: [String] = [
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

    /// Every template in which a placeholder may stand, with what the shell must make of it.
    internal static let templates: [(template: String, expected: @Sendable (String, String) -> [String])] = [
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

    /// The folder `run`, in which every script runs in a folder of its own, and the list folder.
    internal let box: Sandbox

    /// The folders of the test.
    internal init() throws {
        box = try Sandbox()
        try box.folder("run")
    }

    /// The panels `/tmp/A dir/` (cursor on `name`, `selection` marked) and `/B/`, with a hostile variable `EVIL`.
    internal func context(name: String?, selection: [String]) -> ExpansionContext {
        ExpansionContext(
            left: PanelSnapshot(path: "/tmp/A dir/", cursorName: name, selection: selection),
            right: PanelSnapshot(path: "/B/", cursorName: nil),
            environment: ["EVIL": "e'v\"\u{301}il $x `touch M18`;touch M19"],
            listFolder: box.url("lists"),
            listName: "t"
        )
    }

    /// `template` expanded with the cursor on `name` and nothing marked.
    internal func expand(_ template: String, name: String?) -> ExpandedParameters {
        expand(template, name: name, selection: [])
    }

    /// `template` expanded with the cursor on `name` and `selection` marked.
    internal func expand(_ template: String, name: String?, selection: [String]) -> ExpandedParameters {
        ParameterExpander(context: context(name: name, selection: selection)).expand(template)
    }

    /// Runs `printf` with the pieces of every case as its arguments, all cases in one script,
    /// exactly as the runner hands a line to a shell.
    ///
    /// Returns what arrived and which files appeared in the folder the script ran in.
    internal func run(_ cases: [[ExpandedPiece]], shell: String) throws -> Outcome {
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
        let output = try #require(String(bytes: data, encoding: .utf8))
        for word in output.split(separator: "\0", omittingEmptySubsequences: false).dropLast() {
            if word == "\u{1}" { arguments.append([]) } else { arguments[arguments.count - 1].append(String(word)) }
        }
        return Outcome(
            arguments: Array(arguments.dropLast()),
            created: try FileManager.default.contentsOfDirectory(atPath: folder.path)
        )
    }

    /// The same bytes whatever form the test process or the shell prefers for accents.
    internal func same(_ got: [[String]], _ wanted: [[String]]) -> Bool {
        got.map { $0.map(\.decomposedStringWithCanonicalMapping) }
            == wanted.map { $0.map(\.decomposedStringWithCanonicalMapping) }
    }

    /// `name` as it must reach a program: behind `./` when it begins with a dash.
    internal func protected(_ name: String) -> String { name.unicodeScalars.first == "-" ? "./" + name : name }

    /// Every hostile name is one argument and runs nothing, in every template and both shells.
    @Test
    internal func aNameIsOneArgumentAndNothingOfItRunsInAnyPlaceAndShell() throws {
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
                    let got = outcome.arguments[index].map(\.debugDescription)
                    #expect(
                        same([outcome.arguments[index]], [wanted[index]]),
                        "\(shell) \(template) \(name.debugDescription): got \(got)"
                    )
                }
            }
        }
    }

    /// Names put together from everything a shell gives a meaning to, always the same ones.
    @Test
    internal func namesMadeOfShellCharactersArriveUnchanged() throws {
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

    /// A placeholder where no reference to a value is safe is refused; what only looks like such a place is run.
    @Test
    internal func aPlaceWhereNoReferenceIsSafeIsRefused() {
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

    /// No value is ever part of the script's text, only references to it.
    @Test
    internal func noValueIsEverPartOfTheScript() throws {
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
                    withoutReferences.unicodeScalars.allSatisfy { scalar in
                        "cmd \"'${}=\n0123456789".unicodeScalars.contains(scalar)
                    },
                    "\(template) \(name.debugDescription): \(script.text.debugDescription)"
                )
                #expect(script.values.contains { $0.hasSuffix(name) || $0.contains("e'v") })
            }
        }
    }
}
