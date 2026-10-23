import AFMKernel
import Foundation

/// The converter that `plainText` runs over a page.
extension HTMLText {
    /// One conversion of a page: walks its units once and builds the text and the links.
    ///
    /// Lives only inside the `withUnsafeBufferPointer` of the page, on the thread that converts it.
    internal struct Converter {
        private static let hrefName: [UInt16] = [0x68, 0x72, 0x65, 0x66]

        /// The text so far, before its ends are trimmed.
        private var text: [UInt16] = []
        /// The targets of the links so far, in the order they appear.
        private var links: [String] = []
        /// The target of the `<a>` whose text is being read; empty when none is open.
        private var pendingLink: [UInt16] = []
        private var preformatted = 0
        /// Whether the text so far is empty or ends in white space: a space is not added then.
        private var endsInWhitespace = true
        private let input: UnsafeBufferPointer<UInt16>
        private let count: Int
        private let linkBraces: Bool

        /// A conversion of `input`, with the link targets in braces when `linkBraces` is set.
        internal init(_ input: UnsafeBufferPointer<UInt16>, linkBraces: Bool) {
            self.input = input
            count = input.count
            self.linkBraces = linkBraces
            text.reserveCapacity(input.count + 16)
        }

        /// Converts the whole input; false when `cancellation` was set before the end (it is looked
        /// at once per megabyte).
        internal mutating func run(cancellation: CancellationFlag?) -> Bool {
            var index = 0
            var checked = 0
            while index < count {
                if index &- checked > 1 << 20 {
                    checked = index
                    if cancellation?.isCancelled == true {
                        return false
                    }
                }
                let unit = input[index]
                if unit == 0x26 {
                    index = entity(at: index)
                } else if unit != 0x3C {
                    index = copyText(from: index)
                } else if let next = markup(at: index) {
                    index = next
                } else {
                    // A tag that is never closed: the rest is not text.
                    break
                }
            }
            return true
        }

        /// The text with white space trimmed from its ends and one line end behind it, and the
        /// links.
        internal func result() -> Result {
            var lower = 0
            var upper = text.count
            while lower < upper, isWhitespace(text[lower]) { lower += 1 }
            while upper > lower, isWhitespace(text[upper - 1]) { upper -= 1 }
            let trimmed = String(decoding: text[lower..<upper], as: UTF16.self)
            return Result(text: trimmed + (text.isEmpty ? "" : "\n"), links: links)
        }

        private mutating func lineBreak() {
            while text.last == 0x20 { text.removeLast() }
            if !text.isEmpty, text.last != 0x0A { text.append(0x0A) }
            endsInWhitespace = true
        }

        @inline(__always)
        private mutating func emit(_ unit: UInt16) {
            if preformatted > 0 {
                text.append(unit)
                endsInWhitespace = isWhitespace(unit)
            } else if isWhitespace(unit) {
                // Runs of white space, line breaks included, are one space.
                if !endsInWhitespace {
                    text.append(0x20)
                    endsInWhitespace = true
                }
            } else {
                text.append(unit)
                endsInWhitespace = false
            }
        }

        /// Copies the text that starts at `index`, which is no `<` or `&`; returns where to go on.
        ///
        /// A run of text with no tag or entity in it is copied as it is, but for white space.
        private mutating func copyText(from index: Int) -> Int {
            let unit = input[index]
            if preformatted > 0 {
                var end = index + 1
                let limit = min(count, index + 1 << 16)
                while end < limit, input[end] != 0x3C, input[end] != 0x26 { end += 1 }
                text.append(contentsOf: UnsafeBufferPointer(rebasing: input[index..<end]))
                endsInWhitespace = isWhitespace(input[end - 1])
                return end
            }
            guard unit > 0x20, unit < 0x85 else {
                emit(unit)
                return index + 1
            }
            var end = index + 1
            // (Not too far at a time: the flag is looked at between two runs.)
            let limit = min(count, index + 1 << 16)
            while end < limit {
                let next = input[end]
                if next <= 0x20 || next >= 0x85 || next == 0x3C || next == 0x26 { break }
                end += 1
            }
            text.append(contentsOf: UnsafeBufferPointer(rebasing: input[index..<end]))
            endsInWhitespace = false
            return end
        }

        /// The first position at or after `from` that holds `unit`, or `count`.
        @inline(__always)
        private func find(_ unit: UInt16, from: Int) -> Int {
            var position = from
            while position < count, input[position] != unit { position += 1 }
            return position
        }

        /// The position behind the next `</name` (any case) at or after `from`, or nil.
        private func findClosing(_ name: [UInt8], from: Int) -> Int? {
            var position = from
            while position + 1 + name.count < count {
                position = find(0x3C, from: position)
                guard position + 1 + name.count < count else {
                    return nil
                }
                if input[position + 1] == 0x2F, endTagMatches(name, at: position) {
                    return position + 2 + name.count
                }
                position += 1
            }
            return nil
        }

        /// Whether the `</` at `position` is followed by `name` (any case).
        private func endTagMatches(_ name: [UInt8], at position: Int) -> Bool {
            for (offset, letter) in name.enumerated() {
                let unit = input[position + 2 + offset]
                if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) != UInt16(letter) {
                    return false
                }
            }
            return true
        }

