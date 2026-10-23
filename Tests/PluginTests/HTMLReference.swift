import Foundation

@testable import ViewerPlugin

/// `HTMLText.plainText(units:)` as it was before it was made fast: unit by unit, with the strings
/// of the tags made for every one.
///
/// What the fast one must give exactly.
internal enum HTMLReference {
    /// One pass over the HTML: the text and links found so far and where the pass is.
    internal struct Reader {
        /// The HTML as UTF-16 units.
        private let input: [UInt16]

        /// Whether a link's target is written in braces after its text.
        private let linkBraces: Bool

        /// The text so far.
        private var text: [UInt16] = []

        /// The targets of the links so far, in order.
        private var links: [String] = []

        /// The target of the open `<a>`, written after its text when it closes.
        private var pendingLink: String?

        /// How many `<pre>` elements are open: inside one, white space stays as it is.
        private var preformatted = 0

        /// Whether the text so far is empty or ends in white space: a space is not added then.
        private var endsInWhitespace = true

        /// The position of the next unit to read.
        private var index = 0

        /// A pass that starts at the first unit of `input`.
        internal init(input: [UInt16], linkBraces: Bool) {
            self.input = input
            self.linkBraces = linkBraces
            text.reserveCapacity(input.count / 2 + 16)
        }

        /// Whether `unit`, the unit after a `<`, makes the `<` the start of markup: a letter, `/`, `!` or `?`.
        private static func startsMarkup(_ unit: UInt16) -> Bool {
            unit == 0x2F || unit == 0x21 || unit == 0x3F || (unit >= 0x41 && unit <= 0x5A)
                || (unit >= 0x61 && unit <= 0x7A)
        }

        /// Reads the whole input, or up to a tag that never ends, which ends the pass.
        internal mutating func read() {
            while index < input.count {
                let unit = input[index]
                if unit == 0x26 {
                    index = entity(at: index)
                } else if unit != 0x3C {
                    emit(unit)
                    index += 1
                } else if !readMarkup(at: index) {
                    return
                }
            }
        }

        /// The text read, trimmed and ended by a line break unless it is empty, and the links' targets.
        internal func result() -> HTMLText.Result {
            var lower = 0
            var upper = text.count
            while lower < upper, HTMLReference.referenceIsWhitespace(text[lower]) { lower += 1 }
            while upper > lower, HTMLReference.referenceIsWhitespace(text[upper - 1]) { upper -= 1 }
            let trimmed = String(decoding: text[lower..<upper], as: UTF16.self)
            return HTMLText.Result(text: trimmed + (text.isEmpty ? "" : "\n"), links: links)
        }

        /// Adds `string` to the text as it is.
        private mutating func append(_ string: String) {
            text.append(contentsOf: string.utf16)
            endsInWhitespace = text.last.map(HTMLReference.referenceIsWhitespace) ?? true
        }

        /// Ends the line, unless the text is empty or already ends one; spaces before the break go.
        private mutating func lineBreak() {
            while text.last == 0x20 { text.removeLast() }
            if !text.isEmpty, text.last != 0x0A { text.append(0x0A) }
            endsInWhitespace = true
        }

