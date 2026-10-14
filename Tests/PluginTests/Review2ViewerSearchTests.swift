import AFMKernel
import Foundation
import TestSupport
import Testing
@testable import ViewerPlugin

/// Review round 2, the search: a backwards search never returns the match at its start, the
/// result does not depend on the size of the chunks or on whether the bytes are compared raw or
/// decoded, and a file that became shorter does not trap a double-byte search.
@Suite struct Review2ViewerSearch {
    private func find(_ text: String, in data: Data, _ options: SearchOptions = SearchOptions(), from start: Int64 = 0, encoding: ViewerEncoding = .utf8,
                      chunkSize: Int = 1 << 20, rawBytes: Bool = true) throws -> Range<Int64>? {
        let pattern = try SearchPattern(text, options: options, encoding: encoding)
        return try ViewerSearch.find(pattern, in: DataByteSource(data), content: 0..<Int64(data.count), from: start, backwards: options.backwards,
                                     encoding: encoding, chunkSize: chunkSize, rawBytes: rawBytes)
    }

    @Test func aBackwardsSearchDoesNotReturnTheMatchThatBeginsAtItsStart() throws {
        // "ss" is the single character ß (bytes 4 and 5): a match that begins at the start itself.
        let data = Data("Straße".utf8)
        var backwards = SearchOptions()
        backwards.backwards = true
        for chunk in [1, 2, 3, 5, 8, 64, 1 << 20] {
            #expect(try find("ss", in: data, backwards, from: 4, chunkSize: chunk) == nil, "chunk \(chunk)")
            #expect(try find("ss", in: data, backwards, from: 6, chunkSize: chunk) == 4..<6, "chunk \(chunk)")
            #expect(try find("strasse", in: Data("Straße Straße".utf8), backwards, from: 8, chunkSize: chunk) == 0..<7, "chunk \(chunk)")
            #expect(try find("ss", in: data, from: 0, chunkSize: chunk) == 4..<6, "chunk \(chunk)")
        }
    }

    @Test func findingThePreviousHitRepeatedlyWalksBackThroughAllOfThem() throws {
        let data = Data("Straße, STRASSE, strasse, Straße".utf8)
        var backwards = SearchOptions()
        backwards.backwards = true
        var start = Int64(data.count)
        var found: [Range<Int64>] = []
        while let hit = try find("strasse", in: data, backwards, from: start, chunkSize: 5) {
            found.append(hit)
            start = hit.lowerBound
        }
        var forwards: [Range<Int64>] = []
        var next: Int64 = 0
        while let hit = try find("strasse", in: data, from: next, chunkSize: 5) {
            forwards.append(hit)
            next = hit.lowerBound + 1
        }
        #expect(found.count == 4 && found.reversed() == forwards)
    }

    @Test func aStartInTheMiddleOfACharacterReturnsOnlyMatchesThatBeginBeforeIt() throws {
        // "ä" is two bytes; a search backwards from its second byte finds what begins before it.
        let data = Data("ab ää ab".utf8)
        var backwards = SearchOptions()
        backwards.backwards = true
        #expect(try find("ä", in: data, backwards, from: 7) == 5..<7)
        // The second ä begins at 5, before 6: it is found; from 5 itself the first one is.
        #expect(try find("ä", in: data, backwards, from: 6) == 5..<7)
        #expect(try find("ä", in: data, backwards, from: 5) == 3..<5)
        #expect(try find("ä", in: data, backwards, from: 4) == 3..<5)
        #expect(try find("ä", in: data, backwards, from: 3) == nil)
    }

    @Test func controlCharactersAreNotSkippedOverInTheText() throws {
        // The needle has an escape in front of the 9; the text has a 9 only (second byte invalid).
        for raw in [true, false] {
            #expect(try find("\u{1B}9", in: Data([0x39, 0xAE]), rawBytes: raw) == nil, "raw \(raw)")
            #expect(try find("\u{1B}9", in: Data([0x1B, 0x39, 0xAE]), rawBytes: raw) == 0..<2, "raw \(raw)")
        }
        // "0\u{03}" is not "0" followed by anything.
        var text = String(repeating: "é", count: 29) + "0"
        text += "x" + String(repeating: "é", count: 5)
        for chunk in [8, 16, 33, 1 << 20] {
            #expect(try find("0\u{03}", in: Data(text.utf8), chunkSize: chunk) == nil, "chunk \(chunk)")
        }
        let with = String(repeating: "é", count: 29) + "0\u{03}" + String(repeating: "é", count: 5)
        let at = Int64(29 * 2)
        for chunk in [8, 16, 33, 1 << 20] {
            #expect(try find("0\u{03}", in: Data(with.utf8), chunkSize: chunk) == at..<at + 2, "chunk \(chunk)")
        }
    }

