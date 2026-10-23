import Foundation
import Testing

@testable import ViewerPlugin

/// Searches that must give the answer of decoding the whole file: texts in double-byte code
/// pages with long runs of two-byte characters.
@Suite
internal struct ViewerAdoptSearchTests {
    /// Every place `needle` is in `data`, in the same case and not only as a whole word, when all of it is decoded
    /// at once.
    private func occurrences(of needle: String, in data: Data, encoding: ViewerEncoding) -> [Range<Int64>] {
        ViewerAdoptHaystack.occurrences(
            of: needle,
            in: data,
            encoding: encoding,
            caseSensitive: true,
            wholeWords: false
        )
    }

    /// A text of `head`, then `run` as one stretch of two-byte characters with no byte below 0x40 in it,
    /// then `tail`.
    private func cjkFile(_ encoding: ViewerEncoding, head: String, run: String, tail: String) throws -> Data {
        Data(try encoding.encode(head + run + tail))
    }

    /// A string the misaligned halves of the characters of `run` decode to: what a decoder that
    /// starts one byte off sees, and the aligned text never contains.
    private func misaligned(_ encoding: ViewerEncoding, _ run: String, runStart _: Int) throws -> String {
        let bytes = try encoding.encode(run)
        var text = DecodedText()
        _ = encoding.decode(Array(bytes[1..<9]), final: true, into: &text)
        return text.string
    }

    /// The index of the first of the sorted offsets that is above `offset`.
    private func firstIndex(above offset: Int64, in sorted: [Int64]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] > offset { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// A text of 300,000 random characters of the code page's alphabet, from an odd offset.
    private func longRun(of alphabet: [Character]) -> String {
        var state: UInt64 = 12_345
        var run = ""
        for _ in 0..<300_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            run.append(alphabet[Int(state >> 33) % alphabet.count])
        }
        return run
    }

    // MARK: Double-byte code pages

