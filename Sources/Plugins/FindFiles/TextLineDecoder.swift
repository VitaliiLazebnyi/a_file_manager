import Foundation

/// Collects the bytes of a file and hands them out as text, whole lines at a time, for a search with
/// a regular expression.
internal struct TextLineDecoder {
    /// A "line" longer than this is handed out in pieces.
    private static let longestLine = 4 << 20

    /// How much of a piece cut in the middle of a long line is looked at again with the next one,
    /// so that a match across the cut is found as long as it is shorter than this.
    private static let cutOverlap = 4_096

    /// The encoding the bytes are decoded from.
    internal let encoding: TextEncoding
    private var pending = Data()
    private var bigEndian = false
    private var isStart = true

    /// A decoder of text in `encoding`.
    internal init(encoding: TextEncoding) {
        self.encoding = encoding
    }

    /// Takes the next block of the file; returns the text of the whole lines that are complete now (or a
    /// piece of a line that is too long), nil when there is none yet.
    internal mutating func feed(_ block: Data) -> String? {
        pending.append(block)
        if isStart, encoding == .utf16, pending.count >= 2 {
            readByteOrder()
            isStart = false
        }
        if let cut = lastLineEnd(), cut > 0 {
            let text = decode(pending.prefix(cut))
            pending.removeFirst(cut)
            return text
        }
        guard pending.count > Self.longestLine else {
            return nil
        }
        // A line without a break that is too long: handed out in pieces, cut between
        // characters, with the end of each piece repeated at the start of the next.
        let cut = boundary(atOrBefore: pending.count)
        let text = decode(pending.prefix(cut))
        pending.removeFirst(boundary(atOrBefore: max(0, cut - Self.cutOverlap)))
        return text
    }

    /// The text of what is left at the end of the file.
    internal mutating func finish() -> String? {
        defer { pending = Data() }
        return decode(pending)
    }

    /// Tells the byte order of UTF-16 from the first bytes, and drops a byte order mark.
    private mutating func readByteOrder() {
        let mark = (pending[pending.startIndex], pending[pending.startIndex + 1])
        if mark == (0xFE, 0xFF) {
            bigEndian = true
        }
        if mark == (0xFE, 0xFF) || mark == (0xFF, 0xFE) {
            pending.removeFirst(2)
            return
        }
        // Without a mark, text in the Latin range shows in the zero bytes: they come
        // first in the big-endian order, after the letter in the little-endian one.
        var (even, odd) = (0, 0)
        for (offset, byte) in pending.prefix(256).enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) {
                even += 1
            } else {
                odd += 1
            }
        }
        bigEndian = even > odd
    }

    /// The nearest place at or before `position` where a character starts.
    private func boundary(atOrBefore position: Int) -> Int {
        switch encoding {
        case .utf8:
            if position >= pending.count {
                // The end of what there is: a character that is not all here yet waits for the next piece.
                var lead = pending.count - 1
                var back = 0
                while lead > 0, back < 3, pending[pending.startIndex + lead] & 0xC0 == 0x80 {
                    lead -= 1
                    back += 1
                }
                // (Asked only of a line longer than `longestLine`.)
                let byte = pending[pending.startIndex + lead]
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return lead + needed > pending.count ? lead : pending.count
            }
            var index = position
            while index > 0, pending[pending.startIndex + index] & 0xC0 == 0x80 {
                index -= 1
            }
            return index

        case .utf16:
            return position / 4 * 4

        case .western, .dos:
            return position
        }
    }

    /// The number of bytes up to and including the last line break.
    private func lastLineEnd() -> Int? {
        // Looked at in place, from the end: no copy of the bytes, and it stops at the line end.
        pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            guard encoding == .utf16 else {
                var index = bytes.count - 1
                while index >= 0 {
                    if bytes[index] == 0x0A {
                        return index + 1
                    }
                    index -= 1
                }
                return nil
            }
            var index = bytes.count / 2 * 2 - 2
            while index >= 0 {
                let (line, zero) = bigEndian ? (bytes[index + 1], bytes[index]) : (bytes[index], bytes[index + 1])
                if line == 0x0A, zero == 0 {
                    return index + 2
                }
                index -= 2
            }
            return nil
        }
    }

    private func decode(_ data: Data) -> String? {
        switch encoding {
        case .utf8:
            // Bytes that are no UTF-8 are replaced, not refused, so the rest of the line is still searched.
            return String(unsafeUninitializedCapacity: data.count) { buffer in
                let (_, copied) = buffer.initialize(from: data)
                return copied
            }

        case .utf16:
            return String(
                data: data.prefix(data.count / 2 * 2),
                encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian
            )

        case .western, .dos:
            return String(data: data, encoding: encoding.stringEncoding)
                ?? String(data: data, encoding: .isoLatin1)
        }
    }
}
