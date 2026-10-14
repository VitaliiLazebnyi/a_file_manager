import Foundation
import FuzzCore

@testable import CompareContentPlugin

// MARK: loader (decoding into lines, binary comparison)

/// The seeds of `loader`: bytes per line, then the two files around the separator.
@MainActor
internal func loaderSeeds() -> [[UInt8]] {
    [
        [16] + Array("one\r\ntwo\rthree\nfour".utf8) + kSeparator + Array("one\ntwo\n".utf8),
        [0, 0xEF, 0xBB, 0xBF] + Array("bom\nline\n".utf8) + kSeparator
            + [0xFF, 0xFE, 0x61, 0, 0x0D, 0, 0x0A, 0, 0x62, 0],
        [3, 0xFE, 0xFF, 0, 0x61, 0, 0x0A, 0xD8, 0x3D, 0xDC, 0x4D] + kSeparator + [0xE9, 0x0A, 0x80, 0x0D],
        [200, 1, 2, 0, 3] + kSeparator + [1, 2, 3, 3, 4, 5]
    ]
}

/// The Foundation encoding that matches `encoding`.
internal func stringEncoding(of encoding: TextEncoding) -> String.Encoding {
    switch encoding {
    case .utf8:
        .utf8

    case .latin1:
        .isoLatin1

    case .utf16LittleEndian:
        .utf16LittleEndian

    case .utf16BigEndian:
        .utf16BigEndian
    }
}

/// One file decoded into lines: numbered lines without breaks, and the same bytes back when they were valid.
internal func checkDocument(_ raw: [UInt8]) {
    let data = Data(raw)
    let document = TextDocument(data: data)
    let detail = "bytes \(raw.prefix(64)) (\(raw.count)) encoding \(document.encoding.name)"
    fzCheck(document.encoding == TextEncoding.detect(data), "loader-detect-differs", detail)
    for (index, line) in document.lines.enumerated() {
        fzCheck(line.number == index + 1, "loader-line-number", detail)
        fzCheck(!line.text.utf8.contains(0x0A) && !line.text.utf8.contains(0x0D), "loader-break-in-line", detail)
        fzCheck(line.ending != .none || index == document.lines.count - 1, "loader-ending-inside", detail)
    }
    _ = document.usualEnding
    // "The file's bytes: the same as were loaded as long as nothing was changed" - where
    // the bytes are valid in the encoding that was found.
    let body = data.dropFirst(document.encoding.bom.count)
    let foundation = stringEncoding(of: document.encoding)
    if let strict = String(data: body, encoding: foundation), strict.data(using: foundation) == Data(body) {
        fzCheck(document.data() == data, "loader-roundtrip", detail + " back \([UInt8](document.data()).prefix(64))")
    } else {
        _ = document.data()
    }
    _ = TextDocument.looksBinary(data)
    // a forced encoding, as the encoding menu asks for
    let forcedEncodings = [
        TextEncoding.utf8(bom: false), .utf8(bom: true), .utf16LittleEndian, .utf16BigEndian, .latin1
    ]
    for encoding in forcedEncodings {
        let forced = TextDocument(data: data, encoding: encoding)
        _ = forced.data()
    }
}

/// The binary comparison of the two files: the count of differing bytes, the blocks and each row.
internal func checkBinary(_ leftBytes: [UInt8], _ rightBytes: [UInt8], bytesPerLine: Int) {
    let (left, right) = (Data(leftBytes), Data(rightBytes))
    let diff = BinaryDiff.compute(left: left, right: right, bytesPerLine: bytesPerLine)
    let detail = "bytesPerLine \(bytesPerLine) left \(leftBytes.prefix(48)) right \(rightBytes.prefix(48))"
    var differing = abs(left.count - right.count)
    for index in 0..<min(left.count, right.count) where leftBytes[index] != rightBytes[index] {
        differing += 1
    }
    fzCheck(diff.differingBytes == differing, "binarydiff-count", detail)
    var marked = Set<Int>()
    for block in diff.blocks {
        fzCheck(!block.isEmpty && block.upperBound <= diff.rowCount, "binarydiff-blocks", detail)
        for row in block {
            marked.insert(row)
        }
    }
    for row in 0..<min(diff.rowCount + 1, 3_000) {
        let offsets = diff.differingOffsets(left: left, right: right, row: row)
        fzCheck(offsets.isEmpty != marked.contains(row), "binarydiff-row", detail + " row \(row)")
        let line = diff.text(of: left, row: row)
        _ = diff.text(of: right, row: row)
        _ = diff.offsetText(row: row)
        for offset in offsets {
            let onLeft = offset < left.count - row * diff.bytesPerLine
            for range in diff.textRanges(ofByte: offset) where onLeft {
                fzCheck(
                    range.upperBound <= line.utf16.count,
                    "binarydiff-textrange",
                    detail + " row \(row) offset \(offset)"
                )
            }
        }
    }
}

/// The loader's decoding of both files, then their binary comparison.
@MainActor
internal func runLoader(_ bytes: [UInt8]) {
    var choices = Choices(bytes)
    let perLine = Int(Int8(bitPattern: choices.byte()))
    let (leftBytes, rightBytes) = splitPair(&choices)
    for raw in [leftBytes, rightBytes] {
        checkDocument(raw)
    }
    checkBinary(leftBytes, rightBytes, bytesPerLine: perLine)
}

/// The `loader` target.
@MainActor
internal func loaderTarget() -> FuzzTarget {
    FuzzTarget(
        "loader",
        maxLen: 1 << 14,
        dict: ["\r\n", "\r", "\n", "\u{2028}", "\u{85}", "\u{1C}\u{1D}"],
        rawDict: [
            [0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0x00, 0xD8], [0xD8, 0x00], [0x0D, 0x00, 0x0A, 0x00],
            [0xC3], [0xE2, 0x80], [0xF0, 0x9F], [0], [0x0A, 0x00]
        ],
        seeds: loaderSeeds,
        run: runLoader
    )
}
