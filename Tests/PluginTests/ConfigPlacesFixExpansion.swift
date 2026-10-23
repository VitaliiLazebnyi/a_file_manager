import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ConfigurationPlugin

/// Hostile file names against the shell that runs a command line: the argv the shell builds
/// must be exactly the names, in every quoting context.
@Suite
internal struct ConfigPlacesFixExpansion {
    /// File names that break a command line that is not quoted with care.
    internal static let hostile = [
        "x'; touch pwned; '.txt", "a\"b$HOME`id`\\c.txt", "two words.txt", "line\nbreak.txt", "-rf", "!bang.txt",
        "$(id)"
    ]

    /// The panels `/tmp/A dir/` (cursor on `name`) and `/B/`, with an environment that needs quoting.
    internal func context(name: String?) -> ExpansionContext {
        ExpansionContext(
            left: PanelSnapshot(path: "/tmp/A dir/", cursorName: name, selection: []),
            right: PanelSnapshot(path: "/B/", cursorName: nil),
            environment: ["EVIL": "e'v\"il $x `y`", "PLAIN": "/Users/me"],
            listFolder: URL(fileURLWithPath: "/tmp/lists"),
            listName: "t"
        )
    }

    /// The words /bin/zsh makes of `printf '%s\n' <line>`, separated by NUL for printing.
    internal func argv(_ line: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "cd /tmp && printf '%s\\0' " + line]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = try #require(String(bytes: data, encoding: .utf8))
        return output.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// `text` expanded with the cursor on `name`.
    internal func expand(_ text: String, name: String?) -> ExpandedParameters {
        ParameterExpander(context: context(name: name)).expand(text)
    }

    /// A placeholder outside quotes becomes one word, a leading dash behind `./`.
    @Test
    internal func unquotedPlaceholderIsOneWord() throws {
        for name in Self.hostile {
            let expanded = expand("%N", name: name).text
            let words = try argv(expanded)
            #expect(words == [name.hasPrefix("-") ? "./" + name : name], "\(name) -> \(expanded)")
            let path = try argv(expand("%P%N", name: name).text)
            #expect(path == ["/tmp/A dir/" + name])
        }
    }

    /// A placeholder inside double quotes stays the name, also next to other text.
    @Test
    internal func insideDoubleQuotes() throws {
        for name in Self.hostile {
            let expanded = expand("\"%N\"", name: name).text
            #expect(try argv(expanded) == [name.hasPrefix("-") ? "./" + name : name], "\(name) -> \(expanded)")
            #expect(try argv(expand("\"x%Ny\"", name: name).text) == ["x" + name + "y"])
        }
    }

    /// A placeholder inside single quotes stays the name, and quotes the user escaped are tracked.
    @Test
    internal func insideSingleQuotes() throws {
        for name in Self.hostile {
            let expanded = expand("'%N'", name: name).text
            #expect(try argv(expanded) == [name.hasPrefix("-") ? "./" + name : name], "\(name) -> \(expanded)")
            #expect(try argv(expand("'<%P%N>'", name: name).text) == ["</tmp/A dir/" + name + ">"])
        }
        // A backslash and an escaped quote the user wrote do not confuse the tracking.
        #expect(try argv(expand("\\\" '%N'", name: "a'b").text) == ["\"", "a'b"])
        #expect(try argv(expand("\"it's %N\"", name: "a'b").text) == ["it's a'b"])
    }

    /// Environment values are quoted like names, in every quoting context.
    @Test
    internal func environmentValuesAreQuotedToo() throws {
        #expect(try argv(expand("%|EVIL|", name: nil).text) == ["e'v\"il $x `y`"])
        #expect(try argv(expand("'%|EVIL|'", name: nil).text) == ["e'v\"il $x `y`"])
        #expect(try argv(expand("\"%|EVIL|\"", name: nil).text) == ["e'v\"il $x `y`"])
        #expect(expand("%|PLAIN|/x", name: nil).text == "/Users/me/x")
        #expect(
            try argv(CommandLanguage.expandingEnvironment("a %EVIL% '%EVIL%' \"%EVIL%\"", ["EVIL": "e'v\"il $x `y`"]))
                == ["a", "e'v\"il $x `y`", "e'v\"il $x `y`", "e'v\"il $x `y`"]
        )
    }

    /// Each selected name is a word of its own.
    @Test
    internal func selectedNamesAreSeparateWords() throws {
        var context = context(name: nil)
        context.left.selection = ["-n", "b c", "d'e"]
        let text = ParameterExpander(context: context).expand("%S").text
        #expect(try argv(text) == ["./-n", "b c", "d'e"])
    }

    /// A placeholder that needs the name under the cursor reports when there is none.
    @Test
    internal func aMissingNameIsReported() {
        #expect(expand("rm -rf %P%N", name: nil).missingName)
        #expect(
            expand("echo %V", name: nil).missingName && expand("%O.%E", name: nil).missingName
                && expand("%M", name: "x").missingName
        )
        #expect(!expand("rm %P%N", name: "a").missingName && !expand("ls %P %S", name: nil).missingName)
    }
}
