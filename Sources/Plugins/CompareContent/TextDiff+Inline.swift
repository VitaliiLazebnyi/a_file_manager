import Foundation

/// Inside a line: the characters of two differing lines that differ.
extension TextDiff {
    /// The parts of two differing lines that differ, as ranges of UTF-16 units.
    ///
    /// After a difference the comparison only picks up again where at least `minimumMatch`
    /// characters agree, so a stray common letter does not chop a changed word into pieces.
    public static func inline(_ left: String, _ right: String, minimumMatch: Int = 3) -> (
        left: [Range<Int>], right: [Range<Int>]
    ) {
        // Only the part that is compared is turned into UTF-16: a line of megabytes costs no more than one of 4,096.
        let (headLeft, headRight) = (Array(left.utf16.prefix(inlineLimit)), Array(right.utf16.prefix(inlineLimit)))
        // The whole of a longer line is counted (cheap: the length of a string is not walked unit by unit) but not
        // copied.
        let (countLeft, countRight) = (
            headLeft.count == inlineLimit ? left.utf16.count : headLeft.count,
            headRight.count == inlineLimit ? right.utf16.count : headRight.count
        )
        let shared = sharedEnds(headLeft, headRight)
        var segments: [DiffSegment] = []
        if shared.prefix > 0 {
            segments.append(DiffSegment(first: 0..<shared.prefix, second: 0..<shared.prefix, isEqual: true))
        }
        // The effort is bounded: two long lines with little in common would take tens of milliseconds
        // each, and a screenful of them is drawn at once. A coarser result is only less exact highlighting.
        segments +=
            Myers.diff(
                Array(headLeft[shared.prefix..<(headLeft.count - shared.suffix)]),
                Array(headRight[shared.prefix..<(headRight.count - shared.suffix)]),
                costLimit: 300
            )
            .map { segment in
                DiffSegment(
                    first: (segment.first.lowerBound + shared.prefix)..<(segment.first.upperBound + shared.prefix),
                    second: (segment.second.lowerBound + shared.prefix)..<(segment.second.upperBound + shared.prefix),
                    isEqual: segment.isEqual
                )
            }
        if shared.suffix > 0 {
            segments.append(
                DiffSegment(
                    first: (headLeft.count - shared.suffix)..<headLeft.count,
                    second: (headRight.count - shared.suffix)..<headRight.count,
                    isEqual: true
                )
            )
        }
        if countLeft > inlineLimit || countRight > inlineLimit {
            segments.append(
                DiffSegment(first: headLeft.count..<countLeft, second: headRight.count..<countRight, isEqual: false)
            )
        }
        let marked = ranges(of: segments, minimumMatch: minimumMatch)
        return (widened(marked.left, in: headLeft), widened(marked.right, in: headRight))
    }

    /// How long a stretch the two share at the start and at the end, each 0 when shorter than 32.
    ///
    /// A long stretch needs no search. Short ones are left to it, because a stray match next to a difference is
    /// judged there.
    private static func sharedEnds(_ left: [UInt16], _ right: [UInt16]) -> (prefix: Int, suffix: Int) {
        var prefix = 0
        while prefix < left.count, prefix < right.count, left[prefix] == right[prefix] {
            prefix += 1
        }
        if prefix < 32 {
            prefix = 0
        }
        var suffix = 0
        while suffix < left.count - prefix, suffix < right.count - prefix,
            left[left.count - 1 - suffix] == right[right.count - 1 - suffix]
        {
            suffix += 1
        }
        if suffix < 32 {
            suffix = 0
        }
        return (prefix, suffix)
    }

    /// The ranges the segments mark on each side: what differs, and the short matches between differences.
    private static func ranges(of segments: [DiffSegment], minimumMatch: Int) -> (
        left: [Range<Int>], right: [Range<Int>]
    ) {
        var leftRanges: [Range<Int>] = []
        var rightRanges: [Range<Int>] = []
        func mark(_ range: Range<Int>, in ranges: inout [Range<Int>]) {
            guard !range.isEmpty else {
                return
            }
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        for (index, segment) in segments.enumerated() {
            let isShortMatch =
                segment.isEqual && segment.first.count < minimumMatch && index > 0 && index < segments.count - 1
            guard !segment.isEqual || isShortMatch else {
                continue
            }
            mark(segment.first, in: &leftRanges)
            mark(segment.second, in: &rightRanges)
        }
        return (leftRanges, rightRanges)
    }

    /// Ranges that do not cut a character in two: a surrogate pair, or a letter and the marks that belong to it,
    /// are marked whole (a mark on its own would be drawn apart from its letter).
    private static func widened(_ ranges: [Range<Int>], in head: [UInt16]) -> [Range<Int>] {
        // Nothing below U+0300 combines, and a surrogate is above it as well.
        guard !ranges.isEmpty, head.contains(where: { unit in unit >= 0x300 }) else {
            return ranges
        }
        let text = String(decoding: head, as: UTF16.self)
        let units = text.utf16
        var result: [Range<Int>] = []
        for marked in ranges {
            var range = marked
            if range.lowerBound < units.count {
                let lower = units.index(units.startIndex, offsetBy: range.lowerBound)
                let upper = units.index(lower, offsetBy: min(range.count, units.count - range.lowerBound))
                let whole = text.rangeOfComposedCharacterSequences(for: lower..<upper)
                let wholeStart = units.distance(from: units.startIndex, to: whole.lowerBound)
                let wholeEnd = units.distance(from: units.startIndex, to: whole.upperBound)
                range = min(range.lowerBound, wholeStart)..<max(range.upperBound, wholeEnd)
            }
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
