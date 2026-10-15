import Foundation
import Testing

@testable import ConfigurationPlugin

/// The placeholders of a Parameters field at the corners the other suites leave.
@Suite internal struct CovConfigExpansion {
    private let context = ExpansionContext(
        left: PanelSnapshot(path: "/L/", cursorName: "cur.txt", selection: ["a.txt", "b.txt"]),
        right: PanelSnapshot(path: "/R/", cursorName: "other.md"),
        listFolder: URL(fileURLWithPath: "/tmp/lists"),
        listName: "test"
    )

    private func expand(_ text: String, _ change: (inout ExpansionContext) -> Void = { _ in }) -> ExpandedParameters {
        var context = context
        change(&context)
        return ParameterExpander(context: context).expand(text)
    }

    private func expand(
        _ pieces: [ExpandedPiece],
        _ change: (inout ExpansionContext) -> Void = { _ in }
    ) -> ExpandedParameters {
        var context = context
        change(&context)
        return ParameterExpander(context: context).expand(pieces)
    }

    private static let nothingMarked: @Sendable (inout ExpansionContext) -> Void = { $0.left.selection = [] }
    private static let nothingAtAll: @Sendable (inout ExpansionContext) -> Void = {
        $0.left.selection = []
        $0.left.cursorName = nil
    }

    /// A context and a result made without the optional parts have their defaults.
    @Test
    internal func theDefaultsOfAContextAndAResult() {
        let bare = ExpansionContext(left: PanelSnapshot(path: "/"), right: PanelSnapshot(path: "/"))
        #expect(bare.listFolder == FileManager.default.temporaryDirectory && !bare.sourceIsRight)
        let empty = ExpandedParameters()
        #expect(empty.pieces.isEmpty && !empty.asksFirst && !empty.usedArguments && !empty.missingName)
        #expect(empty.text.isEmpty && empty.listFile == nil && empty.problem == nil)
    }

    /// Symbols, punctuation and spaces of other scripts are quoted; letters and marks are not.
    @Test
    internal func otherScriptsAreQuotedButTheirLettersAreNot() {
        #expect(ShellWords.needsQuoting("price€") && ShellWords.needsQuoting("a\u{3000}b"))
        #expect(!ShellWords.needsQuoting("café") && !ShellWords.needsQuoting("名前"))
    }

    /// Splitting keeps escaped quotes inside a quoted word, drops empty words between blanks
    /// and keeps empty fields between other separators.
    @Test
    internal func splittingAtBlanksAndOtherSeparators() {
        #expect(ShellWords.split("a \"b\\\" c\" d") == ["a", "\"b\\\" c\"", "d"])
        #expect(ShellWords.split("a  b ") == ["a", "b"])
        #expect(ShellWords.split("a,,b,", at: ",") == ["a", "", "b", ""])
        #expect(ShellWords.split("", at: ",").isEmpty)
        // An expanded text: an escaped quote inside quotes does not end them.
        let words = ShellWords.split([.text("x \"y\\\" z\" "), .value("v")])
        #expect(words == [[.text("x")], [.text("\"y\\\" z\"")], [.value("v")]])
        let first = ShellWords.firstWord(of: [.text("\"a\\\" b\" rest")])
        #expect(first.word == [.text("\"a\\\" b\"")] && first.rest == [.text(" rest")])
    }

    /// Unquoting keeps a backslash before a character a double quote does not escape.
    @Test
    internal func unquotingKeepsBackslashesThatEscapeNothing() {
        #expect(ShellWords.unquoted("\"a\\b\\$c\"") == "a\\b$c")
    }

    /// A raw piece of an earlier expansion is passed on as it is.
    @Test
    internal func aRawPieceIsPassedOn() {
        #expect(expand([.text("echo "), .raw("a b")]).pieces == [.text("echo "), .raw("a b")])
    }

    /// `:~start,` without a length is no length; the comma is text again.
    @Test
    internal func aSubstringWithoutItsLengthKeepsTheComma() {
        #expect(expand("%N:~1,x").text == "ur.txt,x")
    }

    /// `%Y` alone makes `%S` stand for nothing without marks; with `%y` it falls back to the
    /// cursor, and a list is dropped only without a name under the cursor.
    @Test
    internal func theEmptySelectionModifiers() {
        #expect(expand("ls %Y%S", Self.nothingMarked).text == "ls")
        #expect(expand("ls %Y%y%S", Self.nothingMarked).text == "ls cur.txt")
        #expect(expand("ls %Y%y%S", Self.nothingAtAll).text == "ls")
        #expect(expand("ls %y%S", Self.nothingMarked).text == "ls cur.txt")
        #expect(expand("ls %y%S", Self.nothingAtAll).text == "ls")
        #expect(expand("%Y%y%L", Self.nothingMarked).listFile?.contents == Data("/L/cur.txt\n".utf8))
        #expect(expand("%Y%y%L", Self.nothingAtAll).listFile == nil)
        #expect(expand("%y%L", Self.nothingMarked).listFile == nil)
        #expect(expand("%Y%L", Self.nothingMarked).listFile?.contents == Data())
    }

    /// Inside the user's quotes a value of an earlier expansion after `%S` is repeated for every name.
    @Test
    internal func aValueAfterTheNamesInsideQuotesIsRepeated() {
        let result = expand([.text("cp \"%S"), .value("!"), .text("x\"")])
        #expect(result.text == "cp \"a.txt!x\" \"b.txt!x\"")
    }

    /// With `%E` inside the user's quotes, a name at the start of the quote is protected and
    /// one after other text is not.
    @Test
    internal func namesWithExtensionAffixesInsideQuotes() {
        #expect(expand("mv \"%S.bak%E\"").text == "mv \"a.bak.txt\" \"b.bak.txt\"")
        let dashed: (inout ExpansionContext) -> Void = { $0.left.selection = ["-n.txt"] }
        #expect(expand("mv \"%S.bak%E\"", dashed).text == "mv \"./-n.bak.txt\"")
        #expect(expand("mv \"x%S%E\"", dashed).text == "mv \"x-n.txt\"")
    }

    /// `%U` and `%W` without `L` or `F` are text.
    @Test
    internal func unicodeListCodesWithoutAKindAreText() {
        #expect(expand("%Ux %W").text == "%Ux %W")
    }

    /// A UTF-16 list begins with its mark and holds the names little-endian.
    @Test
    internal func aUTF16ListIsLittleEndianWithAMark() {
        let contents = expand("%WL", Self.nothingMarked).listFile?.contents
        #expect(
            contents == Data([0xFF, 0xFE]) + Data("/L/cur.txt\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        )
    }

    /// `%C1` and `%C2` without any name are empty.
    @Test
    internal func comparedFilesWithoutNamesAreEmpty() {
        let none: (inout ExpansionContext) -> Void = {
            $0.left = PanelSnapshot(path: "/L/")
            $0.right = PanelSnapshot(path: "/R/")
        }
        let result = expand("%C1 %C2", none)
        #expect(result.pieces == [.value(""), .text(" "), .value("")])
        // Without a digit from 1 to 9 the code is text.
        #expect(expand("%C0 %Cx").text == "%C0 %Cx")
        // A list of nothing, without a modifier, is an empty list.
        #expect(expand("%L", Self.nothingAtAll).listFile?.contents == Data())
    }
}
