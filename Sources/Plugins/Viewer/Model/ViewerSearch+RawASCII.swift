import AFMKernel
import Foundation

/// ASCII needles in the raw bytes.
extension ViewerSearch {
    /// What a search of the raw bytes found out.
    internal enum RawAnswer {
        /// The match the decoded search would find (nil: none).
        case answer(Range<Int64>?)
        /// A text with a character that matches case-insensitively without being ASCII: only
        /// decoding gives the answer the decoded search gives.
        case undecided
    }

    /// An ASCII needle in the raw bytes of a UTF-8 or one-byte-per-character text.
    private struct RawScan {
        let needle: [UInt8]
        /// The needle as it is compared: in lower case unless the case matters.
        let wanted: [UInt8]
        let folded: Bool
        let wholeWords: Bool
        /// The characters of the bytes of a text in a code page; nil for UTF-8.
        let table: CodeTable?

        init(_ needle: [UInt8], _ pattern: SearchPattern, table: CodeTable?) {
            let fold = !pattern.caseSensitive
            self.needle = needle
            folded = fold
            wholeWords = pattern.wholeWords
            self.table = table
            wanted = needle.map { byte in fold && byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
        }

        /// Whether the character `unit` belongs to a word.
        private static func isWordUnit(_ unit: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else {
                return false
            }
            return wordCharacters.contains(scalar)
        }

        /// The first position at or after `from` of `byte`, or `count`.
        private static func find(_ byte: UInt8, in start: UnsafePointer<UInt8>, _ count: Int, from: Int) -> Int {
            guard from < count, let found = memchr(start + from, Int32(byte), count - from) else {
                return count
            }
            return start.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }

        /// Where the first (or last) match that begins in `from..<limit` of `raw` begins; nil when
        /// there is none.
        func find(in raw: UnsafeRawBufferPointer, from: Int, before limit: Int, last: Bool) -> Int? {
            let count = raw.count
            guard count >= needle.count, let start = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let first = wanted[0]
            let alternative: UInt8 = folded && first >= 0x61 && first <= 0x7A ? first & ~0x20 : first
            var position = from
            var nextLower = -1
            var nextUpper = -1
            var result: Int?
            while position < limit, position + needle.count <= count {
                if nextLower < position { nextLower = Self.find(first, in: start, count, from: position) }
                if alternative != first, nextUpper < position {
                    nextUpper = Self.find(alternative, in: start, count, from: position)
                }
                position = alternative != first ? min(nextLower, nextUpper) : nextLower
                guard position < limit, position + needle.count <= count else { break }
                if matches(start, at: position),
                    !wholeWords
                        || !(isWordBefore(position, start) || isWordAfter(position + needle.count, start, count))
                {
                    result = position
                    if !last {
                        return result
                    }
                }
                position += 1
            }
            return result
        }

        /// Whether the bytes at `position` are the needle (its first byte is known to be).
        private func matches(_ start: UnsafePointer<UInt8>, at position: Int) -> Bool {
            for offset in 1..<needle.count {
                let byte = start[position + offset]
                if (folded && byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) != wanted[offset] {
                    return false
                }
            }
            return true
        }

        /// Whether the character that ends at `end` belongs to a word.
        private func isWordBefore(_ end: Int, _ start: UnsafePointer<UInt8>) -> Bool {
            guard end > 0 else {
                return false
            }
            let byte = start[end - 1]
            guard byte >= 0x80 else {
                return Self.isWordUnit(UInt16(byte))
            }
            // Beyond ASCII: by the table of the code page, or decoded as UTF-8.
            if let table {
                return Self.isWordUnit(table.single[Int(byte)])
            }
            var begin = end - 1
            while begin > 0, end - begin < 4, start[begin] & 0xC0 == 0x80 { begin -= 1 }
            var text = DecodedText()
            text.tracksOffsets = false
            _ = ViewerEncoding.utf8.decode(
                UnsafeBufferPointer(start: start + begin, count: end - begin),
                final: true,
                into: &text
            )
            // Bytes decoded to the end give at least one unit.
            return Self.isWordUnit(text.units[text.units.count - 1])
        }

        /// Whether the character that begins at `begin` belongs to a word.
        private func isWordAfter(_ begin: Int, _ start: UnsafePointer<UInt8>, _ count: Int) -> Bool {
            guard begin < count else {
                return false
            }
            let byte = start[begin]
            guard byte >= 0x80 else {
                return Self.isWordUnit(UInt16(byte))
            }
            // Beyond ASCII: by the table of the code page, or decoded as UTF-8.
            if let table {
                return Self.isWordUnit(table.single[Int(byte)])
            }
            var text = DecodedText()
            text.tracksOffsets = false
            _ = ViewerEncoding.utf8.decode(
                UnsafeBufferPointer(start: start + begin, count: min(4, count - begin)),
                final: true,
                into: &text
            )
            return Self.isWordUnit(text.units[0])
        }
    }

