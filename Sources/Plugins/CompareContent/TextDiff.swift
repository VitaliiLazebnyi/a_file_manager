public import AFMKernel
public import Foundation

/// When two lines count as equal (spec 09 › Comparison rules).
///
/// The options only decide equality; inside a line that differs, the characters are compared
/// exactly.
public struct DiffOptions: Equatable, Codable, Sendable {
    /// Lines that differ only in upper and lower case are equal ("Case sensitive" off).
    public var ignoreCase = true
    /// Runs of spaces and tabs count as one space, and those at the start and end of a line
    /// as none.
    public var ignoreRepeatedSpaces = true
    /// `\n`, `\r\n` and `\r` are the same line break.
    public var ignoreLineEndings = true

    public init(ignoreCase: Bool = true, ignoreRepeatedSpaces: Bool = true, ignoreLineEndings: Bool = true) {
        self.ignoreCase = ignoreCase
        self.ignoreRepeatedSpaces = ignoreRepeatedSpaces
        self.ignoreLineEndings = ignoreLineEndings
    }

    /// What a line is compared by: two lines are equal exactly when their keys are.
    public func key(_ line: TextLine) -> String {
        var text = line.text
        if ignoreRepeatedSpaces {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.utf8.count)
            var gap = false
            for byte in text.utf8 {
                if byte == 0x20 || byte == 0x09 {
                    gap = true
                } else {
                    if gap, !bytes.isEmpty { bytes.append(0x20) }
                    gap = false
                    bytes.append(byte)
                }
            }
            text = String(decoding: bytes, as: UTF8.self)
        }
        if ignoreCase { text = text.lowercased() }
        return ignoreLineEndings ? text : text + line.ending.rawValue
    }

    /// A 64-bit hash of a line's key, made without building the key as a string.
    ///
    /// Equal keys have equal hashes; equal hashes are checked again with `isSameKey` where it
    /// matters.
    internal func hash(_ line: TextLine) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var text = line.text
        let hashed: Bool = text.withUTF8 { bytes in
            // Only ASCII is hashed as it is. Other text takes the slow path through `key`: it folds
            // case, and it is put in one form, so that a composed and a decomposed `é` are equal.
            if bytes.contains(where: { $0 >= 0x80 }) {
                return false
            }
            var gap = false
            var started = false
            for var byte in bytes {
                if ignoreRepeatedSpaces {
                    if byte == 0x20 || byte == 0x09 {
                        gap = true
                        continue
                    }
                    if gap, started {
                        hash = (hash ^ 0x20) &* 0x100_0000_01b3
                    }
                    gap = false
                    started = true
                }
                if ignoreCase, byte >= 0x41, byte <= 0x5A { byte += 0x20 }
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            return true
        }
        if !hashed {
            hash = 0xcbf2_9ce4_8422_2325
            for byte in key(line).precomposedStringWithCanonicalMapping.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        } else if !ignoreLineEndings {
            for byte in line.ending.rawValue.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        }
        return hash
    }

    /// Whether two lines have the same key; the exact test behind equal hashes.
    internal func isSameKey(_ first: TextLine, _ second: TextLine) -> Bool {
        (first.text == second.text && (ignoreLineEndings || first.ending == second.ending)) || key(first) == key(second)
    }

    /// The hashes of many lines; long files are spread over all cores, because folding case
    /// and spaces is the expensive part of preparing a comparison.
    internal func hashes(_ lines: [TextLine]) -> [UInt64] {
        guard lines.count >= 20_000 else {
            return lines.map(hash)
        }
        let size = max(2_000, lines.count / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let ranges = stride(from: 0, to: lines.count, by: size).map { $0..<min($0 + size, lines.count) }
        return Parallel.map(ranges) { lines[$0].map(hash) }.flatMap { $0 }
    }
}

/// One line of the two panes: a line of the left file, of the right file, or of both.
public struct DiffRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case equal
        /// Both sides have a line here and the two differ.
        case changed
        /// Only the right side has a line here.
        case added
        /// Only the left side has a line here.
        case removed
    }

    /// Positions in the lines of the two files.
    public let left: Int?
    public let right: Int?
    public let kind: Kind
}

/// Two texts laid side by side (spec 09 › Display).
///
/// Pure and UI-free; computing it is the slow part of the comparison and belongs on a background
/// thread.
public struct TextDiff: Equatable, Sendable {
    public let rows: [DiffRow]
    /// The differences as ranges of rows; a run of differing rows is one difference
    /// (spec 09 › Window, Next / Previous difference).
    public let blocks: [Range<Int>]

