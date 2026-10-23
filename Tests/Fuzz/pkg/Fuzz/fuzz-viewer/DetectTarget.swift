import Foundation
import FuzzCore

@testable import ViewerPlugin

/// The `detect` target: encoding detection, and decoding in one go against decoding piece by piece.
internal enum DetectTarget {
    /// The target.
    @MainActor
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "detect",
            maxLen: 8_192,
            dict: [
                "charset=", "windows-1252", "windows-99999999999999999999", "utf-16be", "<html", "<!doctype html",
                "%PDF-", "{\\rtf", "RIFF", "WEBP", ".html", ".bmp"
            ],
            rawDict: [
                [0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0xD8, 0x00], [0x00, 0xD8], [0xDC, 0x00],
                [0x81, 0x40], [0xF0, 0x9F, 0x98, 0x80], [0xED, 0xA0, 0x80], [0xC0, 0x80], [0xF4, 0x90, 0x80, 0x80],
                [0xE2, 0x82]
            ],
            seeds: seeds,
            run: run
        )
    }

    /// The inputs the fuzzer starts from: an encoding, two cut sizes, then the bytes.
    internal static func seeds() -> [[UInt8]] {
        [
            Array("\u{1}\u{3}\u{2}hello wörld €\n日本語 text\r\n".utf8),
            [3, 5, 9, 0xFF, 0xFE, 0x41, 0, 0x3D, 0xD8, 0, 0xDE, 0x0A, 0],
            [8, 2, 2, 0x82, 0xA0, 0x82, 0xA2, 0x41, 0x81, 0x0A, 0x95, 0x5C],
            Array("\u{0}\u{1}\u{1}<html><meta charset=\"windows-1251\">".utf8)
        ]
    }

    /// Runs one input.
    @MainActor
    internal static func run(_ bytes: [UInt8]) {
        var choices = Choices(bytes)
        let encoding = kEncodings[choices.int(kEncodings.count)]
        let cutA = size(&choices)
        let cutB = size(&choices)
        let data = choices.rest()
        let guess = checkDetection(data)
        for candidate in [encoding, guess] {
            let whole = checkWhole(data, candidate)
            checkPieces(data, candidate, cutA: cutA, cutB: cutB, whole: whole)
            if let back = try? candidate.encode(String(decoding: whole.units.prefix(64), as: UTF16.self)) {
                _ = back.count
            }
        }
    }

    /// Detection never traps and is stable; returns the encoding it guessed.
    @MainActor
    private static func checkDetection(_ data: [UInt8]) -> ViewerEncoding {
        let sample = Data(data)
        let guess = ViewerDetection.guessText(sample, isWholeFile: true)
        _ = ViewerDetection.guessText(sample, isWholeFile: false)
        fzCheck(guess == ViewerDetection.guessText(sample, isWholeFile: true), "detect-unstable")
        fzCheck(
            guess.bomLength >= 0 && guess.bomLength <= data.count,
            "detect-bom-length",
            "\(guess.bomLength) of \(data.count)"
        )
        _ = ViewerDetection.content(name: fzText(data.prefix(40)), sample: sample, additionalMedia: [], vetoed: [])
        _ = ViewerDetection.content(name: "a.txt", sample: sample, additionalMedia: [], vetoed: [])
        _ = ViewerDetection.htmlCharset(sample)
        _ = ViewerDetection.extensions(in: fzText(data.prefix(100)))
        _ = HexFormat.hexString(sample.prefix(64))
        return guess.encoding
    }

    /// Decodes the whole in one go and checks the offsets; returns the text.
    @MainActor
    private static func checkWhole(_ data: [UInt8], _ encoding: ViewerEncoding) -> DecodedText {
        var whole = DecodedText()
        let used = encoding.decode(data, final: true, into: &whole)
        fzCheck(
            used == data.count,
            "decode-final-leaves-bytes",
            "\(encoding.codePage): used \(used) of \(data.count): \(describe(data))"
        )
        fzCheck(whole.offsets.count == whole.units.count, "decode-offset-count", "\(encoding.codePage)")
        var last: Int32 = 0
        for offset in whole.offsets {
            fzCheck(
                offset >= last && Int(offset) < max(1, data.count),
                "decode-offsets-order",
                "\(encoding.codePage): \(describe(data))"
            )
            last = offset
        }
        fzCheck(encoding.units(from: Data(data)) == whole.units, "decode-units-differ", "\(encoding.codePage)")
        _ = encoding.string(from: Data(data))
        return whole
    }

    /// Decodes piece by piece: what a piece leaves is handed in again with the next.
    ///
    /// The text and the offsets must be the ones of the whole.
    @MainActor
    private static func checkPieces(
        _ data: [UInt8],
        _ encoding: ViewerEncoding,
        cutA: Int,
        cutB: Int,
        whole: DecodedText
    ) {
        var units: [UInt16] = []
        var offsets: [Int] = []
        var start = 0
        var turn = 0
        var piece = DecodedText()
        while start < data.count {
            let step = max(1, turn.isMultiple(of: 2) ? cutA : cutB)
            turn += 1
            let took = decodePiece(data, encoding, from: start, step: step, into: &piece)
            units += piece.units
            offsets += piece.offsets.map { Int($0) + start }
            start += took
            if took == 0 {
                break
            }
        }
        fzCheck(
            units == whole.units,
            "decode-pieces-differ-text",
            "\(encoding.codePage) cuts \(cutA)/\(cutB): \(describe(data))"
        )
        fzCheck(
            offsets == whole.offsets.map { Int($0) },
            "decode-pieces-differ-offsets",
            "\(encoding.codePage) cuts \(cutA)/\(cutB): \(describe(data))"
        )
    }

    /// Decodes one piece from `start`, `step` bytes long; a piece too small to hold one character grows.
    ///
    /// Returns the bytes the decoder used.
    @MainActor
    private static func decodePiece(
        _ data: [UInt8],
        _ encoding: ViewerEncoding,
        from start: Int,
        step: Int,
        into piece: inout DecodedText
    ) -> Int {
        var end = min(data.count, start + step)
        while true {
            let final = end == data.count
            let took = encoding.decode(Array(data[start..<end]), final: final, into: &piece)
            fzCheck(
                took >= 0 && took <= end - start,
                "decode-used-out-of-range",
                "\(encoding.codePage): \(took) of \(end - start)"
            )
            if took > 0 || final {
                return took
            }
            end = min(data.count, end + 1)
        }
    }
}
