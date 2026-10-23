import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import FindFilesPlugin

/// Text patterns and the local reader at their edges.
extension CoverageFindModel {
    /// Counts calls.
    ///
    /// Unchecked: the count is guarded by `lock`.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// Counts one more call and returns the count.
        func next() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A reader whose every read fails.
    private final class FailingReader: FileReader, @unchecked Sendable {
        func read(upToCount _: Int) throws -> Data? { throw CocoaError(.fileReadUnknown) }

        func seek(to _: UInt64) throws { throw CocoaError(.fileReadUnknown) }

        func close() {
            // Nothing to close.
        }

        deinit {
            // Nothing to release.
        }
    }

    // MARK: Text patterns

    /// The problems of a text say what is wrong with it.
    @Test
    internal func problemsSayWhatIsWrong() {
        #expect(TextPattern.Problem.emptyText.errorDescription == "There is no text to find.")
        #expect(TextPattern.Problem.badRegex("x").errorDescription == "The regular expression cannot be used: x")
        #expect(
            TextPattern.Problem.notRepresentable("€").errorDescription
                == "\"€\" cannot be written in any of the chosen encodings."
        )
        #expect(TextEncoding.utf16.stringEncoding == .utf16LittleEndian)
    }

    /// No encoding chosen means UTF-8, and encodings that write the text alike count once.
    @Test
    internal func noEncodingChosenMeansUTF8AndRepeatedNeedlesAreOne() throws {
        var options = TextSearchOptions()
        options.encodings = []
        #expect(try TextPattern("abc", options: options).isFound(in: Data("xabcx".utf8)))
        options.encodings = [.utf8, .western]
        #expect(try TextPattern("abc", options: options).isFound(in: Data("xabcx".utf8)))
    }

    /// A trailing backslash and an unknown escape stay as they are.
    @Test
    internal func aTrailingBackslashStays() {
        #expect(TextPattern.unescape("a\\") == "a\\" && TextPattern.unescape("a\\q") == "a\\q")
    }

    /// Hex digits come in pairs, also before a quoted text.
    @Test
    internal func hexDigitsMustComeInPairs() {
        var options = TextSearchOptions()
        options.hex = true
        #expect(throws: TextPattern.Problem.badHex("0\"A\"")) { try TextPattern("0\"A\"", options: options) }
        #expect(throws: TextPattern.Problem.badHex("0 1")) { try TextPattern("0 1", options: options) }
    }

    /// A whole word that goes on is no hit; the case forms of a letter of two lengths are both tried.
    @Test
    internal func aWholeWordThatGoesOnIsNoHit() throws {
        var options = TextSearchOptions()
        options.wholeWords = true
        #expect(try !TextPattern("ab", options: options).isFound(in: Data("abc".utf8)))
        // Upper and lower case both count, and a long s is written in two bytes or as an S in one:
        // the longer way runs off the end of the file, the shorter one is found.
        #expect(try TextPattern("a\u{17F}").isFound(in: Data("xaS".utf8)))
    }

    /// A cancelled search finds nothing, by bytes or by expression.
    @Test
    internal func aCancelledSearchFindsNothing() throws {
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let reader = TextPattern.DataReader(Data("abc".utf8))
        #expect(try !TextPattern("b").isFound(in: reader, cancellation: cancellation))
        var options = TextSearchOptions()
        options.regex = true
        let regexReader = TextPattern.DataReader(Data("abc".utf8))
        #expect(try !TextPattern("b", options: options).isFound(in: regexReader, cancellation: cancellation))
    }

    /// A file that cannot be read holds no text, and never passes "NOT containing".
    @Test
    internal func aReaderThatFailsFindsNothing() throws {
        #expect(try !TextPattern("b").isFound(in: FailingReader()))
        var options = TextSearchOptions()
        options.regex = true
        #expect(try !TextPattern("b", options: options).isFound(in: FailingReader()))
        // NOT containing: a file that cannot be read never passes.
        options = TextSearchOptions()
        options.notContaining = true
        #expect(try !TextPattern("b", options: options).accepts(FailingReader()))
    }

    /// After a few files the expression took too long for, it is not tried on others.
    @Test
    internal func aTrippedExpressionGivesUpOnTheFile() throws {
        var options = TextSearchOptions()
        options.regex = true
        let pattern = try TextPattern("(a*)*b", options: options)
        // Every piece takes the expression too long: after three files it is not tried again.
        let long = Data((String(repeating: "a", count: 40) + "\n").utf8)
        for _ in 0..<4 {
            #expect(!pattern.isFound(in: long))
        }
        #expect(!pattern.accepts(TextPattern.DataReader(long)))
    }

    /// Lines longer than a piece are cut between characters, in every encoding.
    @Test
    internal func longLinesAreCutBetweenCharacters() throws {
        var options = TextSearchOptions()
        options.regex = true
        let longest = 4 << 20
        for tail in ["\u{1F600}", "\u{20AC}", "\u{E9}", "a"] {
            // A line longer than the longest, ending in the middle of its last character.
            var data = Data(repeating: 0x61, count: longest)
            let bytes = Array(tail.utf8)
            data.append(contentsOf: bytes.count > 1 ? bytes.dropLast() : bytes)
            #expect(try TextPattern(".", options: options).isFound(in: data, blockSize: longest + 8))
        }
        options.encodings = [.utf16]
        let wide = Data(repeating: 0x61, count: longest + 8)
        #expect(try TextPattern(".", options: options).isFound(in: wide, blockSize: longest + 16))
        // A byte the Western code page does not have is read as Latin-1. It comes first: an
        // expression that has to go through the 4 MB of a piece before it finds anything may
        // use up the time a piece is given (in a build for the thread sanitizer, with other
        // tests running, it did) and then counts as not found.
        options.encodings = [.western]
        var western = Data([0x81])
        western.append(Data(repeating: 0x61, count: longest + 8))
        #expect(try TextPattern("\\x81", options: options).isFound(in: western, blockSize: longest + 16))
    }

    /// An empty file holds no text.
    @Test
    internal func anEmptyFileHoldsNoText() throws {
        #expect(try !TextPattern("a").isFound(in: Data()))
    }

    /// The reader over data seeks, stops at the end and closes.
    @Test
    internal func theDataReaderSeeksAndCloses() {
        let reader = TextPattern.DataReader(Data("abcdef".utf8))
        reader.seek(to: 4)
        #expect(reader.read(upToCount: 10) == Data("ef".utf8))
        reader.seek(to: 99)
        #expect(reader.read(upToCount: 10) == nil)
        reader.close()
    }

    // MARK: The local reader

    /// The local reader opens plain local files only, seeks, and fails once closed.
    @Test
    internal func aLocalReaderOnlyReadsPlainFilesHere() throws {
        #expect(LocalFileReader.open(memory.url("/a")) == nil)
        #expect(FileIdentity.canBeRead(memory.url("/a")) && !FileIdentity.canBeRead(box.url("gone")))
        let file = try box.file("a.txt", "abcdef")
        let reader = try #require(LocalFileReader.open(file))
        #expect(try reader.read(upToCount: 0) == nil)
        try reader.seek(to: 2)
        #expect(try reader.read(upToCount: 2) == Data("cd".utf8))
        reader.interrupt()
        #expect(throws: CocoaError.self) { try reader.seek(to: UInt64.max) }
        reader.close()
        #expect(throws: CocoaError.self) { try reader.read(upToCount: 1) }
        #expect(throws: CocoaError.self) { try reader.seek(to: 0) }
    }

    /// A read cut short by a signal is tried again; a failed one is reported with its error.
    @Test
    internal func anInterruptedReadIsTriedAgainAndAFailedOneReported() throws {
        let file = try box.file("b.txt", "abc")
        let calls = Calls()
        let interrupted = try #require(
            LocalFileReader.open(file) { descriptor, buffer, count in
                guard calls.next() > 1 else {
                    errno = EINTR
                    return -1
                }
                return Darwin.read(descriptor, buffer, count)
            }
        )
        #expect(try interrupted.read(upToCount: 10) == Data("abc".utf8))
        let failing = try #require(
            LocalFileReader.open(file) { _, _, _ in
                errno = EIO
                return -1
            }
        )
        #expect(throws: POSIXError.self) { try failing.read(upToCount: 10) }
        let unknown = try #require(
            LocalFileReader.open(file) { _, _, _ in
                errno = 9_999
                return -1
            }
        )
        #expect(throws: POSIXError(.EIO)) { try unknown.read(upToCount: 10) }
    }
}