        /// Handles the `&` at `ampersand` and returns where to go on.
        ///
        /// Emits what its entity stands for, or the `&` itself.
        private mutating func entity(at ampersand: Int) -> Int {
            // `;` within the next 12 units of the same piece of text.
            var semicolon = -1
            var position = ampersand + 1
            while position < count, position <= ampersand + 12, input[position] != 0x3C {
                if input[position] == 0x3B {
                    semicolon = position
                    break
                }
                position += 1
            }
            guard semicolon > 0 else {
                emit(0x26)
                return ampersand + 1
            }
            let name = UnsafeBufferPointer(rebasing: input[ampersand + 1..<semicolon])
            let common = HTMLText.commonEntity(name)
            if !common.isEmpty {
                for unit in common { emit(unit) }
                return semicolon + 1
            }
            if let replacement = decodeEntity(String(decoding: name, as: UTF16.self)) {
                for unit in replacement.utf16 { emit(unit) }
                return semicolon + 1
            }
            emit(0x26)
            return ampersand + 1
        }

        /// Handles the `<` at `open` and returns where to go on; nil when the tag is not closed.
        ///
        /// The `<` is a character of the text, or begins a comment or a tag.
        private mutating func markup(at open: Int) -> Int? {
            // A `<` that no tag name follows (`a < b`) is a character of the text.
            guard open + 1 < count, HTMLText.beginsMarkup(input[open + 1]) else {
                emit(0x3C)
                return open + 1
            }
            if open + 3 < count, input[open + 1] == 0x21, input[open + 2] == 0x2D, input[open + 3] == 0x2D {
                return commentEnd(open)
            }
            let close = HTMLText.tagEnd(input, from: open)
            guard close < count else {
                return nil
            }
            return tag(open: open, close: close)
        }

        /// The position behind the comment opened at `open`: it ends at the first `-->`, which may
        /// overlap its start; `count` when there is none.
        private func commentEnd(_ open: Int) -> Int {
            var position = open + 2
            while position + 2 < count {
                if input[position] == 0x2D, input[position + 1] == 0x2D, input[position + 2] == 0x3E {
                    return position + 3
                }
                position += 1
            }
            return count
        }

        /// Handles the tag `input[open...close]`; returns where to go on.
        private mutating func tag(open: Int, close: Int) -> Int {
            var start = open + 1
            let isClosing = start < close && input[start] == 0x2F
            while start < close, input[start] == 0x2F { start += 1 }
            let key = TagKey(input, from: start, to: close)
            switch HTMLText.tagTable.kind(of: key) {
            case .anchor:
                anchor(open: open, close: close, isClosing: isClosing)

            case .block:
                lineBreak()

            case .preformatted:
                preformatted = max(0, preformatted + (isClosing ? -1 : 1))
                lineBreak()

            case .skipped:
                if !isClosing {
                    return skipElement(key, from: close + 1)
                }

            case nil:
                break
            }
            return close + 1
        }

        /// The position behind the end tag of the element `key` whose content starts at `from`:
        /// everything up to it is not text. `count` when it is never closed.
        private func skipElement(_ key: TagKey, from: Int) -> Int {
            // The names of these elements have 8 letters at most: they are all in `key.first`.
            let name = (0..<key.length).map { UInt8(truncatingIfNeeded: key.first >> UInt64($0 * 8)) }
            guard let end = findClosing(name, from: from) else {
                return count
            }
            let after = find(0x3E, from: end)
            return after >= count ? count : after + 1
        }

        /// An `<a ...>` opens a link, whose target is written behind its text when the `</a>`
        /// comes.
        private mutating func anchor(open: Int, close: Int, isClosing: Bool) {
            if isClosing {
                guard !pendingLink.isEmpty else {
                    return
                }
                text.append(0x20)
                text.append(contentsOf: linkBraces ? [0x7B] + pendingLink + [0x7D] : pendingLink)
                endsInWhitespace = isWhitespace(text[text.count - 1])
                pendingLink = []
            } else if let found = link(open: open, close: close) {
                pendingLink = found.units
                links.append(found.text)
            }
        }

        /// The link of an opening `<a ...>` whose text is `input[open + 1..<close]`.
        private func link(open: Int, close: Int) -> (units: [UInt16], text: String)? {
            let tag = UnsafeBufferPointer(rebasing: input[open + 1..<close])
            guard let range = attributeRange(Self.hrefName, in: tag), !range.isEmpty, tag[range.lowerBound] != 0x23
            else { return nil }
            let value = UnsafeBufferPointer(rebasing: tag[range])
            // A CR next to a LF is one character: left to the general code.
            if HTMLText.isASCII(value), !value.contains(0x0D) {
                let units = value.contains(0x26) ? HTMLText.decodeEntities(asciiLink: value) : Array(value)
                return (units, String(decoding: units, as: UTF16.self))
            }
            let decoded = HTMLText.decodeEntities(Substring(String(decoding: value, as: UTF16.self)))
            return (Array(decoded.utf16), decoded)
        }
    }
}
