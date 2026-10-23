import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// The viewer's search without any window: plain text, hex and regular expressions, in several encodings and
/// across chunk borders.
@Suite
internal struct ViewerModelSearchTests {
    /// The first place the viewer's search finds `text` in the bytes from `start` on (or before it, backwards).
    private func find(
        _ text: String,
        _ options: SearchOptions,
        in data: Data,
        from start: Int64 = 0,
        encoding: ViewerEncoding = .utf8,
        chunk: Int = 1 << 20
    ) throws -> Range<Int64>? {
        let pattern = try SearchPattern(text, options: options, encoding: encoding)
        var tuning = ViewerSearch.Tuning.standard
        tuning.chunkSize = chunk
        return try ViewerSearch.find(
            ViewerSearch.Request(pattern: pattern, start: start, backwards: options.backwards),
            in: ViewerSearch.Subject(
                source: DataByteSource(data),
                content: 0..<Int64(data.count),
                encoding: encoding,
                boundaries: nil
            ),
            tuning: tuning,
            cancellation: CancellationFlag()
        ) { _ in
            // Not watched here.
        }
    }

    // MARK: Search

    /// Plain text is found with whole words, case and direction, and with `\n`, `\t` and `\\` escapes.
    @Test
    internal func plainTextSearchWithItsSwitches() throws {
        let data = Data("The manager met a man. MAN overboard! Tab\there.\r\nNext line\nback\\slash".utf8)
        #expect(try find("man", SearchOptions(), in: data) == 4..<7)
        #expect(try find("man", SearchOptions(wholeWords: true), in: data) == 18..<21)
        #expect(try find("MAN", SearchOptions(caseSensitive: true), in: data) == 23..<26)
        #expect(try find("man", SearchOptions(), in: data, from: 5) == 18..<21)
        #expect(try find("man", SearchOptions(backwards: true), in: data, from: Int64(data.count)) == 23..<26)
        #expect(try find("man", SearchOptions(backwards: true), in: data, from: 23) == 18..<21)
        #expect(try find("man", SearchOptions(wholeWords: true, backwards: true), in: data, from: 18) == nil)
        #expect(try find("Tab\\there", SearchOptions(), in: data) == 38..<46)
        // `\n` finds a line end of either kind; `\\` one backslash.
        #expect(try find("here.\\nnext", SearchOptions(), in: data) == 42..<53)
        #expect(try find("line\\nback\\\\slash", SearchOptions(), in: data) == 54..<69)
        #expect(try find("absent", SearchOptions(), in: data) == nil)
        #expect(throws: SearchError.empty) { try find("", SearchOptions(), in: data) }
    }

    /// A hex search takes bytes and quoted text, forward and backward, and rejects what is no hex.
    @Test
    internal func hexSearchTakesBytesAndQuotedText() throws {
        let data = Data([0x00, 0x50, 0x4B, 0x01, 0x02, 0xFF, 0x50, 0x4B, 0x03, 0x04])
        let hex = SearchOptions(hex: true)
        #expect(try find("01 02 FF", hex, in: data) == 3..<6)
        #expect(try find("\"PK\"0304", hex, in: data) == 6..<10)
        #expect(try find("\"PK\"", hex, in: data, from: 2) == 6..<8)
        #expect(try find("504b", SearchOptions(backwards: true, hex: true), in: data, from: 10) == 6..<8)
        #expect(try find("504b", SearchOptions(backwards: true, hex: true), in: data, from: 6) == 1..<3)
        #expect(try find("AA", hex, in: data) == nil)
        #expect(throws: SearchError.self) { try find("0G", hex, in: data) }
        #expect(throws: SearchError.self) { try find("012", hex, in: data) }
        #expect(try SearchPattern.hexBytes("\"é\"0A", encoding: .ansi) == [0xE9, 0x0A])
    }

