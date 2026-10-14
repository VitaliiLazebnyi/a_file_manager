import AFMKernel
import Foundation
import Testing

@testable import ViewerPlugin

/// `HTMLText.plainText(units:)` as it was before it was made fast: unit by unit, with the strings
/// of the tags made for every one. What the fast one must give exactly.
enum HTMLReference {
    static let blockTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol",
        "blockquote", "pre", "hr", "section", "article", "header", "footer", "title", "dt", "dd"
    ]
    static let skippedElements: Set<String> = ["script", "style", "noscript", "template", "svg"]

    @inline(__always) static func referenceIsWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    static func plainText(units html: [UInt16], linkBraces: Bool = true) -> HTMLText.Result? {
        var text: [UInt16] = []
        text.reserveCapacity(html.count / 2 + 16)
        var links: [String] = []
        var pendingLink: String?
        var preformatted = 0
        /// Whether the text so far is empty or ends in white space: a space is not added then.
        var endsInWhitespace = true
        html.withUnsafeBufferPointer { input in
            let count = input.count
            var index = 0
            var checked = 0

            func append(_ string: String) {
                text.append(contentsOf: string.utf16)
                endsInWhitespace = text.last.map(Self.referenceIsWhitespace) ?? true
            }
            func lineBreak() {
                while text.last == 0x20 { text.removeLast() }
                if !text.isEmpty, text.last != 0x0A { text.append(0x0A) }
                endsInWhitespace = true
            }
            @inline(__always) func emit(_ unit: UInt16) {
                if preformatted > 0 {
                    text.append(unit)
                    endsInWhitespace = referenceIsWhitespace(unit)
                } else if referenceIsWhitespace(unit) {
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
            func find(_ unit: UInt16, from: Int) -> Int {
                var position = from
                while position < count, input[position] != unit { position += 1 }
                return position
            }
            /// The position behind the next `</name` (any case) at or after `from`, or nil.
            func findClosing(_ name: [UInt8], from: Int) -> Int? {
                var position = from
                while position + 1 + name.count < count {
                    position = find(0x3C, from: position)
                    guard position + 1 + name.count < count else { return nil }
                    if input[position + 1] == 0x2F {
                        var matches = true
                        for (offset, letter) in name.enumerated() {
                            let unit = input[position + 2 + offset]
                            if (unit >= 0x41 && unit <= 0x5A ? unit | 0x20 : unit) != UInt16(letter) {
                                matches = false
                                break
                            }
                        }
                        if matches { return position + 2 + name.count }
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
                let name = String(
                    decoding: UnsafeBufferPointer(rebasing: input[ampersand + 1..<semicolon]), as: UTF16.self)
                if let replacement = HTMLText.decodeEntity(name) {
                    for unit in replacement.utf16 { emit(unit) }
                    return semicolon + 1
                }
                emit(0x26)
                return ampersand + 1
            }

            while index < count {
                if index &- checked > 1 << 20 {
                    checked = index
                }
                let unit = input[index]
                if unit == 0x26 {
                    index = entity(at: index)
                    continue
                }
                guard unit == 0x3C else {
                    emit(unit)
                    index += 1
                    continue
                }
                let open = index
                // A `<` that no tag name follows is a character of the text.
                let after: UInt16 = open + 1 < count ? input[open + 1] : 0
                guard
                    after == 0x2F || after == 0x21 || after == 0x3F || (after >= 0x41 && after <= 0x5A)
                        || (after >= 0x61 && after <= 0x7A)
                else {
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
                // The end of the tag: a `>` inside a value in quotes after `=` does not end it, if
                // the quote closes within 512 units.
                var close = count
                var quote: UInt16 = 0
                var before: UInt16 = 0
                var scan = open + 1
                while scan < min(count, open + 512) {
                    let unit = input[scan]
                    if quote != 0 {
                        if unit == quote { quote = 0 }
                    } else if unit == 0x3E {
                        close = scan
                        break
                    } else if unit == 0x22 || unit == 0x27, before == 0x3D {
                        quote = unit
                    }
                    if !referenceIsWhitespace(unit) { before = unit }
                    scan += 1
                }
                if close == count { close = find(0x3E, from: open) }
                guard close < count else { return }
                index = close + 1
                var start = open + 1
                let isClosing = start < close && input[start] == 0x2F
                while start < close, input[start] == 0x2F { start += 1 }
                var nameBytes: [UInt8] = []
                var position = start
                while position < close, nameBytes.count < 16 {
                    let letter = input[position]
                    if letter >= 0x30 && letter <= 0x39 || letter >= 0x61 && letter <= 0x7A {
                        nameBytes.append(UInt8(letter))
                    } else if letter >= 0x41, letter <= 0x5A {
                        nameBytes.append(UInt8(letter) | 0x20)
                    } else if letter >= 0x80 {
                        nameBytes.append(0xFF)
                    } else {
                        break
                    }
                    position += 1
                }
                let name = String(decoding: nameBytes, as: UTF8.self)
                if !isClosing, Self.skippedElements.contains(name) {
                    // Everything up to the matching end tag is not text.
                    if let end = findClosing(nameBytes, from: index) {
                        let after = find(0x3E, from: end)
                        index = after < count ? after + 1 : count
                    } else {
                        index = count
                    }
                } else if name == "a" {
                    if isClosing, let link = pendingLink {
                        append(linkBraces ? " {\(link)}" : " \(link)")
                        pendingLink = nil
                    } else if !isClosing {
                        let tag = String(
                            decoding: UnsafeBufferPointer(rebasing: input[open + 1..<close]), as: UTF16.self)
                        if let link = HTMLText.attribute("href", in: Substring(tag)), !link.isEmpty,
                            !link.hasPrefix("#")
                        {
                            pendingLink = HTMLText.decodeEntities(Substring(link))
                            links.append(pendingLink ?? link)
                        }
                    }
                } else if name == "pre" {
                    preformatted = max(0, preformatted + (isClosing ? -1 : 1))
                    lineBreak()
                } else if Self.blockTags.contains(name) {
                    lineBreak()
                }
            }
        }
        var lower = 0
        var upper = text.count
        while lower < upper, referenceIsWhitespace(text[lower]) { lower += 1 }
        while upper > lower, referenceIsWhitespace(text[upper - 1]) { upper -= 1 }
        let trimmed = String(decoding: text[lower..<upper], as: UTF16.self)
        return HTMLText.Result(text: trimmed + (text.isEmpty ? "" : "\n"), links: links)
    }
}
