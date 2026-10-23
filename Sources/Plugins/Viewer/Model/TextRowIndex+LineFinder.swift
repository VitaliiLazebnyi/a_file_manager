import Darwin.C

/// How the fast scan finds line ends in raw bytes.
extension TextRowIndex {
    /// Finds the line ends in a buffer of 8-bit or 16-bit units.
    internal struct LineFinder {
        /// The bytes.
        internal let buffer: UnsafeBufferPointer<UInt8>
        /// The address of the first byte.
        internal let start: UnsafePointer<UInt8>
        /// Bytes per unit: 1 or 2.
        internal let unit: Int
        /// Whether a 16-bit unit has its high byte first.
        internal let bigEndian: Bool

        /// 0x80 in every byte of `word` that equals `byte` (and nothing in the others).
        @inline(__always)
        private static func matches(in word: UInt64, _ byte: UInt64) -> UInt64 {
            let difference = word ^ (byte &* 0x0101_0101_0101_0101)
            return
                ~(((difference & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x7F7F_7F7F_7F7F_7F7F) | difference | 0x7F7F_7F7F_7F7F_7F7F)
        }

        /// The 8 bytes from `position` on.
        @inline(__always)
        internal func load(_ position: Int) -> UInt64 {
            UnsafeRawPointer(start + position).loadUnaligned(as: UInt64.self)
        }

        /// The end of the run of LF bytes that begins at `position` (8-bit units).
        internal func emptyRun(from position: Int) -> Int {
            var run = position + 1
            while run + 8 <= buffer.count, load(run) == 0x0A0A_0A0A_0A0A_0A0A { run += 8 }
            while run < buffer.count, buffer[run] == 0x0A { run += 1 }
            return run
        }

        /// Where the line that begins at `position` ends (the buffer's end when it does not end in
        /// it), and whether it is known to hold no tab.
        ///
        /// `nextLF` and `nextCR` keep where the last searches found a line end, so no part of the
        /// buffer is searched twice.
        internal func lineEnd(
            from position: Int,
            nextLF: inout Int,
            nextCR: inout Int
        ) -> (end: Int, plainShort: Bool) {
            let probes = unit == 1 && position + 8 <= buffer.count
            if probes {
                // Short lines are the most; their ends are found without a call.
                let word = load(position)
                let ends = Self.matches(in: word, 0x0A) | Self.matches(in: word, 0x0D)
                if ends != 0 {
                    let before = ends.trailingZeroBitCount >> 3
                    let tabs = Self.matches(in: word, 0x09) & (1 << UInt64(before * 8) &- 1)
                    return (position + before, tabs == 0)
                }
            }
            let searchFrom = probes ? position + 8 : position
            if nextLF < searchFrom { nextLF = find(0x0A, from: searchFrom) }
            if nextCR < searchFrom { nextCR = find(0x0D, from: searchFrom) }
            return (min(nextLF, nextCR), false)
        }

        /// Where the line end at `lineEnd` ends: behind CR+LF, a lone CR or a LF.
        ///
        /// Nil for a CR at the end of the buffer when more is to come: whether a LF follows is not
        /// known yet.
        internal func endOfLineEnd(at lineEnd: Int, atEnd: Bool) -> Int? {
            let end = lineEnd + unit
            guard isUnit(lineEnd, 0x0D) else {
                return end
            }
            if end + unit > buffer.count {
                return atEnd ? end : nil
            }
            return isUnit(end, 0x0A) ? end + unit : end
        }

        /// The first position at or after `from` of a unit that is `byte` (a line end).
        internal func find(_ byte: UInt8, from: Int) -> Int {
            let count = buffer.count
            var position = from
            while position < count, let found = memchr(start + position, Int32(byte), count - position) {
                let foundAt = start.distance(to: found.assumingMemoryBound(to: UInt8.self))
                if unit == 1 {
                    return foundAt
                }
                // A 16-bit unit: the byte is its low half and the other one is zero.
                let first = bigEndian ? foundAt - 1 : foundAt
                let isUnitStart = first >= from && first.isMultiple(of: 2) && first + 1 < count
                if isUnitStart, buffer[bigEndian ? first : first + 1] == 0 {
                    return first
                }
                position = foundAt + 1
            }
            return count
        }

        /// Whether the unit at `position` is `byte`.
        internal func isUnit(_ position: Int, _ byte: UInt8) -> Bool {
            unit == 1
                ? buffer[position] == byte
                : bigEndian
                    ? buffer[position] == 0 && buffer[position + 1] == byte
                    : buffer[position] == byte && buffer[position + 1] == 0
        }
    }
}
