import Foundation

/// The ways a text can be written as bytes: escapes, hex strings, and the case forms in each encoding.
extension TextPattern {
    /// `\t`, `\n` and `\\` of a plain text (spec 09 › "Find text", Escapes).
    internal static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "t":
                    result.append("\t")

                case "n":
                    result.append("\n")

                case "\\":
                    result.append("\\")

                default:
                    result.append("\\")
                    result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped {
            result.append("\\")
        }
        return result
    }

    /// The needles of a plain `text` in all of `encodings`, each written once, and the encodings that
    /// cannot write the text.
    internal static func needles(
        for text: String,
        in encodings: [TextEncoding],
        caseSensitive: Bool,
        wholeWords: Bool
    ) -> (needles: [TextNeedle], dropped: [TextEncoding]) {
        var needles: [TextNeedle] = []
        var dropped: [TextEncoding] = []
        for encoding in encodings {
            let found = Self.needles(for: text, in: encoding, caseSensitive: caseSensitive, wholeWords: wholeWords)
            if found.isEmpty {
                dropped.append(encoding)
            }
            for needle in found
            where !needles.contains(where: { $0.elements == needle.elements && $0.unit == needle.unit }) {
                needles.append(needle)
            }
        }
        return (needles, dropped)
    }

    /// The needles of `text` in `encoding` (UTF-16 in both byte orders); none when a character of the text
    /// cannot be written in it.
    internal static func needles(
        for text: String,
        in encoding: TextEncoding,
        caseSensitive: Bool,
        wholeWords: Bool
    ) -> [TextNeedle] {
        func needle(_ stringEncoding: String.Encoding, unit: Int, bigEndian: Bool) -> TextNeedle? {
            let found = elements(of: text, in: stringEncoding, caseSensitive: caseSensitive)
            return found.isEmpty
                ? nil : TextNeedle(elements: found, unit: unit, bigEndian: bigEndian, wholeWords: wholeWords)
        }
        if encoding == .utf16 {
            return [
                needle(.utf16LittleEndian, unit: 2, bigEndian: false),
                needle(.utf16BigEndian, unit: 2, bigEndian: true)
            ]
            .compactMap(\.self)
        }
        return [needle(encoding.stringEncoding, unit: 1, bigEndian: false)].compactMap(\.self)
    }

    /// Reads `00 FF 12` and `"PK"0102`.
    ///
    /// Without "Case sensitive", the code of a lowercase letter also finds the uppercase letter;
    /// the code of an uppercase letter finds only that.
    internal static func hexElements(_ text: String, caseSensitive: Bool) throws -> [[[UInt8]]] {
        var bytes: [UInt8] = []
        var digits = ""
        var inQuotes = false
        var literal = ""
        for character in text {
            if inQuotes {
                if character == "\"" {
                    bytes += Array(literal.utf8)
                    (literal, inQuotes) = ("", false)
                } else {
                    literal.append(character)
                }
            } else if character == "\"" {
                guard digits.isEmpty else {
                    throw Problem.badHex(text)
                }
                inQuotes = true
            } else if character.isHexDigit {
                digits.append(character)
                if digits.count == 2, let byte = UInt8(digits, radix: 16) {
                    bytes.append(byte)
                    digits = ""
                }
            } else if character == " " || character == "," {
                guard digits.isEmpty else {
                    throw Problem.badHex(text)
                }
            } else {
                throw Problem.badHex(text)
            }
        }
        guard !inQuotes, digits.isEmpty, !bytes.isEmpty else {
            throw Problem.badHex(text)
        }
        return bytes.map { byte in
            !caseSensitive && (0x61...0x7A).contains(byte) ? [[byte], [byte - 0x20]] : [[byte]]
        }
    }

    /// Per character of `text`, the byte sequences that stand for it in `encoding`: as typed, and without
    /// `caseSensitive` in lower and upper case; empty when a character cannot be written in the encoding.
    private static func elements(
        of text: String,
        in encoding: String.Encoding,
        caseSensitive: Bool
    ) -> [[[UInt8]]] {
        var elements: [[[UInt8]]] = []
        for character in text {
            let forms =
                caseSensitive
                ? [String(character)]
                : [String(character), String(character).lowercased(), String(character).uppercased()]
            var alternatives: [[UInt8]] = []
            for form in forms {
                guard let data = form.data(using: encoding, allowLossyConversion: false), !data.isEmpty else {
                    continue
                }
                if !alternatives.contains(Array(data)) {
                    alternatives.append(Array(data))
                }
            }
            // The character as typed must exist in the encoding; its other case need not.
            guard String(character).data(using: encoding, allowLossyConversion: false)?.isEmpty == false else {
                return []
            }
            elements.append(alternatives)
        }
        return elements
    }
}