    public var isIdentical: Bool { blocks.isEmpty }

    /// `anchors` are pairs of lines the user said belong together ("Resync comparison from
    /// here"): the texts before and after each are compared on their own.
    public static func compute(
        left: [TextLine],
        right: [TextLine],
        options: DiffOptions = DiffOptions(),
        anchors: [(left: Int, right: Int)] = [],
        costLimit: Int? = nil,
        cancellation: CancellationFlag? = nil
    ) -> Self {
        compute(
            left: left,
            right: right,
            options: options,
            anchors: anchors,
            costLimit: costLimit,
            cancellation: cancellation,
            hashes: options.hashes
        )
    }

    /// The same with the lines' hashes made by `hashes`: a test that needs two different lines with
    /// the same hash (which the real one as good as never gives) makes them.
    internal static func compute(
        left: [TextLine],
        right: [TextLine],
        options: DiffOptions,
        anchors: [(left: Int, right: Int)],
        costLimit: Int?,
        cancellation: CancellationFlag?,
        hashes: @Sendable ([TextLine]) -> [UInt64]
    ) -> Self {
        // One side after the other: a long side is spread over all cores by itself, and a
        // short one costs little.
        let (leftKeys, rightKeys) = (hashes(left), hashes(right))
        var rows: [DiffRow] = []
        rows.reserveCapacity(max(left.count, right.count))

        func compare(_ a: Range<Int>, _ b: Range<Int>) {
            for segment in Myers.diff(
                Array(leftKeys[a]),
                Array(rightKeys[b]),
                costLimit: costLimit,
                cancellation: cancellation
            ) {
                let (first, second) = (segment.a.lowerBound + a.lowerBound, segment.b.lowerBound + b.lowerBound)
                if segment.isEqual {
                    for offset in 0..<segment.a.count {
                        rows.append(DiffRow(left: first + offset, right: second + offset, kind: .equal))
                    }
                    continue
                }
                // Replaced lines face each other as far as they go; the rest stands alone.
                let paired = min(segment.a.count, segment.b.count)
                for offset in 0..<paired {
                    rows.append(DiffRow(left: first + offset, right: second + offset, kind: .changed))
                }
                for offset in paired..<segment.a.count {
                    rows.append(DiffRow(left: first + offset, right: nil, kind: .removed))
                }
                for offset in paired..<segment.b.count {
                    rows.append(DiffRow(left: nil, right: second + offset, kind: .added))
                }
            }
        }

        var (nextLeft, nextRight) = (0, 0)
        for anchor in anchors.sorted(by: { $0.left < $1.left })
        where anchor.left >= nextLeft && anchor.right >= nextRight && anchor.left < left.count
            && anchor.right < right.count
        {
            compare(nextLeft..<anchor.left, nextRight..<anchor.right)
            rows.append(
                DiffRow(
                    left: anchor.left,
                    right: anchor.right,
                    kind: leftKeys[anchor.left] == rightKeys[anchor.right]
                        && options.isSameKey(left[anchor.left], right[anchor.right])
                        ? .equal : .changed
                )
            )
            (nextLeft, nextRight) = (anchor.left + 1, anchor.right + 1)
        }
        compare(nextLeft..<left.count, nextRight..<right.count)
        // Lines are paired by their hashes; a pair that is not really equal (a collision, which
        // is as good as never) is shown as changed.
        for index in rows.indices where rows[index].kind == .equal {
            if let one = rows[index].left, let two = rows[index].right, !options.isSameKey(left[one], right[two]) {
                rows[index] = DiffRow(left: one, right: two, kind: .changed)
            }
        }
        return Self(rows: rows, blocks: Self.blocks(of: rows))
    }