        /// Adds one unit of text: outside `<pre>`, a run of white space becomes one space.
        private mutating func emit(_ unit: UInt16) {
            if preformatted > 0 {
                text.append(unit)
                endsInWhitespace = HTMLReference.referenceIsWhitespace(unit)
            } else if HTMLReference.referenceIsWhitespace(unit) {
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

        /// The first position at or after `from` that holds `unit`, or the end of the input.
        private func find(_ unit: UInt16, from: Int) -> Int {
            var position = from
            while position < input.count, input[position] != unit { position += 1 }
            return position
        }

        /// The position behind the next `</name` (any case) at or after `from`, or nil.
        private func findClosing(_ name: [UInt8], from: Int) -> Int? {
            var position = from
            while position + 1 + name.count < input.count {
                position = find(0x3C, from: position)
                guard position + 1 + name.count < input.count else {
                    return nil
                }
                if input[position + 1] == 0x2F, closingNameMatches(name, at: position + 2) {
                    return position + 2 + name.count
                }
                position += 1
            }
            return nil
        }

        /// Whether the units at `start` spell `name`, letters in any case.
        private func closingNameMatches(_ name: [UInt8], at start: Int) -> Bool {
            for (offset, letter) in name.enumerated() {
                let unit = input[start + offset]
                if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) != UInt16(letter) {
                    return false
                }
            }
            return true
        }

        /// Handles the `&` at `ampersand`: emits what its entity stands for, or the `&` itself.
        ///
        /// Returns where to go on.
        private mutating func entity(at ampersand: Int) -> Int {
            // `;` within the next 12 units of the same piece of text.
            var semicolon = -1
            var position = ampersand + 1
            while position < input.count, position <= ampersand + 12, input[position] != 0x3C {
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
            let name = String(decoding: input[ampersand + 1..<semicolon], as: UTF16.self)
            if let replacement = HTMLText.decodeEntity(name) {
                for unit in replacement.utf16 { emit(unit) }
                return semicolon + 1
            }
            emit(0x26)
            return ampersand + 1
        }

        /// Reads the `<` at `open` and the markup it starts; returns false for a tag that never ends.
        private mutating func readMarkup(at open: Int) -> Bool {
            // A `<` that no tag name follows is a character of the text.
            guard open + 1 < input.count, Self.startsMarkup(input[open + 1]) else {
                emit(0x3C)
                index += 1
                return true
            }
            if open + 3 < input.count, input[open + 1] == 0x21, input[open + 2] == 0x2D, input[open + 3] == 0x2D {
                index = commentEnd(from: open)
                return true
            }
            let close = tagEnd(from: open)
            guard close < input.count else {
                return false
            }
            index = close + 1
            readTag(from: open, to: close)
            return true
        }

        /// The position behind the comment that starts at `open`: it ends at the first `-->`, which may
        /// overlap its start, or with the input.
        private func commentEnd(from open: Int) -> Int {
            var position = open + 2
            while position + 2 < input.count {
                if input[position] == 0x2D, input[position + 1] == 0x2D, input[position + 2] == 0x3E {
                    return position + 3
                }
                position += 1
            }
            return input.count
        }

        /// The position of the `>` that ends the tag at `open`, or the end of the input.
        ///
        /// A `>` inside a value in quotes after `=` does not end it, if the quote closes within 512 units.
        private func tagEnd(from open: Int) -> Int {
            var quote: UInt16 = 0
            var before: UInt16 = 0
            var scan = open + 1
            while scan < min(input.count, open + 512) {
                let unit = input[scan]
                if quote != 0 {
                    if unit == quote { quote = 0 }
                } else if unit == 0x3E {
                    return scan
                } else if unit == 0x22 || unit == 0x27, before == 0x3D {
                    quote = unit
                }
                if !HTMLReference.referenceIsWhitespace(unit) { before = unit }
                scan += 1
            }
            return find(0x3E, from: open)
        }

        /// The tag's name in lower case, at most 16 bytes, starting at `start`; a non-ASCII unit is 0xFF.
        private func tagName(from start: Int, to close: Int) -> [UInt8] {
            var name: [UInt8] = []
            var position = start
            while position < close, name.count < 16 {
                let letter = input[position]
                if letter >= 0x30 && letter <= 0x39 || letter >= 0x61 && letter <= 0x7A {
                    name.append(UInt8(letter))
                } else if letter >= 0x41, letter <= 0x5A {
                    name.append(UInt8(letter) | 0x20)
                } else if letter >= 0x80 {
                    name.append(0xFF)
                } else {
                    break
                }
                position += 1
            }
            return name
        }

        /// Acts on the tag between `open` (its `<`) and `close` (its `>`): skips an element that is not
        /// text, follows links and `<pre>`, and breaks the line at a block.
        private mutating func readTag(from open: Int, to close: Int) {
            var start = open + 1
            let isClosing = start < close && input[start] == 0x2F
            while start < close, input[start] == 0x2F { start += 1 }
            let nameBytes = tagName(from: start, to: close)
            // A name with a non-ASCII unit is no element the reference knows of.
            let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
            if !isClosing, HTMLReference.skippedElements.contains(name) {
                index = skippedElementEnd(nameBytes)
            } else if name == "a" {
                readLink(isClosing: isClosing, tag: open + 1..<close)
            } else if name == "pre" {
                preformatted = max(0, preformatted + (isClosing ? -1 : 1))
                lineBreak()
            } else if HTMLReference.blockTags.contains(name) {
                lineBreak()
            }
        }

        /// The position behind the end tag of the skipped element `name`, or the end of the input.
        private func skippedElementEnd(_ name: [UInt8]) -> Int {
            guard let end = findClosing(name, from: index) else {
                return input.count
            }
            let behind = find(0x3E, from: end)
            return behind < input.count ? behind + 1 : input.count
        }

        /// An `<a>` keeps its target for later; its end tag writes the target after the link's text.
        private mutating func readLink(isClosing: Bool, tag: Range<Int>) {
            if isClosing, let link = pendingLink {
                append(linkBraces ? " {\(link)}" : " \(link)")
                pendingLink = nil
            } else if !isClosing {
                let tagText = String(decoding: input[tag], as: UTF16.self)
                if let link = HTMLText.attribute("href", in: Substring(tagText)), !link.isEmpty, !link.hasPrefix("#") {
                    let target = HTMLText.decodeEntities(Substring(link))
                    pendingLink = target
                    links.append(target)
                }
            }
        }
    }

    /// The elements that start and end a line of their own.
    internal static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol",
        "blockquote", "pre", "hr", "section", "article", "header", "footer", "title", "dt", "dd"
    ]

    /// The elements whose content is not text: everything up to their end tag is left out.
    internal static let skippedElements: Set<String> = ["script", "style", "noscript", "template", "svg"]

    /// Whether `unit` is white space: the units `Character.isWhitespace` holds for in the Basic
    /// Multilingual Plane.
    @inline(__always)
    internal static func referenceIsWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true

        default:
            return false
        }
    }

    /// The plain text of `html` and the targets of its links, each target after its link's text, in
    /// braces when `linkBraces` is true.
    internal static func plainText(units html: [UInt16], linkBraces: Bool) -> HTMLText.Result? {
        var reader = Reader(input: html, linkBraces: linkBraces)
        reader.read()
        return reader.result()
    }
}
