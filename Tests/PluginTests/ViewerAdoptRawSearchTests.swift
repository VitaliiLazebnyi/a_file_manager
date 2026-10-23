import Foundation
import Testing

@testable import ViewerPlugin

/// Searches for ASCII words in the raw bytes, which must give the answer of decoding the whole file.
@Suite
internal struct ViewerAdoptRawSearchTests {
    /// The words searched for in the random texts.
    private let needles = [
        "word", "WORD", "Word_1", "foo", "bar", "x", "xx", "1", "_", "e", "E", "s", "ss", "strasse", "k", "kelvin",
        "star", "fi", "find", "ff", "st", "i", "stanbul", "12", "foo-bar", " ", "(word)"
    ]

    /// A random text of words, cases, characters that fold to letters (ß, the Kelvin sign, ligatures) and line ends.
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

    /// The text in UTF-8 and three single-byte code pages, and in UTF-8 with bytes that are no UTF-8 in the middle
    /// and at the end.
    private func encodings(of text: String) throws -> [(ViewerEncoding, Data)] {
        let latin = try #require(ViewerEncoding.codePage(1_252))
        let dos = try #require(ViewerEncoding.codePage(437))
        let koi = try #require(ViewerEncoding.codePage(20_866))
        var cases: [(ViewerEncoding, Data)] = [(.utf8, Data(text.utf8))]
        for encoding in [latin, dos, koi] {
            cases.append((encoding, Data(text.compactMap { try? encoding.encode(String($0)) }.joined())))
        }
        cases.append(
            (
                .utf8,
                Data(text.utf8)
                    + Data([0xC3, 0x77, 0x6F, 0x72, 0x64, 0xE2, 0x82, 0x20, 0x77, 0x6F, 0x72, 0x64, 0xF0, 0x9F])
            )
        )
        return cases
    }

    /// Searches the bytes for every needle with every option, from four starts, both from the raw bytes and decoding
    /// everything, and expects the same answer; returns how many searches were compared.
    private func compareSearches(in data: Data, encoding: ViewerEncoding, seed: UInt64) throws -> Int {
        var compared = 0
        let startsAndChunks = [
            (Int64(0), 1 << 20), (Int64(data.count), 977), (Int64(data.count / 2), 313),
            (Int64(data.count / 3 + 1), 4_096)
        ]
        for needle in needles {
            for caseSensitive in [false, true] {
                for wholeWords in [false, true] {
                    for backwards in [false, true] {
                        let options = SearchOptions(
                            wholeWords: wholeWords,
                            caseSensitive: caseSensitive,
                            backwards: backwards
                        )
                        for (start, chunk) in startsAndChunks {
                            let haystack = ViewerAdoptHaystack(
                                data: data,
                                encoding: encoding,
                                chunk: chunk,
                                boundaries: nil
                            )
                            let raw = try haystack.find(needle, options, from: start, raw: true)
                            let decoded = try haystack.find(needle, options, from: start, raw: false)
                            let what = "\(needle) \(options) in \(encoding.name), seed \(seed)"
                            #expect(raw == decoded, Comment(rawValue: "\(what), from \(start), chunks of \(chunk)"))
                            compared += 1
                        }
                    }
                }
            }
        }
        return compared
    }

    // MARK: ASCII words in raw bytes

    /// In random texts of five encodings, the raw byte search finds what the decoded search finds, for every word and
    /// every option.
    @Test
    internal func rawByteSearchGivesTheAnswerOfTheDecodedSearch() throws {
        var compared = 0
        for seed in 1...14 as ClosedRange<UInt64> {
            for (encoding, data) in try encodings(of: jumble(seed: seed)) {
                compared += try compareSearches(in: data, encoding: encoding, seed: seed)
            }
        }
        #expect(compared > 10_000)
    }

    /// Searching again and again from one past the last find gives every occurrence of a word in order, whole words
    /// only or not, in either case.
    @Test
    internal func everyOccurrenceOfAWholeWordIsFoundInOrderInTheRawBytes() throws {
        let text =
            String(repeating: "The Quick brown FOX; quick? quickly, QUICK_x _quick QUICK\n", count: 400)
            + "ünquick quickü quick"
        let data = Data(text.utf8)
        let haystack = ViewerAdoptHaystack(data: data, encoding: .utf8, chunk: 1_000, boundaries: nil)
        for options in [
            SearchOptions(wholeWords: true), SearchOptions(wholeWords: true, caseSensitive: true), SearchOptions()
        ] {
            let reference = ViewerAdoptHaystack.occurrences(
                of: "quick",
                in: data,
                encoding: .utf8,
                caseSensitive: options.caseSensitive,
                wholeWords: options.wholeWords
            )
            var found: [Range<Int64>] = []
            var from: Int64 = 0
            while let next = try haystack.find("quick", options, from: from, raw: true) {
                found.append(next)
                from = next.lowerBound + 1
            }
            #expect(found == reference, "\(options)")
            #expect(found.count == (options.wholeWords ? (options.caseSensitive ? 401 : 400 * 3 + 1) : 400 * 6 + 3))
        }
    }

    /// Where the text has characters that fold to letters (ß, the Kelvin sign, the long s, the fi ligature), the raw
    /// search gives the decoded search's answer.
    @Test
    internal func aSearchNeverChangesAnswerWhenTheTextHasCharactersThatFoldToLetters() throws {
        // ß for ss, the Kelvin sign for k, the long s: found by the decoded search, so the raw one steps aside.
        let data = Data("Straße, \u{212A}elvin, \u{17F}tar, \u{FB01}nd".utf8)
        let haystack = ViewerAdoptHaystack(data: data, encoding: .utf8, chunk: 1 << 20, boundaries: nil)
        for needle in ["strasse", "kelvin", "star", "find"] {
            let raw = try haystack.find(needle, SearchOptions(), from: 0, raw: true)
            let decoded = try haystack.find(needle, SearchOptions(), from: 0, raw: false)
            #expect(raw == decoded, Comment(rawValue: needle))
        }
    }

    /// In UTF-8, a word right after a letter beyond ASCII is part of a longer word: the raw search decodes that letter.
    @Test
    internal func aLetterBeyondASCIIBeforeAWordMakesItNoWholeWord() throws {
        let data = Data("üquick, 日quick, quick".utf8)
        let haystack = ViewerAdoptHaystack(data: data, encoding: .utf8, chunk: 1 << 20, boundaries: nil)
        let options = SearchOptions(wholeWords: true)
        let raw = try haystack.find("quick", options, from: 0, raw: true)
        #expect(raw == Int64(data.count - 5)..<Int64(data.count))
        #expect(try raw == haystack.find("quick", options, from: 0, raw: false))
    }
}