    internal static func blocks(of rows: [DiffRow]) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.kind == .equal {
                if let begun = start { blocks.append(begun..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begun = start { blocks.append(begun..<rows.count) }
        return blocks
    }

    /// The lines of the right text put together from the rows: the right file again, which is
    /// what makes a set of rows a correct diff.
    public func rebuiltRight<Line>(left _: [Line], right: [Line]) -> [Line] {
        rows.compactMap { row in
            switch row.kind {
            case .equal, .changed, .added:
                return row.right.map { right[$0] }

            case .removed:
                return nil
            }
        }
    }

    // MARK: Inside a line

    /// The within-line comparison covers this many characters (spec 09 › Comparison rules).
    public static let inlineLimit = 4_096

    /// The parts of two differing lines that differ, as ranges of UTF-16 units.
    ///
    /// After a difference the comparison only picks up again where at least `minimumMatch`
    /// characters agree, so a stray common letter does not chop a changed word into pieces.
    public static func inline(_ left: String, _ right: String, minimumMatch: Int = 3) -> (
        left: [Range<Int>], right: [Range<Int>]
    ) {
        // Only the part that is compared is turned into UTF-16: a line of megabytes costs no more than one of 4,096.
        let (headA, headB) = (Array(left.utf16.prefix(inlineLimit)), Array(right.utf16.prefix(inlineLimit)))
        // The whole of a longer line is counted (cheap: the length of a string is not walked unit by unit) but not copied.
        let (countA, countB) = (
            headA.count == inlineLimit ? left.utf16.count : headA.count,
            headB.count == inlineLimit ? right.utf16.count : headB.count
        )
        // A long stretch that the two share at the start or at the end needs no search. Short
        // ones are left to it, because a stray match next to a difference is judged there.
        var prefix = 0
        while prefix < headA.count, prefix < headB.count, headA[prefix] == headB[prefix] { prefix += 1 }
        if prefix < 32 { prefix = 0 }
        var suffix = 0
        while suffix < headA.count - prefix, suffix < headB.count - prefix,
            headA[headA.count - 1 - suffix] == headB[headB.count - 1 - suffix]
        { suffix += 1 }
        if suffix < 32 { suffix = 0 }
        var segments: [DiffSegment] = []
        if prefix > 0 { segments.append(DiffSegment(a: 0..<prefix, b: 0..<prefix, isEqual: true)) }
        // The effort is bounded: two long lines with little in common would take tens of milliseconds
        // each, and a screenful of them is drawn at once. A coarser result is only less exact highlighting.
        segments +=
            Myers.diff(
                Array(headA[prefix..<(headA.count - suffix)]),
                Array(headB[prefix..<(headB.count - suffix)]),
                costLimit: 300
            )
            .map {
                DiffSegment(
                    a: ($0.a.lowerBound + prefix)..<($0.a.upperBound + prefix),
                    b: ($0.b.lowerBound + prefix)..<($0.b.upperBound + prefix),
                    isEqual: $0.isEqual
                )
            }
        if suffix > 0 {
            segments.append(
                DiffSegment(
                    a: (headA.count - suffix)..<headA.count,
                    b: (headB.count - suffix)..<headB.count,
                    isEqual: true
                )
            )
        }
        if countA > inlineLimit || countB > inlineLimit {
            segments.append(DiffSegment(a: headA.count..<countA, b: headB.count..<countB, isEqual: false))
        }
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
                segment.isEqual && segment.a.count < minimumMatch && index > 0 && index < segments.count - 1
            guard !segment.isEqual || isShortMatch else { continue }
            mark(segment.a, in: &leftRanges)
            mark(segment.b, in: &rightRanges)
        }
        return (widened(leftRanges, in: headA), widened(rightRanges, in: headB))
    }

    /// Ranges that do not cut a character in two: a surrogate pair, or a letter and the marks that belong to it,
    /// are marked whole (a mark on its own would be drawn apart from its letter).
    private static func widened(_ ranges: [Range<Int>], in head: [UInt16]) -> [Range<Int>] {
        // Nothing below U+0300 combines, and a surrogate is above it as well.
        guard !ranges.isEmpty, head.contains(where: { $0 >= 0x300 }) else {
            return ranges
        }
        let text = String(decoding: head, as: UTF16.self) as NSString
        var result: [Range<Int>] = []
        for range in ranges {
            var range = range
            if range.lowerBound < text.length {
                let whole = text.rangeOfComposedCharacterSequences(
                    for: NSRange(location: range.lowerBound, length: min(range.count, text.length - range.lowerBound))
                )
                range = min(range.lowerBound, whole.location)..<max(range.upperBound, whole.location + whole.length)
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

/// Two files compared byte by byte at the same offsets, in lines of a fixed number of bytes
/// (spec 09 › Loading, mode and encodings: binary mode).
public struct BinaryDiff: Equatable, Sendable {
    public let bytesPerLine: Int
    public let leftCount: Int
    public let rightCount: Int
    /// The differences as ranges of lines.
    public let blocks: [Range<Int>]
    /// Bytes that differ, counting those one file has beyond the end of the other.
    public let differingBytes: Int

    public var rowCount: Int { (max(leftCount, rightCount) + bytesPerLine - 1) / bytesPerLine }
    public var isIdentical: Bool { differingBytes == 0 }

    /// Compares on all cores: the lines are dealt out in large pieces, and each piece reports
    /// its differing stretches.
    public static func compute(left: Data, right: Data, bytesPerLine: Int = 16, cancellation: CancellationFlag? = nil)
        -> Self
    {
        let width = max(1, bytesPerLine)
        let rowCount = (max(left.count, right.count) + width - 1) / width
        let common = min(left.count, right.count)
        let pieceRows = max(4_096, rowCount / (ProcessInfo.processInfo.activeProcessorCount * 4) + 1)
        let pieces = stride(from: 0, to: rowCount, by: pieceRows).map { $0..<min($0 + pieceRows, rowCount) }

        let found: [(blocks: [Range<Int>], bytes: Int)] = left.withUnsafeBytes { first in
            right.withUnsafeBytes { second in
                /// Only read, and only while the call lasts.
                nonisolated(unsafe) let (first, second) = (first, second)
                return Parallel.map(pieces) { piece in
                    var blocks: [Range<Int>] = []
                    var bytes = 0
                    var start: Int?
                    for row in piece {
                        if row & 0xFFF == 0, cancellation?.isCancelled == true { break }
                        let (from, to) = (row * width, min((row + 1) * width, max(left.count, right.count)))
                        let shared = max(0, min(to, common) - from)
                        var differing = to - from - shared
                        if shared > 0, memcmp(first.baseAddress! + from, second.baseAddress! + from, shared) != 0 {
                            for offset in from..<(from + shared) where first[offset] != second[offset] {
                                differing += 1
                            }
                        }
                        bytes += differing
                        if differing > 0 {
                            if start == nil { start = row }
                        } else if let begun = start {
                            blocks.append(begun..<row)
                            start = nil
                        }
                    }
                    if let begun = start { blocks.append(begun..<piece.upperBound) }
                    return (blocks, bytes)
                }
            }
        }
        // Stretches that run across the border of two pieces are one difference.
        var blocks: [Range<Int>] = []
        for block in found.flatMap(\.blocks) {
            if let last = blocks.last, last.upperBound == block.lowerBound {
                blocks[blocks.count - 1] = last.lowerBound..<block.upperBound
            } else {
                blocks.append(block)
            }
        }
        return Self(
            bytesPerLine: width,
            leftCount: left.count,
            rightCount: right.count,
            blocks: blocks,
            differingBytes: found.reduce(0) { $0 + $1.bytes }
        )
    }

    /// The offset of a line's first byte, as shown in front of it.
    public func offsetText(row: Int) -> String {
        String(format: "%08X", row * bytesPerLine)
    }

    /// A line of one file: its bytes in hex, then as characters.
    ///
    /// Empty past the file's end.
    public func text(of data: Data, row: Int) -> String {
        let from = row * bytesPerLine
        guard from < data.count else {
            return ""
        }
        let bytes = data[(data.startIndex + from)..<(data.startIndex + min(from + bytesPerLine, data.count))]
        let digits = Array("0123456789ABCDEF".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(bytesPerLine * 4 + 1)
        for (index, byte) in bytes.enumerated() {
            if index > 0 { text.append(0x20) }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 15)])
        }
        while text.count < bytesPerLine * 3 + 1 { text.append(0x20) }
        for byte in bytes { text.append((0x20..<0x7F).contains(byte) ? byte : 0x2E) }
        return String(decoding: text, as: UTF8.self)
    }

    /// The positions inside a line at which the two files differ.
    public func differingOffsets(left: Data, right: Data, row: Int) -> [Int] {
        let from = row * bytesPerLine
        return (0..<bytesPerLine)
            .filter { offset in
                let position = from + offset
                let (inLeft, inRight) = (position < left.count, position < right.count)
                if inLeft, inRight {
                    return left[left.startIndex + position] != right[right.startIndex + position]
                }
                return inLeft != inRight
            }
    }

    /// Where a byte of a line is in the line's text: its hex digits and its character.
    public func textRanges(ofByte offset: Int) -> [Range<Int>] {
        [(offset * 3)..<(offset * 3 + 2), (bytesPerLine * 3 + 1 + offset)..<(bytesPerLine * 3 + 2 + offset)]
    }
}
