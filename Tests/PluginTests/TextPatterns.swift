import AFMContracts
import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import FindFilesPlugin

/// A text to find inside files: case, escapes, whole words, block borders, encodings, hex and regular
/// expressions.
@Suite
internal struct TextPatterns {
    /// The pattern of `text`, without regard to case, with the default options.
    internal func pattern(_ text: String) throws -> TextPattern {
        try TextPattern(text, caseSensitive: false, options: TextSearchOptions())
    }

    /// The pattern of `text`, with the default options.
    internal func pattern(_ text: String, caseSensitive: Bool) throws -> TextPattern {
        try TextPattern(text, caseSensitive: caseSensitive, options: TextSearchOptions())
    }

    /// The pattern of `text` with `options`, without regard to case.
    internal func pattern(_ text: String, _ options: TextSearchOptions) throws -> TextPattern {
        try TextPattern(text, caseSensitive: false, options: options)
    }

    /// The pattern of `text` with `options`.
    internal func pattern(_ text: String, caseSensitive: Bool, _ options: TextSearchOptions) throws -> TextPattern {
        try TextPattern(text, caseSensitive: caseSensitive, options: options)
    }

    /// A plain text is found without regard to case, also outside ASCII, unless asked.
    @Test
    internal func plainTextIgnoresCaseUnlessAsked() throws {
        let data = Data("Quarterly REPORT for Ärger GmbH".utf8)
        #expect(try pattern("report").isFound(in: data))
        #expect(try !pattern("report", caseSensitive: true).isFound(in: data))
        #expect(try pattern("REPORT", caseSensitive: true).isFound(in: data))
        #expect(try pattern("ärger").isFound(in: data))
        #expect(try pattern("ÄRGER gmbh").isFound(in: data))
        #expect(try !pattern("ärger", caseSensitive: true).isFound(in: data))
    }

    /// `\t`, `\n` and `\\` stand for a tab, a line break and a backslash.
    @Test
    internal func escapesStandForTabAndLineBreak() throws {
        #expect(TextPattern.unescape("a\\tb\\nc\\\\d\\x") == "a\tb\nc\\d\\x")
        #expect(try pattern("one\\ttwo").isFound(in: Data("one\ttwo".utf8)))
        #expect(try pattern("end\\nstart").isFound(in: Data("end\nstart".utf8)))
    }

    /// Whole words are found only where no letter, digit or `_` is next to them.
    @Test
    internal func wholeWords() throws {
        let words = TextSearchOptions(wholeWords: true)
        #expect(try pattern("port", words).isFound(in: Data("the port is open".utf8)))
        #expect(try pattern("port", words).isFound(in: Data("port".utf8)))
        #expect(try pattern("port", words).isFound(in: Data("(port)".utf8)))
        #expect(try !pattern("port", words).isFound(in: Data("a report here".utf8)))
        #expect(try !pattern("port", words).isFound(in: Data("portable".utf8)))
        #expect(try !pattern("port", words).isFound(in: Data("port_2".utf8)))
        // A later occurrence counts when the first one is part of a longer word.
        #expect(try pattern("port", words).isFound(in: Data("report, port".utf8)))
    }

    /// A hit across the border of two blocks is found, with the characters around it.
    @Test
    internal func hitsAcrossBlockBordersAreFoundWithTheirSurroundings() throws {
        let text = String(repeating: "x", count: 61) + " needle " + String(repeating: "y", count: 40) + " needles"
        let words = TextSearchOptions(wholeWords: true)
        for blockSize in 1...40 {
            #expect(try pattern("NEEDLE").isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try pattern("needle", words).isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try !pattern("needl", words).isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try !pattern("eedle", words).isFound(in: Data(text.utf8), blockSize: blockSize))
            #expect(try pattern("needles", words).isFound(in: Data(text.utf8), blockSize: blockSize))
        }
    }

