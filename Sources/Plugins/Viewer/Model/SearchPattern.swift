import Foundation

/// What the user typed into the Find dialog, made ready for searching (spec 10 › Pattern
/// rules).
///
/// An immutable value; safe to share between the searching threads.
internal struct SearchPattern {
    /// What is searched for.
    internal enum Kind {
        /// These bytes, as they are (a hex string).
        case bytes([UInt8])
        /// A regular expression (also a text with a line break in it).
        case expression(NSRegularExpression)
        /// A text, unescaped.
        case text(String)
    }

    /// Stands for `\n` between unescaping and building the search.
    private static let lineBreak: Character = "\u{E000}"

    /// What is searched for.
    internal let kind: Kind
    /// Only whole words (never for bytes).
    internal let wholeWords: Bool
    /// Letters must match in case.
    internal let caseSensitive: Bool

    /// The pattern of `text` with the switches of `options`; throws `SearchError` when it cannot
    /// be searched for.
    ///
    /// `encoding` is the encoding the file is shown in; quoted text in a hex string is searched
    /// as its bytes in that encoding.
    internal init(_ text: String, options: SearchOptions, encoding: ViewerEncoding) throws {
        guard !text.isEmpty else { throw SearchError.empty }
        wholeWords = options.wholeWords && !options.hex
        caseSensitive = options.caseSensitive
        let insensitive: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        func expression(_ pattern: String) throws -> Kind {
            do {
                return .expression(
                    try NSRegularExpression(pattern: pattern, options: insensitive.union(.anchorsMatchLines))
                )
            } catch {
                throw SearchError.badExpression(error.localizedDescription)
            }
        }
        if options.hex {
            kind = .bytes(try Self.hexBytes(text, encoding: encoding))
        } else if options.regex {
            kind = try expression(text)
        } else {
            // Not empty: unescaping turns every character into one or more.
            let plain = Self.unescape(text)
            // `\n` stands for a line break. The specification's Lister finds CR+LF only; files
            // on a Mac end their lines with LF, so every kind of line break is found.
            if plain.contains(Self.lineBreak) {
                let parts = plain.components(separatedBy: String(Self.lineBreak))
                    .map(NSRegularExpression.escapedPattern(for:))
                kind = try expression(parts.joined(separator: "(?:\\r\\n|\\r|\\n)"))
            } else {
                kind = .text(plain)
            }
        }
    }

    /// `\t` is a tab, `\n` a line break, `\\` one backslash; any other backslash is itself.
    internal static func unescape(_ text: String) -> String {
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch characters.next() {
            case "t":
                result.append("\t")

            case "n":
                result.append(lineBreak)

            case "\\":
                result.append("\\")

            case let other?:
                result.append("\\\(other)")

            case nil:
                result.append("\\")
            }
        }
        return result
    }

    /// `00 FF 12`, with or without spaces; text in double quotes stands for its bytes: `"PK"0102`.
    internal static func hexBytes(_ text: String, encoding: ViewerEncoding) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var pending: UInt8?
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\"" {
                guard pending == nil, let literal = quoted(&characters), let encoded = try? encoding.encode(literal)
                else { throw SearchError.badHex(text) }
                bytes += encoded
            } else if let digit = character.hexDigitValue, character.isASCII {
                if let high = pending {
                    bytes.append(high << 4 | UInt8(digit))
                    pending = nil
                } else {
                    pending = UInt8(digit)
                }
            } else if character == " " || character == "," {
                guard pending == nil else { throw SearchError.badHex(text) }
            } else {
                throw SearchError.badHex(text)
            }
        }
        guard pending == nil, !bytes.isEmpty else { throw SearchError.badHex(text) }
        return bytes
    }

    /// The text up to the next double quote, which is taken too; nil when no quote follows.
    private static func quoted(_ characters: inout String.Iterator) -> String? {
        var literal = ""
        while let next = characters.next() {
            if next == "\"" {
                return literal
            }
            literal.append(next)
        }
        return nil
    }
}
