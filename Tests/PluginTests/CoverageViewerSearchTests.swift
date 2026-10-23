import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// Search patterns and searching, in the cases the other tests leave out.
@Suite
internal struct CoverageViewerSearchTests {
    private static func find(
        _ text: String,
        _ options: SearchOptions,
        in source: any ByteSource,
        encoding: ViewerEncoding = .utf8
    ) throws -> Range<Int64>? {
        let pattern = try SearchPattern(text, options: options, encoding: encoding)
        return try ViewerSearch.find(
            ViewerSearch.Request(pattern: pattern, start: 0, backwards: options.backwards),
            in: ViewerSearch.Subject(source: source, content: 0..<source.length, encoding: encoding, boundaries: nil),
            tuning: .standard,
            cancellation: CancellationFlag()
        ) { _ in
            // No progress to show.
        }
    }

    private static func utf16(_ text: String) -> Data {
        Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    // MARK: Search patterns

    /// The errors of a pattern say what is wrong.
    @Test
    internal func patternErrorsExplainThemselves() {
        #expect(SearchError.empty.errorDescription == "There is nothing to search for.")
        #expect(SearchError.badExpression("x").errorDescription == "The regular expression cannot be used: x")
    }

    /// A backslash before anything else, or at the end, is itself.
    @Test
    internal func otherBackslashesStayAsTheyAre() {
        #expect(SearchPattern.unescape("a\\x") == "a\\x")
        #expect(SearchPattern.unescape("a\\") == "a\\")
    }

    /// Hex strings with a nibble left over before quoted text or a space, an unclosed quote, or
    /// text the encoding cannot write, are refused.
    @Test
    internal func malformedHexStringsAreRefused() {
        for text in ["1\"A\"", "\"PK", "1 2", "\"€\""] {
            #expect(throws: SearchError.badHex(text)) { try SearchPattern.hexBytes(text, encoding: .dos) }
        }
    }

    // MARK: Searching

    /// A regular expression can be limited to whole words.
    @Test
    internal func regularExpressionsFindWholeWords() throws {
        var options = SearchOptions()
        options.regex = true
        options.wholeWords = true
        let source = DataByteSource(Data("concat cat".utf8))
        #expect(try Self.find("c.t", options, in: source) == 7..<10)
    }

    /// A text that is gone when it is searched has no match, whichever way it is searched.
    @Test
    internal func aTextThatIsGoneHasNoMatches() throws {
        let gone = CoverageViewerShortSource(length: 1_000, available: 0)
        #expect(try Self.find("word", SearchOptions(), in: gone) == nil)
        #expect(try Self.find("wörd", SearchOptions(), in: gone) == nil)
        #expect(try Self.find("word", SearchOptions(), in: gone, encoding: .utf16LE) == nil)
        var exact = SearchOptions()
        exact.caseSensitive = true
        #expect(try Self.find("word", exact, in: gone) == nil)
    }

    /// A needle longer than the whole text is not found in it.
    @Test
    internal func aNeedleLongerThanTheTextIsNotFound() throws {
        var exact = SearchOptions()
        exact.caseSensitive = true
        #expect(try Self.find("abc", SearchOptions(), in: DataByteSource(Data("ab".utf8))) == nil)
        #expect(try Self.find("abcdef", exact, in: DataByteSource(Self.utf16("abc")), encoding: .utf16LE) == nil)
    }

    /// Characters beyond the Basic Multilingual Plane match themselves when the case is ignored.
    @Test
    internal func pairsMatchThemselvesWithoutCase() throws {
        let data = Data("a😀x".utf8)
        #expect(try Self.find("😀X", SearchOptions(), in: DataByteSource(data)) == 1..<6)
    }

    /// Whole words in raw UTF-8: an emoji is no letter, an accented letter is.
    @Test
    internal func wholeWordsLookAtTheCharactersAround() throws {
        var options = SearchOptions()
        options.wholeWords = true
        #expect(try Self.find("word", options, in: DataByteSource(Data("😀word".utf8))) == 4..<8)
        #expect(try Self.find("word", options, in: DataByteSource(Data("éword".utf8))) == nil)
        #expect(try Self.find("word", options, in: DataByteSource(Data("wordé".utf8))) == nil)
    }

    /// A match outside the bytes a search accepts is not taken.
    @Test
    internal func matchesOutsideTheAcceptedBytesAreLeft() {
        #expect(ViewerSearch.bytes([0x41], in: Data("xxA".utf8), base: 0, accepted: 0..<1, last: false) == nil)
        #expect(ViewerSearch.bytes([], in: Data("xxA".utf8), base: 0, accepted: 0..<3, last: false) == nil)
    }
}
