public import Foundation

/// How the bytes of a text file become characters (spec 09 › Loading, mode and encodings).
public enum TextEncoding: Equatable, Sendable {
    /// The fallback for bytes that are not valid UTF-8: every byte is a character.
    case latin1
    /// UTF-16 with the high byte first, as its byte-order mark says.
    case utf16BigEndian
    /// UTF-16 with the low byte first, as its byte-order mark says.
    case utf16LittleEndian
    /// UTF-8, with or without a byte-order mark.
    case utf8(bom: Bool)

    /// A text decoded with the encoding found for it.
    internal struct Decoded {
        /// The encoding found: by byte-order mark, else UTF-8 when the bytes are valid UTF-8, else Latin-1.
        internal var encoding: TextEncoding
        /// The text.
        internal var text: String
        /// False when the bytes were not valid in the encoding and replacement characters stand for them.
        internal var isLossless: Bool
    }

    /// The name shown in the status line.
    public var name: String {
        switch self {
        case .utf8(let bom):
            return bom ? "UTF-8 (BOM)" : "UTF-8"

        case .utf16LittleEndian:
            return "UTF-16 LE"

        case .utf16BigEndian:
            return "UTF-16 BE"

        case .latin1:
            return "Latin-1"
        }
    }

    /// The byte-order mark the file starts with; empty for none.
    internal var bom: [UInt8] {
        switch self {
        case .utf8(true):
            return [0xEF, 0xBB, 0xBF]

        case .utf16LittleEndian:
            return [0xFF, 0xFE]

        case .utf16BigEndian:
            return [0xFE, 0xFF]

        default:
            return []
        }
    }

    /// The encoding as Foundation names it.
    internal var stringEncoding: String.Encoding {
        switch self {
        case .utf8:
            return .utf8

        case .utf16LittleEndian:
            return .utf16LittleEndian

        case .utf16BigEndian:
            return .utf16BigEndian

        case .latin1:
            return .isoLatin1
        }
    }

    /// By byte-order mark; without one, UTF-8 when the bytes are valid UTF-8, else Latin-1.
    public static func detect(_ data: Data) -> Self {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8(bom: true)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }
        return String(data: data, encoding: .utf8) != nil ? .utf8(bom: false) : .latin1
    }

    /// `detect` and `decode` in one pass over the bytes, which for UTF-8 without a mark is the
    /// validation that decides between UTF-8 and Latin-1; and whether the bytes were read without loss.
    ///
    /// A file with a byte-order mark that holds invalid sequences is shown with replacement
    /// characters; writing it back would change those bytes.
    internal static func decodeDetectedChecked(_ data: Data) -> Decoded {
        if let marked = detect(prefixOf: data) {
            let body = data.dropFirst(marked.bom.count)
            if let text = String(data: body, encoding: marked.stringEncoding) {
                return Decoded(encoding: marked, text: text, isLossless: true)
            }
            return Decoded(encoding: marked, text: String(repairingUTF8: body), isLossless: false)
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(encoding: .utf8(bom: false), text: text, isLossless: true)
        }
        return Decoded(encoding: .latin1, text: Self.latin1.decode(data), isLossless: true)
    }

    /// The encoding that the byte-order mark at the start of `data` names; nil without one.
    private static func detect(prefixOf data: Data) -> Self? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8(bom: true)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }
        return nil
    }

    /// The text of `data` in this encoding, after its byte-order mark.
    internal func decode(_ data: Data) -> String {
        let body = data.dropFirst(bom.count)
        // Broken UTF-16 (an odd byte at the end) still shows what can be read.
        return String(data: body, encoding: stringEncoding) ?? String(repairingUTF8: body)
    }

    /// The bytes of a text; in Latin-1 a character beyond it becomes a question mark.
    internal func encode(_ text: String) -> Data {
        var data = Data(bom)
        switch self {
        case .utf8:
            data.append(contentsOf: text.utf8)

        case .utf16LittleEndian:
            for unit in text.utf16 {
                data.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(truncatingIfNeeded: unit >> 8)])
            }

        case .utf16BigEndian:
            for unit in text.utf16 {
                data.append(contentsOf: [UInt8(truncatingIfNeeded: unit >> 8), UInt8(truncatingIfNeeded: unit)])
            }

        case .latin1:
            data.append(
                contentsOf: text.unicodeScalars.map { scalar in scalar.value < 0x100 ? UInt8(scalar.value) : 0x3F }
            )
        }
        return data
    }

    /// The bytes of a text, or nil when the encoding cannot hold it (Latin-1 and a character beyond it).
    internal func encodeExactly(_ text: String) -> Data? {
        text.data(using: stringEncoding, allowLossyConversion: false).map { encoded in Data(bom) + encoded }
    }
}
