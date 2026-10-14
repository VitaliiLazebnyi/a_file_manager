import Foundation
import FuzzCore

// What several targets of the group share: text out of bytes, the separator of the two sides of an
// input, the plain longest common subsequence, and the fixed clock, locale and time zone.

/// The two bytes between the left and the right side of an input.
internal let kSeparator: [UInt8] = [0x1C, 0x1D]

/// Times (seconds since 1970) that rename masks are evaluated with: ordinary ones and the far ends.
internal let kRealisticDates: [Double] = [
    0, 1_700_000_000, 1_700_000_000.789, -62_167_219_200, 253_402_300_799, -1, 951_782_400, 4_102_444_800, 1e10,
    -1e10, 86_399.9999
]

/// UTC, so that the dates do not depend on the machine.
internal let kUTC = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current

/// The fixed locale the masks and templates are evaluated in.
internal let kPosixLocale = Locale(identifier: "en_US_POSIX")

/// The bytes as UTF-8 text, each invalid sequence replaced by U+FFFD (as `String(decoding:as:)` does).
internal func text(_ bytes: [UInt8]) -> String {
    fzText(bytes)
}

/// Seeds given as text.
internal func seedsOf(_ texts: [String]) -> [[UInt8]] {
    texts.map { Array($0.utf8) }
}

/// The text of `bytes`, shortened to at most 255 bytes of UTF-8 (the longest file name).
internal func name255(_ bytes: [UInt8]) -> String {
    var name = text(bytes)
    while name.utf8.count > 255 {
        name.removeLast()
    }
    return name
}

/// Length of the longest common subsequence, the plain quadratic way.
internal func lcs<T: Equatable>(_ first: [T], _ second: [T]) -> Int {
    guard !first.isEmpty, !second.isEmpty else {
        return 0
    }
    var row = [Int](repeating: 0, count: second.count + 1)
    for element in first {
        var diagonal = 0
        for column in 0..<second.count {
            let above = row[column + 1]
            row[column + 1] = element == second[column] ? diagonal + 1 : max(above, row[column])
            diagonal = above
        }
    }
    return row[second.count]
}

/// The rest of the input split at the first separator into the left and the right side.
internal func splitPair(_ choices: inout Choices) -> ([UInt8], [UInt8]) {
    let all = choices.rest()
    var index = 0
    while index + 1 < all.count {
        if all[index] == 0x1C, all[index + 1] == 0x1D {
            return (Array(all[..<index]), Array(all[(index + 2)...]))
        }
        index += 1
    }
    return (all, [])
}