    @Test func theAnswerDoesNotDependOnTheChunkSizeOrThePath() throws {
        var state: UInt64 = 20_260_101
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33) % bound
        }
        let pieces = ["ss", "ß", "S", "s", "A", "a", "é", "É", "\u{03}", "\u{1B}", "\u{200B}", " ", "ﬁ", "fi", "K", "\u{212A}", "k", "x", "\n", "ẞ"]
        let needles = ["ss", "ß", "fi", "k", "ak", "é", "s\u{03}", "x s", "SS"]
        var compared = 0
        for _ in 0..<150 {
            var text = ""
            for _ in 0..<(8 + next(40)) { text += pieces[next(pieces.count)] }
            let data = Data(text.utf8)
            let needle = needles[next(needles.count)]
            for backwards in [false, true] {
                var options = SearchOptions()
                options.backwards = backwards
                options.caseSensitive = next(4) == 0
                let start = backwards ? Int64(data.count) : 0
                let reference = try find(needle, in: data, options, from: start, chunkSize: 1 << 20, rawBytes: false)
                for chunk in [1, 2, 3, 7, 16, 100] {
                    #expect(try find(needle, in: data, options, from: start, chunkSize: chunk, rawBytes: false) == reference,
                            "decoded \(text.debugDescription) \(needle.debugDescription) backwards \(backwards) chunk \(chunk)")
                    #expect(try find(needle, in: data, options, from: start, chunkSize: chunk, rawBytes: true) == reference,
                            "raw \(text.debugDescription) \(needle.debugDescription) backwards \(backwards) chunk \(chunk)")
                }
                compared += 1
            }
        }
        #expect(compared == 300)
    }

    @Test func everyBackwardsMatchBeginsBeforeTheStart() throws {
        let data = Data("ßssSSßx ßss".utf8)
        var options = SearchOptions()
        options.backwards = true
        for start in 0...Int64(data.count) {
            for chunk in [1, 3, 1 << 20] {
                if let hit = try find("ss", in: data, options, from: start, chunkSize: chunk) {
                    #expect(hit.lowerBound < start, "start \(start) chunk \(chunk): \(hit)")
                }
            }
        }
    }

    // MARK: Double-byte text in a file that became shorter

    private final class Shrunk: ByteSource {
        let length: Int64 = 200_000
        func read(at offset: Int64, count: Int) throws -> Data {
            guard offset < 50_000 else { return Data() }
            return Data((0..<min(count, 50_000 - Int(offset))).map { ($0 + Int(offset)) % 2 == 0 ? UInt8(0x81) : UInt8(0x41) })
        }
    }

    @Test func aFileThatBecameShorterDoesNotTrapTheBoundariesOfADoubleByteText() throws {
        let sjis = try #require(ViewerEncoding.codePage(932))
        let boundaries = CharacterBoundaries(source: Shrunk(), content: 0..<200_000, encoding: sjis)
        #expect(throws: ViewerError.fileChanged) { try boundaries.characterStart(atOrBefore: 150_000) }
        let pattern = try SearchPattern("zzzz", options: SearchOptions(), encoding: sjis)
        // Reached through a search, which goes by chunks.
        #expect(throws: (any Error).self) {
            _ = try ViewerSearch.find(pattern, in: Shrunk(), content: 0..<200_000, from: 0, backwards: false, encoding: sjis, chunkSize: 40_000, parallelism: 1)
        }
    }

    @Test func theBoundariesKeepAtMostAFixedNumberOfBlocks() throws {
        let sjis = try #require(ViewerEncoding.codePage(932))
        let data = Data((0..<(1 << 20)).map { $0 % 2 == 0 ? UInt8(0x81) : UInt8(0x41) })
        let boundaries = CharacterBoundaries(source: DataByteSource(data), content: 0..<Int64(data.count), encoding: sjis, spacing: 16)
        for offset in stride(from: 0, to: data.count, by: 16) { _ = try boundaries.characterStart(atOrBefore: Int64(offset)) }
        #expect(boundaries.blockCount <= CharacterBoundaries.keptLimit)
    }
}
