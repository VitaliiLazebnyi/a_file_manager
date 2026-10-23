import Foundation
import Testing

@testable import ViewerPlugin

/// Review round 2, second pass, the viewer: wide characters, the sequential scan of a giant line,
/// the limit on index builds, EUC-JP and GB 18030, printing, links, the pixel limit and a FIFO
/// that takes the place of a file.
@Suite
internal struct Review2PluginsBP2ViewerTests {
    /// How a test text is indexed: by default a UTF-8 text wrapped at words, in segments of 4 MB read
    /// in chunks of 1 MB, one after the other, with the raw scan.
    internal struct Indexing {
        /// The encoding of the bytes.
        internal var encoding: ViewerEncoding = .utf8

        /// Whether rows break at words.
        internal var wrap = true

        /// The size of a segment of the index, in bytes.
        internal var segment = 4 << 20

        /// The size of a read, in bytes.
        internal var chunk = 1 << 20

        /// Whether the segments are scanned at the same time.
        internal var parallel = false

        /// Whether the scan goes over the bytes without decoding them where it can.
        internal var raw = true

        /// The document of `data` laid out `columns` wide, its index built on the calling thread.
        internal func document(_ data: Data, columns: Int) -> TextDocument {
            let document = TextDocument(
                source: DataByteSource(data),
                encoding: encoding,
                bomLength: 0,
                layout: .text(TextLayoutOptions(columns: columns, wordWrap: wrap, tabWidth: 8)),
                reusing: nil
            )
            document.buildIndex(
                parallel: parallel,
                scanning: TextRowIndex.ScanOptions(segmentSize: segment, chunkSize: chunk, rawScan: raw)
            ) {
                // Not watched here.
            }
            return document
        }
    }

    /// A value that several threads look at.
    ///
    /// Unchecked: the state is guarded by `lock`.
    internal final class Locked<Value>: @unchecked Sendable {
        /// Guards `value`.
        private let lock = NSLock()

        /// The value itself.
        private var value: Value

        /// A box that holds `value`.
        internal init(_ value: Value) { self.value = value }

        /// Runs `body` on the value while holding the lock, and returns what it returns.
        @discardableResult
        internal func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }

