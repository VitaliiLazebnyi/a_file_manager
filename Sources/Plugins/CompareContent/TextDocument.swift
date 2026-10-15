public import Foundation

/// How the bytes of a text file become characters (spec 09 › Loading, mode and encodings).
public enum TextEncoding: Equatable, Sendable {
    case utf8(bom: Bool)
    case utf16LittleEndian, utf16BigEndian
    /// The fallback for bytes that are not valid UTF-8: every byte is a character.
    case latin1

    public var name: String {
        switch self {
        case .utf8(let bom): return bom ? "UTF-8 (BOM)" : "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .latin1: return "Latin-1"
        }
    }

    var bom: [UInt8] {
        switch self {
        case .utf8(true): return [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: return [0xFF, 0xFE]
        case .utf16BigEndian: return [0xFE, 0xFF]
        default: return []
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LittleEndian: return .utf16LittleEndian
        case .utf16BigEndian: return .utf16BigEndian
        case .latin1: return .isoLatin1
        }
    }

    /// By byte-order mark; without one, UTF-8 when the bytes are valid UTF-8, else Latin-1.
    public static func detect(_ data: Data) -> Self {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8(bom: true) }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        return String(data: data, encoding: .utf8) != nil ? .utf8(bom: false) : .latin1
    }

    /// `detect` and `decode` in one pass over the bytes, which for UTF-8 without a mark is the
    /// validation that decides between UTF-8 and Latin-1; and whether the bytes were read without loss. A file with a
    /// byte-order mark that holds invalid sequences is shown with replacement characters; writing it
    /// back would change those bytes.
    static func decodeDetectedChecked(_ data: Data) -> (encoding: Self, text: String, isLossless: Bool) {
        if let marked = detect(prefixOf: data) {
            let body = data.dropFirst(marked.bom.count)
            if let text = String(data: body, encoding: marked.stringEncoding) { return (marked, text, true) }
            return (marked, String(decoding: body, as: UTF8.self), false)
        }
        if let text = String(data: data, encoding: .utf8) { return (.utf8(bom: false), text, true) }
        return (.latin1, Self.latin1.decode(data), true)
    }

    private static func detect(prefixOf data: Data) -> Self? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8(bom: true) }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        return nil
    }

    func decode(_ data: Data) -> String {
        let body = data.dropFirst(bom.count)
        // Broken UTF-16 (an odd byte at the end) still shows what can be read.
        return String(data: body, encoding: stringEncoding) ?? String(decoding: body, as: UTF8.self)
    }

    /// The bytes of a text; in Latin-1 a character beyond it becomes a question mark.
    func encode(_ text: String) -> Data {
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
            data.append(contentsOf: text.unicodeScalars.map { $0.value < 0x100 ? UInt8($0.value) : 0x3F })
        }
        return data
    }

    /// The bytes of a text, or nil when the encoding cannot hold it (Latin-1 and a character beyond it).
    func encodeExactly(_ text: String) -> Data? {
        text.data(using: stringEncoding, allowLossyConversion: false).map { Data(bom) + $0 }
    }
}

public enum LineEnding: String, Equatable, Sendable {
    /// The last line of a file that does not end with a line break.
    case none = ""
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

public struct TextLine: Equatable, Sendable {
    public var text: String
    public var ending: LineEnding
    /// The line's number in the file as it was loaded; 0 for lines added or changed since
    /// (spec 09 › Edit mode and saving).
    public var number: Int

    public init(_ text: String, ending: LineEnding = .lf, number: Int = 0) {
        self.text = text
        self.ending = ending
        self.number = number
    }
}

/// A text file as lines, with what is needed to write it back unchanged: its encoding and
/// every line's own line break. A value; safe to hand between threads.
public struct TextDocument: Equatable, Sendable {
    public var encoding: TextEncoding
    public var lines: [TextLine]
    /// False when the bytes loaded were not valid in the encoding and were shown with replacement
    /// characters: saving would then change them, and is refused.
    public private(set) var isLossless = true

    public init(encoding: TextEncoding = .utf8(bom: false), lines: [TextLine] = []) {
        self.encoding = encoding
        self.lines = lines
    }

    public init(data: Data, encoding: TextEncoding? = nil) {
        if let encoding {
            self.encoding = encoding
            lines = Self.split(encoding.decode(data))
        } else {
            let found = TextEncoding.decodeDetectedChecked(data)
            self.encoding = found.encoding
            isLossless = found.isLossless
            lines = Self.split(found.text)
        }
    }

    /// Cuts a text at `\n`, `\r\n` and `\r`. A text that ends with a line break has no empty
    /// line after it.
    public static func split(_ text: String) -> [TextLine] {
        var lines: [TextLine] = []
        var text = text
        text.withUTF8 { bytes in
            var start = 0
            var index = 0
            func line(to end: Int, _ ending: LineEnding) {
                lines.append(
                    TextLine(
                        String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self),
                        ending: ending,
                        number: lines.count + 1
                    )
                )
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x0A {
                    line(to: index, .lf)
                    start = index + 1
                } else if byte == 0x0D {
                    let isPair = index + 1 < bytes.count && bytes[index + 1] == 0x0A
                    line(to: index, isPair ? .crlf : .cr)
                    if isPair { index += 1 }
                    start = index + 1
                }
                index += 1
            }
            if start < bytes.count { line(to: bytes.count, .none) }
        }
        return lines
    }

    /// The line break most lines use; new lines get it, and so does a last line that had
    /// none when something is put after it. `sampleLimit` looks at that many lines at the start
    /// only (an edit in a huge file must not count them all).
    public func usualEnding(sampleLimit: Int = .max) -> LineEnding {
        var counts: [LineEnding: Int] = [:]
        for line in lines.prefix(sampleLimit) where line.ending != .none { counts[line.ending, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? .lf
    }

    public var usualEnding: LineEnding { usualEnding() }

    private func text() -> String {
        let usual = usualEnding
        var text = ""
        for (index, line) in lines.enumerated() {
            text += line.text
            // Only the last line may go without a line break.
            text += line.ending == .none && index < lines.count - 1 ? usual.rawValue : line.ending.rawValue
        }
        return text
    }

    /// The file's bytes: the same as were loaded as long as nothing was changed.
    public func data() -> Data {
        encoding.encode(text())
    }

    /// The file's bytes, or an error where they cannot be the text: characters the encoding cannot
    /// hold (they would become question marks), or a file that was not valid when loaded.
    func encodedData(named name: String) throws -> Data {
        guard isLossless else { throw CompareLoader.SaveError.invalidSequences(name, encoding) }
        guard let data = encoding.encodeExactly(text()) else {
            throw CompareLoader.SaveError.notRepresentable(name, encoding)
        }
        return data
    }

    /// Files with a zero byte near the start are shown in hex; UTF-16 text is full of them
    /// and is recognised by its byte-order mark.
    public static func looksBinary(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return false }
        return data.prefix(64 * 1_024).contains(0)
    }
}