    /// The text is found in each chosen encoding, and in UTF-16 in both byte orders.
    @Test
    internal func encodings() throws {
        let text = "Grüße aus Köln"
        let latin = try #require(text.data(using: .windowsCP1252))
        let dos = try #require(text.data(using: TextEncoding.dos.stringEncoding))
        let little = try #require(text.data(using: .utf16LittleEndian))
        let big = try #require(text.data(using: .utf16BigEndian))
        func found(_ encoding: TextEncoding, in data: Data) throws -> Bool {
            try pattern("grüße", TextSearchOptions(encodings: [encoding])).isFound(in: data)
        }
        #expect(try found(.utf8, in: Data(text.utf8)) && !found(.utf8, in: latin) && !found(.utf8, in: little))
        #expect(try found(.western, in: latin) && !found(.western, in: Data(text.utf8)))
        #expect(try found(.dos, in: dos) && !found(.dos, in: latin))
        #expect(try found(.utf16, in: little) && found(.utf16, in: big) && !found(.utf16, in: latin))
        // Any of the ticked encodings will do.
        let all = TextSearchOptions(encodings: TextEncoding.allCases)
        for data in [Data(text.utf8), latin, dos, little, big] {
            #expect(try pattern("köln", all).isFound(in: data))
        }
        // Whole words look at whole UTF-16 units.
        let words = TextSearchOptions(wholeWords: true, encodings: [.utf16])
        #expect(try pattern("aus", words).isFound(in: little) && pattern("aus", words).isFound(in: big))
        #expect(try !pattern("au", words).isFound(in: little))
    }

    /// An encoding that cannot write the text is left out; with none left the text is refused.
    @Test
    internal func textThatAnEncodingCannotWriteDropsThatEncoding() throws {
        let both = try pattern("日本", TextSearchOptions(encodings: [.western, .utf8]))
        #expect(both.droppedEncodings == [.western])
        #expect(both.isFound(in: Data("in 日本 gewesen".utf8)))
        #expect(throws: TextPattern.Problem.notRepresentable("日本")) {
            try pattern("日本", TextSearchOptions(encodings: [.western, .dos]))
        }
        #expect(throws: TextPattern.Problem.emptyText) { try pattern("") }
    }

    /// Hex bytes with quoted text in between are found; a lowercase letter also finds the uppercase one.
    @Test
    internal func hexBytes() throws {
        let hex = TextSearchOptions(hex: true)
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0x12])
        #expect(try pattern("00 FF 12", hex).isFound(in: data))
        #expect(try pattern("00ff12", hex).isFound(in: data))
        #expect(try pattern("\"PK\"0304", caseSensitive: true, hex).isFound(in: data))
        #expect(try !pattern("00 FF 13", hex).isFound(in: data))
        // The code of a lowercase letter also finds the uppercase letter, not the other way round.
        #expect(try pattern("6B", hex).isFound(in: Data("K".utf8)) && pattern("6B", hex).isFound(in: Data("k".utf8)))
        #expect(try !pattern("6B", caseSensitive: true, hex).isFound(in: Data("K".utf8)))
        #expect(try !pattern("4B", hex).isFound(in: Data("k".utf8)))
        for broken in ["0", "0G", "\"open", "12 3"] {
            #expect(throws: TextPattern.Problem.badHex(broken)) { try pattern(broken, hex) }
        }
    }

    /// A regular expression matches line by line, `^` and `$` at the line ends.
    @Test
    internal func regularExpressionsMatchLineByLine() throws {
        let regex = TextSearchOptions(regex: true)
        let data = Data("first line\nError 42: disk full\r\nlast line".utf8)
        #expect(try pattern("^error \\d+", regex).isFound(in: data))
        #expect(try !pattern("^error \\d+", caseSensitive: true, regex).isFound(in: data))
        #expect(try pattern("full$", regex).isFound(in: data))
        #expect(try !pattern("line.+Error", regex).isFound(in: data))
        #expect(try pattern("^last", regex).isFound(in: data, blockSize: 7))
        #expect(try pattern("disk", TextSearchOptions(wholeWords: true, regex: true)).isFound(in: data))
        #expect(try !pattern("dis", TextSearchOptions(wholeWords: true, regex: true)).isFound(in: data))
        #expect(throws: TextPattern.Problem.self) { try pattern("(open", regex) }
    }

    /// A regular expression is matched in UTF-16, with or without a mark, and in the Western code page.
    @Test
    internal func regularExpressionsInOtherEncodings() throws {
        let text = "erste Zeile\nGröße: 12 cm\nEnde"
        let utf16 = TextSearchOptions(regex: true, encodings: [.utf16])
        var withMark = Data([0xFE, 0xFF])
        withMark.append(try #require(text.data(using: .utf16BigEndian)))
        #expect(
            try pattern("^größe: \\d+", utf16)
                .isFound(
                    in: try #require(text.data(using: .utf16LittleEndian)),
                    blockSize: 9
                )
        )
        #expect(try pattern("^größe: \\d+", utf16).isFound(in: withMark, blockSize: 9))
        let western = TextSearchOptions(regex: true, encodings: [.western])
        #expect(try pattern("^größe", western).isFound(in: try #require(text.data(using: .windowsCP1252))))
        #expect(try !pattern("^größe", western).isFound(in: Data(text.utf8)))
    }
}