    /// The characters other than ASCII letters that a literal, case-insensitive search of
    /// `NSString` takes for ASCII letters: ß and ẞ for `ss`, the long s, the Kelvin sign,
    /// the ligatures ﬀ…ﬆ.
    ///
    /// A chunk that has one is left to the decoded search.
    private static let caseFolded: Set<UInt16> = [
        0xDF, 0x17F, 0x1E9E, 0x212A, 0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB05, 0xFB06
    ]

    /// The first (or last) match of an ASCII `needle` that begins inside `accepted`, found in the
    /// raw bytes of a UTF-8 or one-byte-per-character text: a byte is compared with both cases
    /// of the letter, and for a whole word the characters on either side are looked at.
    ///
    /// The same answer as the decoded search gives; `undecided` where it could not be sure to.
    internal static func rawASCII(
        _ needle: [UInt8],
        _ pattern: SearchPattern,
        _ context: Context,
        accepted: Range<Int64>,
        last: Bool
    ) throws -> RawAnswer {
        let (content, encoding) = (context.content, context.encoding)
        // Four bytes either side are a character; a match is at most three bytes a letter long.
        let lower = max(content.lowerBound, accepted.lowerBound - 4)
        let upper = min(content.upperBound, accepted.upperBound + Int64(needle.count) * 3 + 4)
        let data = try context.source.read(lower..<upper, cancellation: context.cancellation)
        // The characters of the bytes of a text in a code page; nil for UTF-8.
        let table = encoding.kind == .utf8 ? nil : CodeTable.table(for: encoding)
        if hasCaseFolded(data, table: table) {
            return .undecided
        }
        let scan = RawScan(needle, pattern, table: table)
        let found = data.withUnsafeBytes { raw in
            scan.find(
                in: raw,
                from: Int(accepted.lowerBound - lower),
                before: Int(min(Int64(data.count), accepted.upperBound - lower)),
                last: last
            )
        }
        return .answer(found.map { position in lower + Int64(position)..<lower + Int64(position + needle.count) })
    }

    /// Whether `data` has one of `caseFolded`: by the code page's `table`, or in UTF-8 without one.
    private static func hasCaseFolded(_ data: Data, table: CodeTable?) -> Bool {
        guard let table else {
            return hasCaseFolded(utf8: data)
        }
        let folded = (0x80...0xFF).filter { caseFolded.contains(table.single[$0]) }.map(UInt8.init)
        return data.withUnsafeBytes { raw in
            folded.contains { memchr(raw.baseAddress, Int32($0), raw.count) != nil }
        }
    }

    /// Whether `data` has the UTF-8 form of one of `caseFolded`.
    private static func hasCaseFolded(utf8 data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let count = raw.count
            guard count > 0, let start = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            var index = 0
            while index < count {
                if index + 8 <= count,
                    UnsafeRawPointer(start + index).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 == 0
                {
                    index += 8
                    continue
                }
                if isCaseFolded(start, at: index, count) {
                    return true
                }
                index += 1
            }
            return false
        }
    }

    /// Whether the UTF-8 bytes at `index` are one of `caseFolded`.
    private static func isCaseFolded(_ start: UnsafePointer<UInt8>, at index: Int, _ count: Int) -> Bool {
        let byte = start[index]
        guard byte >= 0xC3, index + 1 < count else {
            return false
        }
        let second = start[index + 1]
        let third = index + 2 < count ? start[index + 2] : 0
        switch byte {
        case 0xC3 where second == 0x9F, 0xC5 where second == 0xBF:
            return true

        case 0xE1 where second == 0xBA && third == 0x9E, 0xE2 where second == 0x84 && third == 0xAA:
            return true

        case 0xEF where second == 0xAC && (0x80...0x86).contains(third):
            return true

        default:
            return false
        }
    }
}