        deinit {
            // Nothing to release.
        }
    }

    // MARK: A sequential scan reads a giant line once (V069)

    /// Unchecked: what it records is guarded by `lock`; its switches are set by the test before use.
    private final class CountingSource: ByteSource, @unchecked Sendable {
        let base: any ByteSource
        private let lock = NSLock()
        private var total: Int64 = 0
        var length: Int64 { base.length }
        var bytesRead: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return total
        }

        init(_ base: any ByteSource) { self.base = base }

        func read(at offset: Int64, count: Int) throws -> Data {
            let data = try base.read(at: offset, count: count)
            lock.lock()
            total += Int64(data.count)
            lock.unlock()
            return data
        }

        deinit {
            // Nothing to release.
        }
    }

    /// The text of every row of `document`, at least one.
    internal func rows(_ document: TextDocument) throws -> [String] {
        try document.rows(from: 0, count: max(1, document.rowCount), cancellation: nil).map(\.text)
    }

    // MARK: East Asian width (V035)

    /// The East Asian width table calls wide characters wide and narrow ones narrow.
    @Test
    internal func theEastAsianWidthTableKnowsWideAndNarrowCharacters() {
        for scalar: UInt32 in [
            0x1100, 0x3042, 0x4E00, 0xAC00, 0xFF21, 0xFFE0, 0x1F600, 0x20000, 0x2FFFD, 0x3000, 0x231A
        ] {
            #expect(EastAsianWidth.isWide(scalar), "U+\(String(scalar, radix: 16))")
        }
        for scalar: UInt32 in [
            0x41, 0xE9, 0x20A0, 0x0E01, 0xFF61 + 0x20, 0x1D400, 0xE000, 0x2FFFE, 0xFFE8, 0x10FFFF, 0x30, 0x300, 0xD7A4
        ] {
            if scalar == 0xFF61 + 0x20 { continue }  // U+FF81, a half-width katakana, is narrow
            #expect(!EastAsianWidth.isWide(scalar), "U+\(String(scalar, radix: 16))")
        }
        #expect(!EastAsianWidth.isWide(0xFF81))
    }

    /// Wide characters take two columns: a row holds as many as fit, and at least one.
    @Test
    internal func wideCharactersTakeTwoColumnsInTheRows() throws {
        let plain = Indexing()
        let data = Data("日本語日本語日本語\n".utf8)
        // Six columns hold three wide characters.
        #expect(try rows(plain.document(data, columns: 6)) == ["日本語", "日本語", "日本語"])
        // Odd widths: a wide character that does not fit goes to the next row.
        let five = try rows(plain.document(data, columns: 5))
        #expect(five == ["日本", "語日", "本語", "日本", "語"])
        // Mixed with narrow ones.
        #expect(try rows(Indexing(wrap: false).document(Data("ab日本語\n".utf8), columns: 5)) == ["ab日", "本語"])
        // One column holds one wide character (a row is never empty).
        #expect(try rows(plain.document(Data("日本\n".utf8), columns: 1)) == ["日", "本"])
    }

    /// A character outside the Basic Multilingual Plane is measured as one character, and a mark after a
    /// wide one adds no column.
    @Test
    internal func characterOutsideTheBasicPlaneAreMeasuredAsOneCharacter() throws {
        let plain = Indexing()
        // Emoji and U+20000 are wide; a mathematical letter is not.
        #expect(try rows(plain.document(Data("😀😀😀\n".utf8), columns: 4)) == ["😀😀", "😀"])
        #expect(
            try rows(plain.document(Data("\u{20000}\u{20000}\u{20000}\n".utf8), columns: 4)) == [
                "\u{20000}\u{20000}", "\u{20000}"
            ]
        )
        #expect(try rows(plain.document(Data("𝐀𝐀𝐀𝐀\n".utf8), columns: 2)) == ["𝐀𝐀", "𝐀𝐀"])
        // In a row of one column a wide character is past the width at once; its second half stays with it.
        #expect(try rows(plain.document(Data("😀😀\n".utf8), columns: 1)) == ["😀", "😀"])
        #expect(try rows(plain.document(Data("日\u{301}日\n".utf8), columns: 1)) == ["日\u{301}", "日"])
        // A combining mark after a wide character adds no column.
        #expect(
            try rows(plain.document(Data("日\u{301}日\u{301}日\u{301}\n".utf8), columns: 4))
                == ["日\u{301}日\u{301}", "日\u{301}"]
        )
    }

    /// Wide characters in UTF-16, either byte order, are cut into rows like those in UTF-8.
    @Test
    internal func wideCharactersInUTF16AreCutLikeThoseInUTF8() throws {
        // Four units, eight columns: the raw scan of a short line must not take it for one row of six.
        let text = "日本語日\n"
        let data = try #require(text.data(using: .utf16LittleEndian))
        #expect(try rows(Indexing(encoding: .utf16LE).document(data, columns: 6)) == ["日本語", "日"])
        let big = try #require(text.data(using: .utf16BigEndian))
        #expect(try rows(Indexing(encoding: .utf16BE).document(big, columns: 6)) == ["日本語", "日"])
    }

    /// The raw scan in small segments and the decoding scan give the same rows of random wide text.
    @Test
    internal func theFastScanAndTheDecodingScanAgreeOnWideText() throws {
        let pieces = ["a", "日", "😀", "\u{301}", "漢字", " ", "x", "é", "ｱ", "\t", "한", "𝐀"]
        var state: UInt64 = 0x1234_5678
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for round in 0..<40 {
            var text = ""
            for _ in 0..<(1 + next() % 40) {
                for _ in 0..<(next() % 30) { text += pieces[next() % pieces.count] }
                text += next().isMultiple(of: 7) ? "\r\n" : "\n"
            }
            let columns = 1 + next() % 12
            for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] {
                let data = try #require(
                    text.data(
                        using: encoding == .utf8 ? .utf8 : encoding == .utf16LE ? .utf16LittleEndian : .utf16BigEndian
                    )
                )
                let fast = Indexing(encoding: encoding, wrap: false, segment: 64, chunk: 40, raw: true)
                    .document(data, columns: columns)
                let plain = Indexing(encoding: encoding, wrap: false, raw: false).document(data, columns: columns)
                #expect(
                    fast.rowCount == plain.rowCount && fast.lineCount == plain.lineCount,
                    "round \(round) \(encoding.name) columns \(columns)"
                )
                #expect(try rows(fast) == rows(plain), "round \(round) \(encoding.name) columns \(columns)")
            }
        }
    }

    /// A sequential scan reads a line longer than many segments about once, and gives the rows of a
    /// parallel scan.
    @Test
    internal func aSequentialScanDoesNotReadAGiantLineTwice() throws {
        var data = Data(repeating: UInt8(ascii: "a"), count: 400_000)
        data.append(Data("\nsecond line\nthird\n".utf8))
        let source = CountingSource(DataByteSource(data))
        let counted = TextDocument(
            source: source,
            encoding: .utf8,
            bomLength: 0,
            layout: .text(TextLayoutOptions(columns: 80, wordWrap: true, tabWidth: 8)),
            reusing: nil
        )
        counted.buildIndex(
            parallel: false,
            scanning: TextRowIndex.ScanOptions(segmentSize: 64 << 10, chunkSize: 32 << 10, rawScan: true)
        ) {
            // Not watched here.
        }
        #expect(counted.isIndexComplete && counted.readError == nil)
        // The first segment reads the line to its end; the segments inside the line are not read at all.
        #expect(source.bytesRead < Int64(Double(data.count) * 1.25), "read \(source.bytesRead) of \(data.count)")
        let reference = Indexing(segment: 64 << 10, chunk: 32 << 10, parallel: true).document(data, columns: 80)
        #expect(counted.rowCount == reference.rowCount && counted.lineCount == reference.lineCount)
        #expect(try rows(counted) == rows(reference))
        #expect(counted.lineCount == 3 && counted.rowCount == 400_000 / 80 + 2)
    }

    /// Sequential and parallel scans give the rows of one whole pass, whatever the lines, segments
    /// and chunks.
    @Test
    internal func sequentialAndParallelScansGiveTheSameRowsWhateverTheLinesAndSegments() throws {
        var state: UInt64 = 99
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for round in 0..<30 {
            var text = ""
            for _ in 0..<(1 + next() % 12) {
                // Lines of every length, some far longer than a segment, some empty.
                let length = [0, 1, 5, 40, 300, 2_000, 9_000][next() % 7]
                for _ in 0..<length { text += ["a", "b", "日", " ", "é"][next() % 5] }
                text += ["\n", "\r\n", "\r"][next() % 3]
            }
            let data = Data(text.utf8)
            let columns = [3, 10, 80][next() % 3]
            let segment = [7, 64, 1_000, 4_096][next() % 4]
            let chunk = [16, 100, 4_096][next() % 3]
            let sequential = Indexing(segment: segment, chunk: chunk, parallel: false).document(data, columns: columns)
            let parallel = Indexing(segment: segment, chunk: chunk, parallel: true).document(data, columns: columns)
            let whole = Indexing().document(data, columns: columns)
            #expect(
                sequential.rowCount == whole.rowCount && sequential.lineCount == whole.lineCount,
                "round \(round) segment \(segment)"
            )
            #expect(
                parallel.rowCount == whole.rowCount && parallel.lineCount == whole.lineCount,
                "round \(round) segment \(segment)"
            )
            #expect(try rows(sequential) == rows(whole), "round \(round) segment \(segment) chunk \(chunk)")
        }
    }
}
