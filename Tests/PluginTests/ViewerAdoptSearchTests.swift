import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ViewerPlugin

/// Searches that must give the answer of decoding the whole file: texts in double-byte code
/// pages with long runs of two-byte characters, and ASCII words in the raw bytes.
@Suite
struct ViewerAdoptSearch {
    /// Every place `needle` is in `data` when all of it is decoded at once: the reference.
    private func occurrences(
        of needle: String,
        in data: Data,
        encoding: ViewerEncoding,
        caseSensitive: Bool = true,
        wholeWords: Bool = false
    ) -> [Range<Int64>] {
        var text = DecodedText()
        let used = encoding.decode(data, final: true, into: &text)
        let string = text.units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < string.length, let scalar = Unicode.Scalar(string.character(at: index)) else {
                return false
            }
            return word.contains(scalar)
        }
        var found: [Range<Int64>] = []
        var from = 0
        let length = needle.utf16.count
        while from + length <= string.length {
            let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            let range = string.range(
                of: needle,
                options: options,
                range: NSRange(location: from, length: string.length - from)
            )
            guard range.location != NSNotFound else { break }
            from = range.location + 1
            if wholeWords, isWord(range.location - 1) || isWord(range.location + range.length) { continue }
            let end = range.location + range.length
            found.append(
                Int64(
                    text.offsets[range.location]
                )..<(end < text.offsets.count ? Int64(text.offsets[end]) : Int64(used))
            )
        }
        return found
    }

    private func find(
        _ needle: String,
        _ options: SearchOptions,
        in data: Data,
        from start: Int64,
        encoding: ViewerEncoding,
        chunk: Int,
        boundaries: CharacterBoundaries? = nil,
        raw: Bool = true
    ) throws -> Range<Int64>? {
        let pattern = try SearchPattern(needle, options: options, encoding: encoding)
        return try ViewerSearch.find(
            pattern,
            in: DataByteSource(data),
            content: 0..<Int64(data.count),
            from: start,
            backwards: options.backwards,
            encoding: encoding,
            chunkSize: chunk,
            parallelism: 3,
            boundaries: boundaries,
            rawBytes: raw
        )
    }

    // MARK: Double-byte code pages

    /// A text of `head`, then `run` as one stretch of two-byte characters with no byte below 0x40 in it,
    /// then `tail`.
    private func cjkFile(_ encoding: ViewerEncoding, head: String, run: String, tail: String) throws -> Data {
        Data(try #require(encoding.encode(head + run + tail)))
    }

    /// A string the misaligned halves of the characters of `run` decode to: what a decoder that
    /// starts one byte off sees, and the aligned text never contains.
    private func misaligned(_ encoding: ViewerEncoding, _ run: String, runStart _: Int) throws -> String {
        let bytes = try #require(encoding.encode(run))
        var text = DecodedText()
        _ = encoding.decode(Array(bytes[1..<9]), final: true, into: &text)
        return text.string
    }

    @Test(arguments: [936, 932, 950, 949])
    func aLongRunOfTwoByteCharactersIsFoundExactlyForwardAndBackward(
        codePage: Int
    ) throws {
        let encoding = try #require(ViewerEncoding.codePage(codePage))
        let alphabets: [Int: String] = [
            936: "你好世界中国人民共和国大学生活", 932: "日本語文字列検索機能確認用資料", 950: "你好世界中國人民共和國大學生活", 949: "한국어문자열검색기능확인용자료"
        ]
        let alphabet = Array(try #require(alphabets[codePage])).filter { encoding.encode(String($0)) != nil }
        #expect(alphabet.count >= 8)
        // 300,000 characters (600,000 bytes) without a single byte below 0x40, from an odd offset.
        var state: UInt64 = 12_345
        var run = ""
        for _ in 0..<300_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            run.append(alphabet[Int(state >> 33) % alphabet.count])
        }
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
                    encoding: encoding
                )
                for start in [0, 1, 2, 3, 4_097, 100_001, 299_998, 300_001, 599_999, 600_002, Int64(data.count) - 3]
                    as [Int64]
                {
                    let forward = try find(
                        needle,
                        SearchOptions(),
                        in: data,
                        from: start,
                        encoding: encoding,
                        chunk: chunk,
                        boundaries: boundaries
                    )
                    #expect(
                        forward == reference.first { $0.lowerBound >= start },
                        "forward \(needle) from \(start), chunks of \(chunk), code page \(codePage)"
                    )
                    let backward = try find(
                        needle,
                        SearchOptions(backwards: true),
                        in: data,
                        from: start,
                        encoding: encoding,
                        chunk: chunk
                    )
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

    @Test
    func characterBoundariesAreExactAndAreReadOnce() throws {
        final class Counting: ByteSource {
            let data: Data
            private let counter = ViewerAdoptBox(Int64(0))
            init(_ data: Data) { self.data = data }
            var length: Int64 { Int64(data.count) }
            var bytesRead: Int64 { counter.value }
            func read(at offset: Int64, count: Int) -> Data {
                let lower = Int(max(0, min(offset, length)))
                let upper = min(data.count, lower + max(0, count))
                counter.mutate { $0 += Int64(upper - lower) }
                return data.subdata(in: lower..<upper)
            }
        }
        let gbk = try #require(ViewerEncoding.codePage(936))
        let characters = Array("你好世界中国人民共和国大学生活")
        var run = "a"
        for index in 0..<500_000 { run.append(characters[(index * 7 + index / 13) % characters.count]) }
        // A stray lead byte ends the run, then text and a second run.
        var bytes = try #require(gbk.encode(run))
        bytes +=
            [0xB0, 0x0A] + (try #require(gbk.encode("tail\n")))
            + (try #require(gbk.encode(String(run.dropFirst().prefix(40_000)))))
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
            let start = try boundaries.characterStart(atOrBefore: offset)
            // The greatest character start at or before the offset.
            // The end of the file is a place a character could begin.
            let expected =
                offset >= Int64(data.count) ? Int64(data.count) : sorted[(sorted.partitioningIndex { $0 > offset }) - 1]
            #expect(start == expected, Comment(rawValue: "offset \(offset): \(start) instead of \(expected)"))
        }
        // The first query had to go back through the run; the others cost little: a pass over the
        // file and a little, not a pass for each query.
        #expect(
            source.bytesRead < 3 * Int64(data.count) + 200 * 40_000,
            "\(source.bytesRead) bytes read for \(data.count)"
        )
        let after = source.bytesRead
        _ = try boundaries.characterStart(atOrBefore: 700_000)
        #expect(source.bytesRead - after < 40_000)
    }

    @Test
    func aSearchThroughAClusterOfLineEndsKeepsTheCharactersInStep() throws {
        // The usual case: line ends are in reach, and the answer is the same as ever.
        let sjis = try #require(ViewerEncoding.codePage(932))
        let line = "日本語のテキスト、ｶﾀｶﾅと ASCII 12345\n"
        let data = Data(try #require(sjis.encode(String(repeating: line, count: 3_000))))
        let reference = occurrences(of: "テキスト、", in: data, encoding: sjis)
        #expect(reference.count == 3_000)
        for chunk in [4_096, 7_777, 65_536] {
            var from: Int64 = 0
            var found: [Range<Int64>] = []
            while let next = try find("テキスト、", SearchOptions(), in: data, from: from, encoding: sjis, chunk: chunk) {
                found.append(next)
                from = next.lowerBound + 1
            }
            #expect(found == reference, "chunks of \(chunk)")
        }
    }

    // MARK: ASCII words in raw bytes

    private func jumble(seed: UInt64) -> String {
        var state = seed | 1
        func next(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(truncatingIfNeeded: state >> 9) % bound
        }
        let pieces = [
            "word ", "Word_1 ", "WORD", "words", "foo-bar ", "Foo", "BAR", "x", "xx ", "1", "_", "12 ", "e", "E\u{301}",
            "é", "É", "straße ", "STRASSE ", "Strasse ", "ss",
            "\u{212A}elvin ", "kelvin ", "\u{17F}tar ", "star ", "\u{FB01}nd ", "find ", "fi", "ff", "\u{130}stanbul ",
            "\u{131}", "i", "I", "日本語", "😀", "\n", "\r\n", "\t",
            "  ", ".", ",", "-", "(word)", "\u{0}", "ǅ", "ß", "ẞ", "st ", "\u{FB05}"
        ]
        var text = ""
        for _ in 0..<400 { text += pieces[next(pieces.count)] }
        return text
    }

    @Test
    func rawByteSearchGivesTheAnswerOfTheDecodedSearch() throws {
        let latin = try #require(ViewerEncoding.codePage(1_252))
        let dos = try #require(ViewerEncoding.codePage(437))
        let koi = try #require(ViewerEncoding.codePage(20_866))
        let needles = [
            "word", "WORD", "Word_1", "foo", "bar", "x", "xx", "1", "_", "e", "E", "s", "ss", "strasse", "k", "kelvin",
            "star", "fi", "find", "ff", "st", "i", "stanbul", "12", "foo-bar", " ", "(word)"
        ]
        var compared = 0
        for seed in 1...14 as ClosedRange<UInt64> {
            let text = jumble(seed: seed)
            var cases: [(ViewerEncoding, Data)] = [(.utf8, Data(text.utf8))]
            for encoding in [latin, dos, koi] {
                cases.append((encoding, Data(text.compactMap { encoding.encode(String($0)) }.flatMap { $0 })))
            }
            // Bytes that are no UTF-8, in the middle and at the end.
            cases.append(
                (
                    .utf8,
                    Data(text.utf8)
                        + Data([0xC3, 0x77, 0x6F, 0x72, 0x64, 0xE2, 0x82, 0x20, 0x77, 0x6F, 0x72, 0x64, 0xF0, 0x9F])
                )
            )
            for (encoding, data) in cases {
                for needle in needles {
                    for caseSensitive in [false, true] {
                        for wholeWords in [false, true] {
                            for backwards in [false, true] {
                                let options = SearchOptions(
                                    wholeWords: wholeWords,
                                    caseSensitive: caseSensitive,
                                    backwards: backwards
                                )
                                for (start, chunk) in [
                                    (Int64(0), 1 << 20), (Int64(data.count), 977), (Int64(data.count / 2), 313),
                                    (Int64(data.count / 3 + 1), 4_096)
                                ] {
                                    let raw = try find(
                                        needle,
                                        options,
                                        in: data,
                                        from: start,
                                        encoding: encoding,
                                        chunk: chunk,
                                        raw: true
                                    )
                                    let decoded = try find(
                                        needle,
                                        options,
                                        in: data,
                                        from: start,
                                        encoding: encoding,
                                        chunk: chunk,
                                        raw: false
                                    )
                                    #expect(
                                        raw == decoded,
                                        Comment(
                                            rawValue:
                                                "\(needle) \(options) in \(encoding.name), seed \(seed), from \(start), chunks of \(chunk)"
                                        )
                                    )
                                    compared += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(compared > 10_000)
    }

    @Test
    func everyOccurrenceOfAWholeWordIsFoundInOrderInTheRawBytes() throws {
        let text =
            String(repeating: "The Quick brown FOX; quick? quickly, QUICK_x _quick QUICK\n", count: 400)
            + "ünquick quickü quick"
        let data = Data(text.utf8)
        for options in [
            SearchOptions(wholeWords: true), SearchOptions(wholeWords: true, caseSensitive: true), SearchOptions()
        ] {
            let reference = occurrences(
                of: "quick",
                in: data,
                encoding: .utf8,
                caseSensitive: options.caseSensitive,
                wholeWords: options.wholeWords
            )
            var found: [Range<Int64>] = []
            var from: Int64 = 0
            while let next = try find("quick", options, in: data, from: from, encoding: .utf8, chunk: 1_000) {
                found.append(next)
                from = next.lowerBound + 1
            }
            #expect(found == reference, "\(options)")
            #expect(found.count == (options.wholeWords ? (options.caseSensitive ? 401 : 400 * 3 + 1) : 400 * 6 + 3))
        }
    }

    @Test
    func aSearchNeverChangesAnswerWhenTheTextHasCharactersThatFoldToLetters() throws {
        // ß for ss, the Kelvin sign for k, the long s: found by the decoded search, so the raw one steps aside.
        let data = Data("Straße, \u{212A}elvin, \u{17F}tar, \u{FB01}nd".utf8)
        for needle in ["strasse", "kelvin", "star", "find"] {
            let raw = try find(needle, SearchOptions(), in: data, from: 0, encoding: .utf8, chunk: 1 << 20, raw: true)
            let decoded = try find(
                needle,
                SearchOptions(),
                in: data,
                from: 0,
                encoding: .utf8,
                chunk: 1 << 20,
                raw: false
            )
            #expect(raw == decoded, Comment(rawValue: needle))
        }
    }
}

extension Array {
    /// The index of the first element for which `predicate` holds (it holds for a suffix).
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