    /// In a long run of two-byte characters of each double-byte code page, a search forward or backward finds
    /// exactly what decoding everything finds, from every start and with chunk borders at every parity.
    @Test(arguments: [936, 932, 950, 949])
    internal func aLongRunOfTwoByteCharactersIsFoundExactlyForwardAndBackward(
        codePage: Int
    ) throws {
        let encoding = try #require(ViewerEncoding.codePage(codePage))
        let alphabets: [Int: String] = [
            936: "你好世界中国人民共和国大学生活", 932: "日本語文字列検索機能確認用資料", 950: "你好世界中國人民共和國大學生活", 949: "한국어문자열검색기능확인용자료"
        ]
        let alphabet = Array(try #require(alphabets[codePage])).filter { (try? encoding.encode(String($0))) != nil }
        #expect(alphabet.count >= 8)
        // 300,000 characters (600,000 bytes) without a single byte below 0x40, from an odd offset.
        let run = longRun(of: alphabet)
        let tail = "\nASCII tail, and more " + String(alphabet[0..<4]) + "\n"
        let data = try cjkFile(encoding, head: "x", run: run, tail: tail)
        // The runs must be pure two-byte for this to test anything.
        let body = data.dropFirst().prefix(600_000)
        #expect(body.allSatisfy { $0 >= 0x40 })
        let wanted = [String(alphabet[0..<2]), String(alphabet[3..<5]), String(alphabet.suffix(3))]
        let strangers = [try misaligned(encoding, run, runStart: 1)]
        for needle in wanted + strangers where !needle.isEmpty {
            let reference = occurrences(of: needle, in: data, encoding: encoding)
            // Chunk sizes that put the borders at every parity and far from any ASCII byte.
            for chunk in [4_096, 10_007, 65_536, 262_145] {
                let boundaries = CharacterBoundaries(
                    source: DataByteSource(data),
                    content: 0..<Int64(data.count),
                    encoding: encoding,
                    spacing: CharacterBoundaries.standardSpacing
                )
                let known = ViewerAdoptHaystack(data: data, encoding: encoding, chunk: chunk, boundaries: boundaries)
                let unknown = ViewerAdoptHaystack(data: data, encoding: encoding, chunk: chunk, boundaries: nil)
                for start in [0, 1, 2, 3, 4_097, 100_001, 299_998, 300_001, 599_999, 600_002, Int64(data.count) - 3]
                    as [Int64]
                {
                    let forward = try known.find(needle, SearchOptions(), from: start, raw: true)
                    #expect(
                        forward == reference.first { $0.lowerBound >= start },
                        "forward \(needle) from \(start), chunks of \(chunk), code page \(codePage)"
                    )
                    let backward = try unknown.find(needle, SearchOptions(backwards: true), from: start, raw: true)
                    #expect(
                        backward == reference.last { $0.lowerBound < start },
                        "backward \(needle) from \(start), chunks of \(chunk), code page \(codePage)"
                    )
                }
            }
        }
        // The text that is only there when decoded one byte off is not found.
        #expect(occurrences(of: strangers[0], in: data, encoding: encoding).isEmpty || codePage == 932)
    }

    /// The character boundaries of a GBK text with long runs give the exact character start before any offset, and
    /// read the file about once for all queries.
    @Test
    internal func characterBoundariesAreExactAndAreReadOnce() throws {
        final class Counting: ByteSource {
            let data: Data
            private let counter = ViewerAdoptBox(Int64(0))
            var length: Int64 { Int64(data.count) }
            var bytesRead: Int64 { counter.value }

            init(_ data: Data) { self.data = data }

            func read(at offset: Int64, count: Int) -> Data {
                let lower = Int(max(0, min(offset, length)))
                let upper = min(data.count, lower + max(0, count))
                counter.mutate { $0 += Int64(upper - lower) }
                return data.subdata(in: lower..<upper)
            }

            deinit {
                // Nothing to release.
            }
        }
        let gbk = try #require(ViewerEncoding.codePage(936))
        let characters = Array("你好世界中国人民共和国大学生活")
        var run = "a"
        for index in 0..<500_000 { run.append(characters[(index * 7 + index / 13) % characters.count]) }
        // A stray lead byte ends the run, then text and a second run.
        var bytes = try gbk.encode(run)
        bytes +=
            [0xB0, 0x0A] + (try gbk.encode("tail\n"))
            + (try gbk.encode(String(run.dropFirst().prefix(40_000))))
        let data = Data(bytes)
        var text = DecodedText()
        _ = gbk.decode(data, final: true, into: &text)
        let starts = Set(text.offsets.map(Int64.init))
        let sorted = starts.sorted()
        let source = Counting(data)
        let boundaries = CharacterBoundaries(
            source: source,
            content: 0..<Int64(data.count),
            encoding: gbk,
            spacing: 16 << 10
        )
        var queries: [Int64] = [900_000, 1, 2, 3, 524_287, 524_288, 999_999, Int64(data.count) - 1, Int64(data.count)]
        queries += (0..<150).map { _ in Int64.random(in: 0..<Int64(data.count)) }
        for offset in queries {
            let start = try boundaries.characterStart(atOrBefore: offset, cancellation: nil)
            // The greatest character start at or before the offset.
            // The end of the file is a place a character could begin.
            let expected =
                offset >= Int64(data.count) ? Int64(data.count) : sorted[firstIndex(above: offset, in: sorted) - 1]
            #expect(start == expected, Comment(rawValue: "offset \(offset): \(start) instead of \(expected)"))
        }
        // The first query had to go back through the run; the others cost little: a pass over the
        // file and a little, not a pass for each query.
        #expect(
            source.bytesRead < 3 * Int64(data.count) + 200 * 40_000,
            "\(source.bytesRead) bytes read for \(data.count)"
        )
        let after = source.bytesRead
        _ = try boundaries.characterStart(atOrBefore: 700_000, cancellation: nil)
        #expect(source.bytesRead - after < 40_000)
    }

    /// A Shift JIS text whose line ends are in reach of every chunk gives every occurrence, in order.
    @Test
    internal func aSearchThroughAClusterOfLineEndsKeepsTheCharactersInStep() throws {
        // The usual case: line ends are in reach, and the answer is the same as ever.
        let sjis = try #require(ViewerEncoding.codePage(932))
        let line = "日本語のテキスト、ｶﾀｶﾅと ASCII 12345\n"
        let data = Data(try sjis.encode(String(repeating: line, count: 3_000)))
        let reference = occurrences(of: "テキスト、", in: data, encoding: sjis)
        #expect(reference.count == 3_000)
        for chunk in [4_096, 7_777, 65_536] {
            let haystack = ViewerAdoptHaystack(data: data, encoding: sjis, chunk: chunk, boundaries: nil)
            var from: Int64 = 0
            var found: [Range<Int64>] = []
            while let next = try haystack.find("テキスト、", SearchOptions(), from: from, raw: true) {
                found.append(next)
                from = next.lowerBound + 1
            }
            #expect(found == reference, "chunks of \(chunk)")
        }
    }
}
