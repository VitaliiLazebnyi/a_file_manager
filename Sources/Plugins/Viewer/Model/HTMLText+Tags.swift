/// How the converter finds tags and tells their kinds.
extension HTMLText {
    /// What a tag name stands for.
    internal enum TagKind {
        /// `<a>`: a link, whose target is written behind its text.
        case anchor
        /// A tag that begins a line (`p`, `div`, `br`, `li`, ...).
        case block
        /// `<pre>`: a line of its own, and white space inside is kept.
        case preformatted
        /// An element whose content is not text (`script`, `style`, ...).
        case skipped
    }

    /// A tag name of up to 16 letters, packed (the form it is looked up in).
    internal struct TagKey: Hashable {
        /// Letters 1 to 8, the first in the lowest byte.
        internal var first: UInt64 = 0
        /// Letters 9 to 16.
        internal var second: UInt64 = 0
        /// How many letters were appended.
        internal var length = 0

        /// The key of `name`, which is lower case ASCII.
        internal init(_ name: String) {
            for letter in name.utf8 { append(letter) }
        }

        /// The key of the name of a tag that starts at `start` of `input`, in lower case.
        ///
        /// The scan stops at `close`, at the first unit that is no letter or digit, or after 16. A
        /// letter that is not ASCII counts as one that no known name has.
        internal init(_ input: UnsafeBufferPointer<UInt16>, from start: Int, to close: Int) {
            var position = start
            while position < close, length < 16 {
                let letter = input[position]
                if letter >= 0x30 && letter <= 0x39 || letter >= 0x61 && letter <= 0x7A {
                    append(UInt8(letter))
                } else if letter >= 0x41, letter <= 0x5A {
                    append(UInt8(letter) | 0x20)
                } else if letter >= 0x80 {
                    append(0xFF)
                } else {
                    break
                }
                position += 1
            }
        }

        /// Adds a letter at the end (16 at most fit).
        @inline(__always)
        internal mutating func append(_ letter: UInt8) {
            if length < 8 {
                first |= UInt64(letter) << UInt64(length * 8)
            } else {
                second |= UInt64(letter) << UInt64((length - 8) * 8)
            }
            length += 1
        }
    }

    /// The tag names that mean something, in a table that is looked up with a multiplication
    /// and a compare (there are millions of tags in a page).
    internal struct TagTable {
        private var slots = [(key: TagKey, kind: TagKind)?](repeating: nil, count: 128)

        /// The table of `blockTags`, `skippedElements`, `a` and `pre`.
        internal init() {
            var entries: [(TagKey, TagKind)] = []
            for name in HTMLText.blockTags { entries.append((TagKey(name), .block)) }
            for name in HTMLText.skippedElements { entries.append((TagKey(name), .skipped)) }
            entries.append((TagKey("a"), .anchor))
            // "pre" is a block tag as well, with a meaning of its own.
            entries.removeAll { $0.0 == TagKey("pre") }
            entries.append((TagKey("pre"), .preformatted))
            for (key, kind) in entries {
                var slot = Self.slot(key)
                while slots[slot] != nil { slot = (slot + 1) & 127 }
                slots[slot] = (key, kind)
            }
        }

        @inline(__always)
        private static func slot(_ key: TagKey) -> Int {
            let mixed =
                (key.first &* 0x9E37_79B9_7F4A_7C15) ^ (key.second &* 0xC2B2_AE3D_27D4_EB4F) ^ UInt64(key.length)
            return Int(truncatingIfNeeded: (mixed &* 0xFF51_AFD7_ED55_8CCD) >> 57)
        }

        /// What the tag name `key` stands for; nil for a tag that means nothing to the text.
        @inline(__always)
        internal func kind(of key: TagKey) -> TagKind? {
            var slot = Self.slot(key)
            while let entry = slots[slot] {
                if entry.key == key {
                    return entry.kind
                }
                slot = (slot + 1) & 127
            }
            return nil
        }
    }

    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol",
        "blockquote", "pre", "hr", "section", "article", "header", "footer", "title", "dt", "dd"
    ]
    /// Elements whose content is not text.
    ///
    /// Each name has 8 letters at most (the scan relies on it).
    private static let skippedElements: Set<String> = ["script", "style", "noscript", "template", "svg"]

    /// The table of the tags that mean something, made once.
    internal static let tagTable = TagTable()

    /// How far a tag is looked at for its end with quotes taken into account.
    private static let quotedTagLimit = 512

    /// The position of the `>` that ends the tag opened at `open`: one inside a quoted value
    /// (`title="a>b"`) does not, as long as the quote closes within `quotedTagLimit` units; else
    /// the first `>` after `open`. `count` when there is none.
    @inline(__always)
    internal static func tagEnd(_ input: UnsafeBufferPointer<UInt16>, from open: Int) -> Int {
        let count = input.count
        let limit = min(count, open + quotedTagLimit)
        var position = open + 1
        var quote: UInt16 = 0
        var previous: UInt16 = 0
        while position < limit {
            let unit = input[position]
            if quote != 0 {
                if unit == quote { quote = 0 }
            } else if unit == 0x3E {
                return position
            } else if unit == 0x22 || unit == 0x27, previous == 0x3D {
                quote = unit
            }
            if !isWhitespace(unit) { previous = unit }
            position += 1
        }
        position = open + 1
        while position < count, input[position] != 0x3E { position += 1 }
        return position
    }

    /// Whether a `<` followed by this unit begins a tag, a comment or a declaration (else it is text).
    @inline(__always)
    internal static func beginsMarkup(_ unit: UInt16) -> Bool {
        unit == 0x2F || unit == 0x21 || unit == 0x3F || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
    }
}
