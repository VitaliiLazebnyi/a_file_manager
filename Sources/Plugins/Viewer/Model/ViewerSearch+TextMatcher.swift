import Foundation

/// How a text is found in decoded units.
extension ViewerSearch {
    /// Finds a text in decoded UTF-16 units, the same way whatever the chunk it is looked for
    /// in.
    ///
    /// Without case, both sides are folded a character at a time (ß and ss are the same, as are the
    /// ligatures and the Kelvin sign) and a match must begin and end at the border of a character
    /// of the text; nothing is skipped over, so a control character in the text is a character that
    /// does not match, as it is in the raw bytes.
    internal struct TextMatcher {
        private let needle: [UInt16]
        private let caseSensitive: Bool

        /// A matcher of `text`, folded once when the case does not matter.
        internal init(_ text: String, caseSensitive: Bool) {
            self.caseSensitive = caseSensitive
            let units = Array(text.utf16)
            if caseSensitive {
                needle = units
            } else {
                var cache: [UInt32: [UInt16]] = [:]
                var folded: [UInt16] = []
                var index = 0
                while index < units.count {
                    let (value, width) = Self.character(units, at: index)
                    if units[index] < 0x80 {
                        folded.append(units[index] >= 0x41 && units[index] <= 0x5A ? units[index] | 0x20 : units[index])
                    } else {
                        let piece = Self.fold(value, &cache)
                        folded.append(contentsOf: piece.isEmpty ? Array(units[index..<index + width]) : piece)
                    }
                    index += width
                }
                needle = folded
            }
        }

        /// The scalar value at `index` and how many units it takes (a lone surrogate is its own value).
        @inline(__always)
        private static func character(_ units: [UInt16], at index: Int) -> (value: UInt32, width: Int) {
            let unit = units[index]
            if unit >= 0xD800, unit <= 0xDBFF, index + 1 < units.count, units[index + 1] >= 0xDC00,
                units[index + 1] <= 0xDFFF
            {
                return (0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00), 2)
            }
            return (UInt32(unit), 1)
        }

        /// What a character folds to; empty when it folds to itself (no character folds to nothing).
        private static func fold(_ value: UInt32, _ cache: inout [UInt32: [UInt16]]) -> [UInt16] {
            guard let scalar = Unicode.Scalar(value), scalar.properties.changesWhenCaseFolded else {
                return []
            }
            if let known = cache[value] {
                return known
            }
            let folded = Array(String(Character(scalar)).folding(options: [.caseInsensitive], locale: nil).utf16)
            cache[value] = folded
            return folded
        }

        /// Where the match of the needle that begins at `start` ends, if there is one: the folded
        /// characters from `start` on are exactly the needle, and its last character is whole.
        private func end(ofMatchAt start: Int, in units: [UInt16], _ cache: inout [UInt32: [UInt16]]) -> Int? {
            var matched = 0
            var index = start
            let count = units.count
            let length = needle.count
            while matched < length {
                guard index < count else {
                    return nil
                }
                let unit = units[index]
                if unit < 0x80 {
                    guard needle[matched] == (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) else {
                        return nil
                    }
                    matched += 1
                    index += 1
                    continue
                }
                let (value, width) = Self.character(units, at: index)
                let folded = Self.fold(value, &cache)
                if !folded.isEmpty {
                    guard matched + folded.count <= length else {
                        return nil
                    }
                    for offset in 0..<folded.count where needle[matched + offset] != folded[offset] { return nil }
                    matched += folded.count
                } else {
                    guard matched + width <= length, needle[matched] == unit,
                        width == 1 || needle[matched + 1] == units[index + 1]
                    else { return nil }
                    matched += width
                }
                index += width
            }
            return index
        }

        /// The first (or last) match that begins in the units `first..<end`, and ends in `units`
        /// (it may reach behind `end`) and for which `accepts` holds; units are indexes into `units`.
        internal func find(in units: [UInt16], from first: Int, before end: Int, last: Bool, accepts: (NSRange) -> Bool)
            -> NSRange?
        {
            guard !needle.isEmpty, first >= 0, first < end, first < units.count else {
                return nil
            }
            let stop = min(end, units.count)
            return caseSensitive
                ? findExact(in: units, from: first, before: stop, last: last, accepts: accepts)
                : findFolded(in: units, from: first, before: stop, last: last, accepts: accepts)
        }

        /// `find` when the case matters: the units are compared as they are.
        private func findExact(
            in units: [UInt16],
            from first: Int,
            before end: Int,
            last: Bool,
            accepts: (NSRange) -> Bool
        ) -> NSRange? {
            let length = needle.count
            guard units.count >= length else {
                return nil
            }
            var position = last ? min(end - 1, units.count - length) : first
            while last ? position >= first : position < end && position + length <= units.count {
                if units[position] == needle[0], matches(units, at: position) {
                    let range = NSRange(location: position, length: length)
                    if accepts(range) {
                        return range
                    }
                }
                position += last ? -1 : 1
            }
            return nil
        }

        /// `find` without case: the characters of the units are folded as they are compared.
        private func findFolded(
            in units: [UInt16],
            from first: Int,
            before end: Int,
            last: Bool,
            accepts: (NSRange) -> Bool
        ) -> NSRange? {
            var cache: [UInt32: [UInt16]] = [:]
            let initial = needle[0]
            var index = last ? end - 1 : first
            while last ? index >= first : index < end {
                let unit = units[index]
                var width = 1
                if unit < 0x80 {
                    // Most characters are told apart by the first unit alone.
                    if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) == initial,
                        let found = match(at: index, in: units, &cache, accepts: accepts)
                    {
                        return found
                    }
                } else if last, unit >= 0xDC00, unit <= 0xDFFF, index > first, units[index - 1] >= 0xD800,
                    units[index - 1] <= 0xDBFF
                {
                    // The second half of a pair is no place for a match to begin.
                    index -= 1
                    continue
                } else {
                    width = Self.character(units, at: index).width
                    if let found = match(at: index, in: units, &cache, accepts: accepts) {
                        return found
                    }
                }
                index += last ? -1 : width
            }
            return nil
        }

        /// The match that begins at `index`, when there is one and `accepts` holds for it.
        private func match(
            at index: Int,
            in units: [UInt16],
            _ cache: inout [UInt32: [UInt16]],
            accepts: (NSRange) -> Bool
        ) -> NSRange? {
            guard let matchEnd = end(ofMatchAt: index, in: units, &cache) else {
                return nil
            }
            let range = NSRange(location: index, length: matchEnd - index)
            return accepts(range) ? range : nil
        }

        private func matches(_ units: [UInt16], at position: Int) -> Bool {
            for offset in 1..<max(1, needle.count) where units[position + offset] != needle[offset] { return false }
            return true
        }
    }
}
