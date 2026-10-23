import AFMKernel
import Foundation

/// HTML as plain text with its links (spec 10 › HTML text (strip tags)): tags are removed,
/// the targets of links are written behind their text, in braces when asked for.
///
/// A pure function; nothing is loaded and no script runs.
internal enum HTMLText {
    /// The text of a page and the targets of its links.
    internal struct Result: Equatable {
        /// The text, trimmed at both ends and ended by a line end (empty for a page without text).
        internal var text: String
        /// The targets of the links, in the order they appear.
        internal var links: [String]
    }

    /// The named entities that are decoded (name → text); the numeric ones are decoded from
    /// their number.
    internal static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…",
        "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "euro": "€", "auml": "ä", "ouml": "ö", "uuml": "ü",
        "Auml": "Ä",
        "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "bull": "•",
        "middot": "·",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "deg": "°", "times": "×"
    ]

    /// The entities of the most text, found without making a string of the name.
    private static let commonEntities: [(name: [UInt16], replacement: [UInt16])] =
        Self.entities.filter { ["amp", "lt", "gt", "quot", "apos", "nbsp"].contains($0.key) }
        .map { entity in
            (Array(entity.key.utf16), Array(entity.value.utf16))
        }

    /// The text of `html`, with the targets of its links behind their text, in braces when
    /// `linkBraces` is set.
    internal static func plainText(from html: String, linkBraces: Bool) -> Result {
        convert(Array(html.utf16), linkBraces: linkBraces, cancellation: nil).result
    }

    /// The same for text that is decoded already, scanned unit by unit (hundreds of megabytes a
    /// second).
    ///
    /// Nil when `cancellation` was set.
    internal static func plainText(units html: [UInt16], linkBraces: Bool, cancellation: CancellationFlag?)
        -> Result?
    {
        let converted = convert(html, linkBraces: linkBraces, cancellation: cancellation)
        return converted.cancelled ? nil : converted.result
    }

    /// White space as `Character.isWhitespace` and trimming know it.
    @inline(__always)
    internal static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true

        default:
            return false
        }
    }

    /// The range of the value of attribute `name` (lower case ASCII) in the text of a tag
    /// (without `<` and `>`): `name="x"`, `name='x'` or `name=x`, with spaces around the `=`.
    ///
    /// The attributes are walked one by one, so `data-href`, and a value that holds the text
    /// `href=` (`title='a href="x"'`), are no `href`. The first one counts.
    internal static func attributeRange(_ name: [UInt16], in tag: UnsafeBufferPointer<UInt16>) -> Range<Int>? {
        let count = tag.count
        var index = 0
        while index < count {
            while index < count, isWhitespace(tag[index]) || tag[index] == 0x2F { index += 1 }
            let nameStart = index
            while index < count, !isWhitespace(tag[index]), tag[index] != 0x3D { index += 1 }
            let nameEnd = index
            index = skipWhitespace(tag, from: index)
            guard index < count, tag[index] == 0x3D else { continue }
            let value = attributeValue(tag, at: skipWhitespace(tag, from: index + 1))
            index = value.next
            if isName(name, UnsafeBufferPointer(rebasing: tag[nameStart..<nameEnd])) {
                return value.range
            }
        }
        return nil
    }

    /// The first position at or after `from` in `tag` that holds no white space, or its end.
    private static func skipWhitespace(_ tag: UnsafeBufferPointer<UInt16>, from: Int) -> Int {
        var index = from
        while index < tag.count, isWhitespace(tag[index]) { index += 1 }
        return index
    }

    /// The value of an attribute that starts at `index` of `tag` (behind the `=` and its spaces):
    /// the text between quotes, or up to the next white space; and the position behind it.
    private static func attributeValue(_ tag: UnsafeBufferPointer<UInt16>, at index: Int) -> (
        range: Range<Int>, next: Int
    ) {
        let count = tag.count
        if index < count, tag[index] == 0x22 || tag[index] == 0x27 {
            let quote = tag[index]
            var close = index + 1
            while close < count, tag[close] != quote { close += 1 }
            return (index + 1..<close, min(count, close + 1))
        }
        var close = index
        while close < count, !isWhitespace(tag[close]) { close += 1 }
        return (index..<close, close)
    }

    /// Whether `found`, an attribute name of a tag, is `name` (lower case ASCII), in any case.
    private static func isName(_ name: [UInt16], _ found: UnsafeBufferPointer<UInt16>) -> Bool {
        guard found.count == name.count else {
            return false
        }
        for (unit, wanted) in zip(found, name) where (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) != wanted {
            return false
        }
        return true
    }

    /// The text of `html`; `cancelled` when `cancellation` was set before it was all read (the
    /// text is then empty).
    private static func convert(_ html: [UInt16], linkBraces: Bool, cancellation: CancellationFlag?) -> (
        result: Result, cancelled: Bool
    ) {
        html.withUnsafeBufferPointer { input in
            var converter = Converter(input, linkBraces: linkBraces)
            guard converter.run(cancellation: cancellation) else {
                return (Result(text: "", links: []), true)
            }
            return (converter.result(), false)
        }
    }

    /// The text for an entity name given as units, when it is one of `commonEntities`; empty
    /// when it is not.
    @inline(__always)
    internal static func commonEntity(_ name: UnsafeBufferPointer<UInt16>) -> [UInt16] {
        guard name.count >= 2, name.count <= 4 else {
            return []
        }
        for entity in commonEntities where entity.name.count == name.count && entity.name.elementsEqual(name) {
            return entity.replacement
        }
        return []
    }

    /// Whether every unit is ASCII (below 0x80).
    @inline(__always)
    internal static func isASCII(_ units: UnsafeBufferPointer<UInt16>) -> Bool {
        for unit in units where unit >= 0x80 { return false }
        return true
    }

    /// `decodeEntities` for a link that is plain ASCII without CR (a character is a unit).
    internal static func decodeEntities(asciiLink link: UnsafeBufferPointer<UInt16>) -> [UInt16] {
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
            var replacement = commonEntity(name)
            if replacement.isEmpty, let decoded = decodeEntity(String(decoding: name, as: UTF16.self)) {
                replacement = Array(decoded.utf16)
            }
            if !replacement.isEmpty {
                result.removeLast()
                result.append(contentsOf: replacement)
                index = semicolon + 1
            }
        }
        return result
    }

    /// The value of an attribute of a tag: `href="x"`, `href='x'` or `href=x`.
    internal static func attribute(_ name: String, in tag: Substring) -> String? {
        let units = Array(tag.utf16)
        let wanted = name.utf16.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        return units.withUnsafeBufferPointer { buffer in
            attributeRange(wanted, in: buffer).map { String(decoding: buffer[$0], as: UTF16.self) }
        }
    }

    /// The text an entity name (without `&` and `;`) stands for; nil when it is not known.
    internal static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return entities[name]
    }

    /// `text` with every entity it holds replaced by what it stands for; an `&` that begins no
    /// known entity stays as it is.
    internal static func decodeEntities(_ text: Substring) -> String {
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
    internal static func url(from text: String) -> URL? {
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
