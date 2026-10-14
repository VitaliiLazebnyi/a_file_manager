import Foundation
import FuzzCore

@testable import CompareContentPlugin

// MARK: inline

/// `units` without the units inside `ranges` (ordered, not overlapping).
internal func removing(_ ranges: [Range<Int>], from units: [UInt16]) -> [UInt16] {
    var out: [UInt16] = []
    var start = 0
    for range in ranges {
        out += units[start..<range.lowerBound]
        start = range.upperBound
    }
    return out + units[start...]
}

/// The two sides of the input as UTF-16 units: decoded from UTF-8, or (`wide`) little-endian pairs.
internal func utf16Pair(_ choices: inout Choices, wide: Bool) -> ([UInt16], [UInt16]) {
    let (leftBytes, rightBytes) = splitPair(&choices)
    func units(_ bytes: [UInt8]) -> [UInt16] {
        if !wide {
            return Array(text(bytes).utf16)
        }
        return stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
    }
    return (units(leftBytes), units(rightBytes))
}

/// Whether `part` stands in `whole` in order, not necessarily side by side.
internal func isSubsequence(_ part: [UInt16], of whole: [UInt16]) -> Bool {
    var matched = 0
    for unit in whole where matched < part.count && part[matched] == unit {
        matched += 1
    }
    return matched == part.count
}

/// A string made by Foundation from the units as they are (lone surrogates included), as a bridged string is.
internal func bridgedString(_ units: [UInt16]) -> String {
    guard let made = CFStringCreateWithCharacters(nil, units, units.count) else {
        fzFail("inline-bridged-string", "no string from \(units.prefix(60))")
    }
    return made as String
}

/// The whole characters around `range` (UTF-16 offsets), as `rangeOfComposedCharacterSequences(for:)` finds them.
internal func composedRange(_ text: String, _ range: Range<Int>) -> Range<Int> {
    let string = text as CFString
    let first = CFStringGetRangeOfComposedCharactersAtIndex(string, range.lowerBound)
    let last = CFStringGetRangeOfComposedCharactersAtIndex(string, range.upperBound - 1)
    return first.location..<(last.location + last.length)
}

/// The seeds of `inline`: the minimum match, the flags, then the two lines.
@MainActor
internal func inlineSeeds() -> [[UInt8]] {
    let longLeft = String(repeating: "x", count: 40) + "abc" + String(repeating: "y", count: 40)
    let longRight = String(repeating: "x", count: 40) + "abd" + String(repeating: "y", count: 40)
    return [
        [3, 0] + Array("The quick brown fox".utf8) + kSeparator + Array("The quack brown box".utf8),
        [0, 0] + Array("e\u{301}a👍🏽b".utf8) + kSeparator + Array("éa👍b".utf8),
        [
            2, 1, 0x3D, 0xD8, 0x4D, 0xDC, 0x41, 0, 0x3D, 0xD8, 0x1C, 0x1D, 0x4D, 0xDC, 0x41, 0, 0x3D, 0xD8, 0x4E,
            0xDC
        ],
        [3, 0] + Array(longLeft.utf8) + kSeparator + Array(longRight.utf8),
        [3, 0x80] + Array("abcdefgh".utf8) + kSeparator + Array("abxdefgy".utf8)
    ]
}

/// The highlights of one pair of lines: valid ranges, the rest standing in the other line, no character cut.
internal func checkInline(_ left: String, _ right: String, minimum: Int, bridged: Bool) {
    let (leftUnits, rightUnits) = (Array(left.utf16), Array(right.utf16))
    let detail =
        "minimumMatch \(minimum) bridged \(bridged) left \(leftUnits.prefix(60)) right \(rightUnits.prefix(60))"
        + " (\(leftUnits.count),\(rightUnits.count))"
    let marks = TextDiff.inline(left, right, minimumMatch: minimum)
    for (ranges, count) in [(marks.left, leftUnits.count), (marks.right, rightUnits.count)] {
        var end = -1
        for range in ranges {
            fzCheck(
                !range.isEmpty && range.lowerBound > end && range.upperBound <= count,
                "inline-ranges-invalid",
                detail + " ranges \(ranges)"
            )
            end = range.upperBound
        }
    }
    // The marks cover whole characters (a surrogate pair, a letter with its accents), so one side may mark
    // more than the other: what is left unmarked on one side still stands, in that order, in the other line.
    fzCheck(
        isSubsequence(removing(marks.left, from: leftUnits), of: rightUnits)
            && isSubsequence(removing(marks.right, from: rightUnits), of: leftUnits),
        "inline-rest-differs",
        detail + " \(marks)"
    )
    // No mark cuts a character in two (the lines as the window holds them: lone surrogates repaired).
    if !bridged {
        for (ranges, line) in [(marks.left, left), (marks.right, right)] {
            for range in ranges where range.upperBound <= line.utf16.count {
                let whole = composedRange(line, range)
                fzCheck(
                    whole == range,
                    "inline-mark-cuts-a-character",
                    detail + " range \(range) whole \(NSRange(location: whole.lowerBound, length: whole.count))"
                )
            }
        }
    }
    if left == right, leftUnits == rightUnits {
        fzCheck(marks.left.isEmpty && marks.right.isEmpty, "inline-equal-highlighted", detail)
    }
}

/// The within-line highlights, on decoded and on bridged lines, short and beyond the inline limit.
@MainActor
internal func runInline(_ bytes: [UInt8]) {
    var choices = Choices(bytes)
    let minimum = Int(choices.byte()) % 6
    let flags = choices.byte()
    var (first, second) = utf16Pair(&choices, wide: flags & 1 != 0)
    if flags & 0x80 != 0 {  // long lines, beyond the inline limit
        let times = 1 + Int(flags >> 1 & 0x3F) * 20
        if first.count * times <= 12_000 {
            first = Array(repeatElement(first, count: times).joined())
        }
        if second.count * (times + 1) <= 12_000 {
            second = Array(repeatElement(second, count: times + 1).joined())
        }
    }
    // As the window has them: lines that came out of a decoder (lone surrogates repaired),
    // and bridged strings, which may still carry them.
    for bridged in [false, true] {
        let left = bridged ? bridgedString(first) : String(decoding: first, as: UTF16.self)
        let right = bridged ? bridgedString(second) : String(decoding: second, as: UTF16.self)
        checkInline(left, right, minimum: minimum, bridged: bridged)
    }
}

/// The `inline` target.
@MainActor
internal func inlineTarget() -> FuzzTarget {
    FuzzTarget(
        "inline",
        maxLen: 24_000,
        dict: [
            "e\u{301}", "é", "👍🏽", "👨‍👩‍👧", "\u{200D}", "\u{FE0F}", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "\u{1C}\u{1D}"
        ],
        rawDict: [[0x3D, 0xD8], [0x4D, 0xDC], [0x00, 0xD8], [0xFF, 0xDF], [0x01, 0x03]],
        seeds: inlineSeeds,
        run: runInline
    )
}