    /// Regular expressions are found with anchors, case and direction, and a broken one is an error.
    @Test
    internal func regularExpressions() throws {
        let data = Data("id=17; id=2048\nname = Smith\nNAME = Jones".utf8)
        let regex = SearchOptions(regex: true)
        #expect(try find("id=\\d{3,}", regex, in: data) == 7..<14)
        #expect(try find("^name\\s*=\\s*\\w+$", regex, in: data) == 15..<27)
        #expect(
            try find(
                "^name",
                SearchOptions(caseSensitive: true, backwards: true, regex: true),
                in: data,
                from: Int64(data.count)
            ) == 15..<19
        )
        #expect(
            try find("^name", SearchOptions(backwards: true, regex: true), in: data, from: Int64(data.count)) == 28..<32
        )
        #expect(throws: SearchError.self) { try find("(unclosed", regex, in: data) }
    }

    /// A search in UTF-16, DOS or UTF-8 gives the byte range of what it found, from any offset.
    @Test
    internal func searchingInOtherEncodingsGivesByteRanges() throws {
        let text = "Zeile eins\r\nGrößenwahn und Ärger"
        let wide = Data(try ViewerEncoding.utf16LE.encode(text))
        #expect(try find("größenwahn", SearchOptions(), in: wide, encoding: .utf16LE) == 24..<44)
        #expect(
            try find("ärger", SearchOptions(backwards: true), in: wide, from: Int64(wide.count), encoding: .utf16LE)
                == 54..<64
        )
        // From an odd offset the search still reads whole code units.
        #expect(try find("und", SearchOptions(), in: wide, from: 25, encoding: .utf16LE) == 46..<52)
        let dos = Data(try ViewerEncoding.dos.encode(text))
        #expect(try find("Größe", SearchOptions(caseSensitive: true), in: dos, encoding: .dos) == 12..<17)
        let utf8 = Data(text.utf8)
        #expect(try find("ärger", SearchOptions(), in: utf8) == 29..<35)
    }

    /// Plain, regular expression and hex matches across chunk borders are found in both directions.
    @Test(arguments: [false, true])
    internal func matchesAcrossChunkBordersAreFound(backwards: Bool) throws {
        // Chunks of 64 bytes: the needle lies across the border at 4096 and, in UTF-8, the
        // border even splits a character of it.
        var text = String(repeating: "abcdefg ", count: 511) + "abc Grüße aus Köln, 日本 "
        text += String(repeating: "hijklmn ", count: 300)
        let data = Data(text.utf8)
        let expected = try #require(text.range(of: "Grüße aus Köln, 日本"))
        let range =
            Int64(
                text.utf8.distance(from: text.startIndex, to: expected.lowerBound)
            )..<Int64(
                text.utf8.distance(from: text.startIndex, to: expected.upperBound)
            )
        let start = backwards ? Int64(data.count) : 0
        let wide = Data(try ViewerEncoding.utf16LE.encode(text))
        for chunk in [64, 100, 4_096, 1 << 20] {
            // The UTF-8 text from its start or end, in chunks of this size.
            func search(_ needle: String, _ options: SearchOptions) throws -> Range<Int64>? {
                var directed = options
                directed.backwards = backwards
                return try find(needle, directed, in: data, from: start, chunk: chunk)
            }
            #expect(try search("grüße aus köln, 日本", SearchOptions()) == range, "chunk \(chunk)")
            #expect(
                try search("Gr.ße\\s+aus\\s+K\\wln", SearchOptions(regex: true))?.lowerBound == range.lowerBound,
                "chunk \(chunk)"
            )
            #expect(
                try search("\"Gr\"C3BC\"\"C39F", SearchOptions(hex: true)) == range.lowerBound..<range.lowerBound + 6,
                "chunk \(chunk)"
            )
            let found = try find(
                "aus köln",
                SearchOptions(backwards: backwards),
                in: wide,
                from: backwards ? Int64(wide.count) : 0,
                encoding: .utf16LE,
                chunk: chunk
            )
            #expect(
                found.map { bytes in
                    ViewerEncoding.utf16LE.string(from: wide.subdata(in: Int(bytes.lowerBound)..<Int(bytes.upperBound)))
                } == "aus Köln"
            )
        }
    }

    /// Searching on from each find gives every occurrence once, in order, in both directions.
    @Test
    internal func everyOccurrenceIsFoundOnceInOrder() throws {
        var bytes = [UInt8](repeating: 0x2E, count: 200_000)
        let places = [0, 61, 64, 4_090, 65_535, 65_540, 131_070, 199_997]
        for place in places { bytes.replaceSubrange(place..<place + 3, with: Array("hit".utf8)) }
        let data = Data(bytes)
        for options in [SearchOptions(), SearchOptions(hex: true), SearchOptions(regex: true)] {
            let needle = options.hex ? "686974" : "hit"
            var found: [Int] = []
            var start: Int64 = 0
            while let match = try find(needle, options, in: data, from: start, chunk: 1 << 16) {
                found.append(Int(match.lowerBound))
                start = match.lowerBound + 1
            }
            #expect(found == places)
            var backwards = options
            backwards.backwards = true
            found = []
            start = Int64(data.count)
            while let match = try find(needle, backwards, in: data, from: start, chunk: 1 << 16) {
                found.append(Int(match.lowerBound))
                start = match.lowerBound
            }
            #expect(found == places.reversed())
        }
    }

    /// A cancelled search finds nothing, and a search reports its progress in order up to the end.
    @Test
    internal func aCancelledSearchFindsNothingAndProgressIsReported() throws {
        let data = Data(repeating: 0x61, count: 1 << 20) + Data("needle".utf8)
        let pattern = try SearchPattern("needle", options: SearchOptions(), encoding: .utf8)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let request = ViewerSearch.Request(pattern: pattern, start: 0, backwards: false)
        let subject = ViewerSearch.Subject(
            source: DataByteSource(data),
            content: 0..<Int64(data.count),
            encoding: .utf8,
            boundaries: nil
        )
        var tuning = ViewerSearch.Tuning.standard
        tuning.chunkSize = 4_096
        #expect(
            try ViewerSearch.find(request, in: subject, tuning: tuning, cancellation: cancelled) { _ in
                // Not watched here.
            } == nil
        )
        var reports: [Double] = []
        tuning.parallelism = 4
        let flag = CancellationFlag()
        let found = try ViewerSearch.find(request, in: subject, tuning: tuning, cancellation: flag) { fraction in
            reports.append(fraction)
        }
        #expect(found == Int64(1 << 20)..<Int64((1 << 20) + 6))
        #expect(reports.count > 10 && reports == reports.sorted() && (reports.last ?? 2) <= 1)
    }
}
