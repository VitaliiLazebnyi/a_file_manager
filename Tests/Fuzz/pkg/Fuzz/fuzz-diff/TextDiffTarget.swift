import Foundation
import FuzzCore

@testable import CompareContentPlugin

// MARK: textdiff

/// The seeds of `textdiff`: options, anchors, then the two files around the separator.
@MainActor
internal func textDiffSeeds() -> [[UInt8]] {
    [
        [7, 0] + Array("one\ntwo\nthree\nfour\n".utf8) + kSeparator + Array("one\nTWO\nthree\nfive\nfour".utf8),
        [0, 1, 3, 3] + Array("a\r\nb\rc\n a  b \nx\n".utf8) + kSeparator + Array("a\nb\nc\na b\ny\nx\n".utf8),
        [0x35, 2, 2, 2, 5, 4] + Array("a\nb\na\nb\na\nb\nc\n".utf8) + kSeparator
            + Array("b\na\nb\na\nc\na\nb\n".utf8),
        [3, 0, 0xFF, 0xFE] + Array("a\0\n\0b\0\n\0".utf8) + kSeparator + [0xFE, 0xFF]
            + Array("\0a\0\n\0c\0\n".utf8),
        [1, 0] + Array("é\ne\u{301}\nK\n".utf8) + kSeparator + Array("e\u{301}\nÉ\n\u{212A}\n".utf8)
    ]
}

/// Checks that the rows walk both sides in order and that equal rows hold lines with the same key.
internal func checkRows(
    _ diff: TextDiff,
    _ left: [TextLine],
    _ right: [TextLine],
    _ options: DiffOptions,
    _ detail: String
) {
    var (leftIndex, rightIndex) = (0, 0)
    for row in diff.rows {
        switch row.kind {
        case .equal, .changed:
            fzCheck(row.left == leftIndex && row.right == rightIndex, "textdiff-rows-order", detail)
            if row.kind == .equal, let one = row.left, let two = row.right, one < left.count, two < right.count {
                fzCheck(options.isSameKey(left[one], right[two]), "textdiff-equal-row-differs", detail)
            }
            leftIndex += 1
            rightIndex += 1

        case .added:
            fzCheck(row.left == nil && row.right == rightIndex, "textdiff-rows-order", detail)
            rightIndex += 1

        case .removed:
            fzCheck(row.right == nil && row.left == leftIndex, "textdiff-rows-order", detail)
            leftIndex += 1
        }
    }
    fzCheck(leftIndex == left.count && rightIndex == right.count, "textdiff-rows-cover", detail)
}

/// Checks that the blocks are ordered, inside the rows, and hold exactly the rows that are not equal.
internal func checkBlocks(_ diff: TextDiff, _ detail: String) {
    var inBlock = [Bool](repeating: false, count: diff.rows.count)
    var last = -1
    for block in diff.blocks {
        fzCheck(
            !block.isEmpty && block.lowerBound > last && block.upperBound <= diff.rows.count,
            "textdiff-blocks",
            detail
        )
        for row in block {
            inBlock[row] = true
        }
        last = block.upperBound
    }
    for (index, row) in diff.rows.enumerated() {
        fzCheck((row.kind != .equal) == inBlock[index], "textdiff-blocks-kind", detail)
    }
}

/// The options, cost limit and anchors a `textdiff` input starts with.
internal func readTextDiffSettings(_ choices: inout Choices) -> (DiffOptions, TextDiffAnchoring) {
    let flags = choices.byte()
    let options = DiffOptions(
        ignoreCase: flags & 1 != 0,
        ignoreRepeatedSpaces: flags & 2 != 0,
        ignoreLineEndings: flags & 4 != 0
    )
    let limit: Int? = flags & 0x30 == 0x30 ? Int(flags >> 6) : nil
    let anchorCount = Int(choices.byte()) % 4
    var anchors: [(left: Int, right: Int)] = []
    for _ in 0..<anchorCount {
        anchors.append((Int(choices.byte()) - 2, Int(choices.byte()) - 2))
    }
    return (options, TextDiffAnchoring(limit: limit, anchors: anchors))
}

/// TextDiff on two files: rows, blocks, the shortest diff, and the loader's comparison agreeing.
@MainActor
internal func runTextDiff(_ bytes: [UInt8]) {
    var choices = Choices(bytes)
    let (options, anchoring) = readTextDiffSettings(&choices)
    let (limit, anchors) = (anchoring.limit, anchoring.anchors)
    let (leftBytes, rightBytes) = splitPair(&choices)
    let leftDocument = TextDocument(data: Data(leftBytes))
    let rightDocument = TextDocument(data: Data(rightBytes))
    let (left, right) = (leftDocument.lines, rightDocument.lines)
    let leftText = left.map { $0.text + $0.ending.rawValue }.prefix(40).debugDescription
    let rightText = right.map { $0.text + $0.ending.rawValue }.prefix(40).debugDescription
    let detail =
        "options \(options) limit \(String(describing: limit)) anchors \(anchors) left \(leftText) right \(rightText)"
    let diff = TextDiff.compute(left: left, right: right, options: options, anchors: anchors, costLimit: limit)
    checkRows(diff, left, right, options, detail)
    fzCheck(
        diff.rebuiltRight(left: Array(left.indices), right: Array(right.indices)) == Array(right.indices),
        "textdiff-rebuilt",
        detail
    )
    checkBlocks(diff, detail)
    if anchors.isEmpty, limit == nil, left.count * right.count <= 20_000 {
        let (leftKeys, rightKeys) = (left.map(options.key), right.map(options.key))
        let equal = diff.rows.filter { $0.kind == .equal }.count
        let common = lcs(leftKeys, rightKeys)
        fzCheck(equal == common, "textdiff-not-shortest", detail + " equal rows \(equal) lcs \(common)")
    }
    let compared = CompareLoader.text(left: leftDocument, right: rightDocument, options: options, anchors: anchors)
    guard case .text(_, _, let again, let width) = compared else {
        fzFail("comparetext-kind", detail)
    }
    fzCheck(width == (left + right).reduce(0) { max($0, $1.text.utf16.count) }, "comparetext-width", detail)
    if limit == nil {
        fzCheck(again == diff, "comparetext-differs", detail)
    }
}

/// The `textdiff` target.
@MainActor
internal func textDiffTarget() -> FuzzTarget {
    FuzzTarget(
        "textdiff",
        maxLen: 1 << 14,
        dict: [
            "\r\n", "\r", "\n", " ", "\t", "a\n", "A\n", "é", "e\u{301}", "\u{212A}", "K", "k", "\u{1C}\u{1D}",
            "  a  b\n", "a b\n"
        ],
        rawDict: [[0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xFE, 0xFF], [0xD8, 0x00], [0x00, 0xDC]],
        seeds: textDiffSeeds,
        run: runTextDiff
    )
}
