import AFMKernel
import Foundation

/// HTML as plain text with its links (spec 10 › HTML text (strip tags)): tags are removed,
/// the targets of links are written behind their text, in braces when asked for.
///
/// A pure function; nothing is loaded and no script runs.
enum HTMLText {
    private static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol",
        "blockquote", "pre", "hr", "section", "article", "header", "footer", "title", "dt", "dd"
    ]
    /// Elements whose content is not text.
    ///
    /// Each name has 8 letters at most (the scan relies on it).
    private static let skippedElements: Set<String> = ["script", "style", "noscript", "template", "svg"]
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…",
        "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "euro": "€", "auml": "ä", "ouml": "ö", "uuml": "ü",
        "Auml": "Ä",
        "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "bull": "•",
        "middot": "·",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "deg": "°", "times": "×"
    ]

    struct Result: Equatable {
        var text: String
        /// The targets of the links, in the order they appear.
        var links: [String]
    }

    static func plainText(from html: String, linkBraces: Bool = true) -> Result {
        convert(Array(html.utf16), linkBraces: linkBraces, cancellation: nil).result
    }

    /// White space as `Character.isWhitespace` and trimming know it.
    @inline(__always) private static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true

        default:
            return false
        }
    }

    /// What a tag name stands for.
    private enum TagKind {
        case skipped, anchor, preformatted, block
    }

    /// A tag name of up to 16 letters, packed (the form it is looked up in).
    private struct TagKey: Hashable {
        var first: UInt64 = 0
        var second: UInt64 = 0
        var length = 0

        init() {}

        init(_ name: String) {
            for letter in name.utf8 { append(letter) }
        }

        @inline(__always) mutating func append(_ letter: UInt8) {
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
    private struct TagTable {
        private var slots = [(key: TagKey, kind: TagKind)?](repeating: nil, count: 128)

        init() {
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

        @inline(__always) private static func slot(_ key: TagKey) -> Int {
            let mixed =
                (key.first &* 0x9E37_79B9_7F4A_7C15) ^ (key.second &* 0xC2B2_AE3D_27D4_EB4F) ^ UInt64(key.length)
            return Int(truncatingIfNeeded: (mixed &* 0xFF51_AFD7_ED55_8CCD) >> 57)
        }

        @inline(__always) func kind(of key: TagKey) -> TagKind? {
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

    private static let tagTable = TagTable()

    /// The entities of the most text, found without making a string of the name.
    private static let commonEntities: [(name: [UInt16], replacement: [UInt16])] =
        entities.filter { ["amp", "lt", "gt", "quot", "apos", "nbsp"].contains($0.key) }
        .map {
            (Array($0.key.utf16), Array($0.value.utf16))
        }

    /// The text for an entity name given as units, when it is one of `commonEntities`.
    @inline(__always)
    private static func commonEntity(_ name: UnsafeBufferPointer<UInt16>) -> [UInt16]? {
        guard name.count >= 2, name.count <= 4 else {
            return nil
        }
        for entity in commonEntities where entity.name.count == name.count && entity.name.elementsEqual(name) {
            return entity.replacement
        }
        return nil
    }

    @inline(__always) private static func isASCII(_ units: UnsafeBufferPointer<UInt16>) -> Bool {
        for unit in units where unit >= 0x80 { return false }
        return true
    }

    /// The range of the value of attribute `name` (lower case ASCII) in the text of a tag
    /// (without `<` and `>`): `name="x"`, `name='x'` or `name=x`, with spaces around the `=`.
    ///
    /// The attributes are walked one by one, so `data-href`, and a value that holds the text
    /// `href=` (`title='a href="x"'`), are no `href`. The first one counts.
    static func attributeRange(_ name: [UInt16], in tag: UnsafeBufferPointer<UInt16>) -> Range<Int>? {
        let count = tag.count
        var index = 0
        while index < count {
            while index < count, isWhitespace(tag[index]) || tag[index] == 0x2F { index += 1 }
            let nameStart = index
            while index < count, !isWhitespace(tag[index]), tag[index] != 0x3D { index += 1 }
            let nameEnd = index
            while index < count, isWhitespace(tag[index]) { index += 1 }
            guard index < count, tag[index] == 0x3D else { continue }
            index += 1
            while index < count, isWhitespace(tag[index]) { index += 1 }
            var value = index..<index
            if index < count, tag[index] == 0x22 || tag[index] == 0x27 {
                let quote = tag[index]
                var close = index + 1
                while close < count, tag[close] != quote { close += 1 }
                value = index + 1..<close
                index = min(count, close + 1)
            } else {
                var close = index
                while close < count, !isWhitespace(tag[close]) { close += 1 }
                value = index..<close
                index = close
            }
            guard nameEnd - nameStart == name.count else { continue }
            var matches = true
            for offset in 0..<name.count {
                let unit = tag[nameStart + offset]
                if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) != name[offset] {
                    matches = false
                    break
                }
            }
            if matches {
                return value
            }
        }
        return nil
    }

    private static let hrefName: [UInt16] = [0x68, 0x72, 0x65, 0x66]

    /// How far a tag is looked at for its end with quotes taken into account.
    private static let quotedTagLimit = 512

    /// The position of the `>` that ends the tag opened at `open`: one inside a quoted value
    /// (`title="a>b"`) does not, as long as the quote closes within `quotedTagLimit` units; else
    /// the first `>` after `open`. `count` when there is none.
    @inline(__always)
    private static func tagEnd(_ input: UnsafeBufferPointer<UInt16>, from open: Int) -> Int {
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
    private static func beginsMarkup(_ unit: UInt16) -> Bool {
        unit == 0x2F || unit == 0x21 || unit == 0x3F || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    /// `decodeEntities` for a link that is plain ASCII without CR (a character is a unit).
    private static func decodeEntities(asciiLink link: UnsafeBufferPointer<UInt16>) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(link.count)
        var index = 0
        while index < link.count {
            let unit = link[index]
            result.append(unit)
            index += 1
            guard unit == 0x26 else { continue }
            // `;` within the next 12 characters.
            var semicolon = -1
            var position = index
            while position < link.count, position < index + 12 {
                if link[position] == 0x3B {
                    semicolon = position
                    break
                }
                position += 1
            }
            guard semicolon >= 0 else { continue }
            let name = UnsafeBufferPointer(rebasing: link[index..<semicolon])
            if let replacement = commonEntity(name)
                ?? decodeEntity(String(decoding: name, as: UTF16.self)).map({ Array($0.utf16) })
            {
                result.removeLast()
                result.append(contentsOf: replacement)
                index = semicolon + 1
            }
        }
        return result
    }

    /// The same for text that is decoded already, scanned unit by unit (hundreds of megabytes a
    /// second).
    ///
    /// Nil when `cancellation` was set.
    static func plainText(units html: [UInt16], linkBraces: Bool = true, cancellation: CancellationFlag? = nil)
        -> Result?
    {
        let converted = convert(html, linkBraces: linkBraces, cancellation: cancellation)
        return converted.cancelled ? nil : converted.result
    }

    /// The text of `html`; `cancelled` when `cancellation` was set before it was all read (the
    /// text is then empty).
    private static func convert(_ html: [UInt16], linkBraces: Bool, cancellation: CancellationFlag?) -> (
        result: Result, cancelled: Bool
    ) {
        var text: [UInt16] = []
        text.reserveCapacity(html.count + 16)
        var links: [String] = []
        var pendingLink: [UInt16]?
        var preformatted = 0
        /// Whether the text so far is empty or ends in white space: a space is not added then.
        var endsInWhitespace = true
        var cancelled = false
        let tags = tagTable
        html.withUnsafeBufferPointer { input in
            let count = input.count
            var index = 0
            var checked = 0

            func lineBreak() {
                while text.last == 0x20 { text.removeLast() }
                if !text.isEmpty, text.last != 0x0A { text.append(0x0A) }
                endsInWhitespace = true
            }
            @inline(__always) func emit(_ unit: UInt16) {
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
            /// The first position at or after `from` that holds `unit`, or `count`.
            @inline(__always) func find(_ unit: UInt16, from: Int) -> Int {
                var position = from
                while position < count, input[position] != unit { position += 1 }
                return position
            }
            /// The position behind the next `</name` (any case) at or after `from`, or nil.
            func findClosing(_ name: [UInt8], from: Int) -> Int? {
                var position = from
                while position + 1 + name.count < count {
                    position = find(0x3C, from: position)
                    guard position + 1 + name.count < count else {
                        return nil
                    }
                    if input[position + 1] == 0x2F {
                        var matches = true
                        for (offset, letter) in name.enumerated() {
                            let unit = input[position + 2 + offset]
                            if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) != UInt16(letter) {
                                matches = false
                                break
                            }
                        }
                        if matches {
                            return position + 2 + name.count
                        }
                    }
                    position += 1
                }
                return nil
            }
            /// Handles the `&` at `ampersand`: emits what its entity stands for, or the `&`
            /// itself. Returns where to go on.
            func entity(at ampersand: Int) -> Int {
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
                if let replacement = commonEntity(name) {
                    for unit in replacement { emit(unit) }
                    return semicolon + 1
                }
                if let replacement = decodeEntity(String(decoding: name, as: UTF16.self)) {
                    for unit in replacement.utf16 { emit(unit) }
                    return semicolon + 1
                }
                emit(0x26)
                return ampersand + 1
            }
            /// The link of an opening `<a ...>` whose text is `input[open + 1..<close]`.
            func link(open: Int, close: Int) -> (units: [UInt16], text: String)? {
                let tag = UnsafeBufferPointer(rebasing: input[open + 1..<close])
                guard let range = attributeRange(hrefName, in: tag), !range.isEmpty, tag[range.lowerBound] != 0x23
                else { return nil }
                let value = UnsafeBufferPointer(rebasing: tag[range])
                // A CR next to a LF is one character: left to the general code.
                if isASCII(value), !value.contains(0x0D) {
                    let units = value.contains(0x26) ? decodeEntities(asciiLink: value) : Array(value)
                    return (units, String(decoding: units, as: UTF16.self))
                }
                let decoded = decodeEntities(Substring(String(decoding: value, as: UTF16.self)))
                return (Array(decoded.utf16), decoded)
            }

            while index < count {
                if index &- checked > 1 << 20 {
                    checked = index
                    if cancellation?.isCancelled == true {
                        cancelled = true
                        return
                    }
                }
                let unit = input[index]
                if unit == 0x26 {
                    index = entity(at: index)
                    continue
                }
                if unit != 0x3C {
                    // A run of text with no tag or entity in it is copied as it is, but for
                    // white space.
                    if preformatted > 0 {
                        var end = index + 1
                        let limit = min(count, index + 1 << 16)
                        while end < limit, input[end] != 0x3C, input[end] != 0x26 { end += 1 }
                        text.append(contentsOf: UnsafeBufferPointer(rebasing: input[index..<end]))
                        endsInWhitespace = isWhitespace(input[end - 1])
                        index = end
                    } else if unit > 0x20, unit < 0x85 {
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
                        index = end
                    } else {
                        emit(unit)
                        index += 1
                    }
                    continue
                }
                let open = index
                // A `<` that no tag name follows (`a < b`) is a character of the text.
                guard open + 1 < count, beginsMarkup(input[open + 1]) else {
                    emit(0x3C)
                    index += 1
                    continue
                }
                if open + 3 < count, input[open + 1] == 0x21, input[open + 2] == 0x2D, input[open + 3] == 0x2D {
                    // A comment ends at the first `-->`, which may overlap its start.
                    var position = open + 2
                    index = count
                    while position + 2 < count {
                        if input[position] == 0x2D, input[position + 1] == 0x2D, input[position + 2] == 0x3E {
                            index = position + 3
                            break
                        }
                        position += 1
                    }
                    continue
                }
                let close = tagEnd(input, from: open)
                guard close < count else {
                    return
                }
                index = close + 1
                var start = open + 1
                let isClosing = start < close && input[start] == 0x2F
                while start < close, input[start] == 0x2F { start += 1 }
                var key = TagKey()
                var position = start
                while position < close, key.length < 16 {
                    let letter = input[position]
                    if letter >= 0x30 && letter <= 0x39 || letter >= 0x61 && letter <= 0x7A {
                        key.append(UInt8(letter))
                    } else if letter >= 0x41, letter <= 0x5A {
                        key.append(UInt8(letter) | 0x20)
                    } else if letter >= 0x80 {
                        key.append(0xFF)
                    } else {
                        break
                    }
                    position += 1
                }
                let kind = tags.kind(of: key)
                if !isClosing, kind == .skipped {
                    // Everything up to the matching end tag is not text. (The names of these
                    // elements have 8 letters at most: they are all in `key.first`.)
                    let name = (0..<key.length).map { UInt8(truncatingIfNeeded: key.first >> UInt64($0 * 8)) }
                    if let end = findClosing(name, from: index) {
                        let after = find(0x3E, from: end)
                        index = after >= count ? count : after + 1
                    } else {
                        index = count
                    }
                } else if kind == .anchor {
                    if isClosing, let target = pendingLink {
                        text.append(0x20)
                        text.append(contentsOf: linkBraces ? [0x7B] + target + [0x7D] : target)
                        endsInWhitespace = isWhitespace(text[text.count - 1])
                        pendingLink = nil
                    } else if !isClosing, let found = link(open: open, close: close) {
                        pendingLink = found.units
                        links.append(found.text)
                    }
                } else if kind == .preformatted {
                    preformatted = max(0, preformatted + (isClosing ? -1 : 1))
                    lineBreak()
                } else if kind == .block {
                    lineBreak()
                }
            }
        }
        if cancelled {
            return (Result(text: "", links: []), true)
        }
        var lower = 0
        var upper = text.count
        while lower < upper, isWhitespace(text[lower]) { lower += 1 }
        while upper > lower, isWhitespace(text[upper - 1]) { upper -= 1 }
        let trimmed = String(decoding: text[lower..<upper], as: UTF16.self)
        return (Result(text: trimmed + (text.isEmpty ? "" : "\n"), links: links), false)
    }

    /// The value of an attribute of a tag: `href="x"`, `href='x'` or `href=x`.
    static func attribute(_ name: String, in tag: Substring) -> String? {
        let units = Array(tag.utf16)
        let wanted = name.utf16.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        return units.withUnsafeBufferPointer { buffer in
            attributeRange(wanted, in: buffer).map { String(decoding: buffer[$0], as: UTF16.self) }
        }
    }

    /// The text an entity name (without `&` and `;`) stands for; nil when it is not known.
    static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return entities[name]
    }

    static func decodeEntities(_ text: Substring) -> String {
        guard text.contains("&") else {
            return String(text)
        }
        var result = ""
        var rest = text
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            guard let semicolon = after.prefix(12).firstIndex(of: ";") else {
                result.append("&")
                rest = after
                continue
            }
            let name = after[..<semicolon]
            let replacement = decodeEntity(String(name))
            if let replacement {
                result += replacement
                rest = after[after.index(after: semicolon)...]
            } else {
                result.append("&")
                rest = after
            }
        }
        return result + rest
    }

    /// Whether a piece of text is a link as the context menu understands it (spec 10 ›
    /// Context menu rules): it starts with `http://`, `https://` or `www.`.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "{}<>\"'()[],;"))
        )
        let lowered = trimmed.lowercased()
        guard !trimmed.contains(" ") else {
            return nil
        }
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if lowered.hasPrefix("www.") {
            return URL(string: "https://" + trimmed)
        }
        return nil
    }
}
