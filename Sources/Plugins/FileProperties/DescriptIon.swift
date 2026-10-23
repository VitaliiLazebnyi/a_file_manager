import Foundation

/// The file comments of one folder, as Total Commander keeps them in `descript.ion`
/// (spec 19 › `descript.ion` and `files.bbs`, 07 › File comments): one line per file, the name
/// (in double quotes when it holds a space), a space, the comment, CRLF.
///
/// A value type without any file access; `CommentStore` reads and writes it.
internal struct DescriptIon: Equatable {
    /// How the file is written.
    ///
    /// A new file is plain text, and becomes UTF-16 only when a name or a comment needs it
    /// (`CommentPreferredFormat=4`, the default).
    internal enum Encoding: Equatable {
        /// The Windows code page 1252, which is how Total Commander writes plain text.
        case ansi
        /// UTF-16 with the high byte first, after the mark `FE FF`.
        case utf16BigEndian
        /// UTF-16 with the low byte first, after the mark `FF FE`.
        case utf16LittleEndian
        /// UTF-8, with or without the mark `EF BB BF` in front.
        case utf8(bom: Bool)
    }

    /// The comment of one file.
    internal struct Entry: Equatable {
        /// The file's name as the line writes it; looked up without regard to case.
        internal var name: String
        /// With real line breaks (`\n`) between the lines.
        internal var comment: String
    }

    /// The name of the comment file in each folder.
    internal static let fileName = "descript.ion"
    /// The longest comment the format takes.
    internal static let commentLimit = 4_095
    /// Follows a comment of several lines, whose lines are joined with a literal `\n`.
    private static let multilineMarker = "\u{04}\u{C2}"

    /// In the order of the file, which is kept when the file is written again.
    internal private(set) var entries: [Entry] = []
    /// The encoding the file was read in, which it is written in again where it can be.
    internal private(set) var encoding = Encoding.ansi

    /// The comments by lower-cased name, for looking up many files of a folder.
    internal var commentsByName: [String: String] {
        Dictionary(entries.map { ($0.name.lowercased(), $0.comment) }) { first, _ in first }
    }

    /// Whether the file holds no comment at all; such a file is removed rather than written.
    internal var isEmpty: Bool { entries.isEmpty }

    /// A file without comments, written as plain text.
    internal init() {
        // Every property starts with its default.
    }

    /// Reads whatever can be read; a file that cannot be decoded gives no comments.
    internal init(data: Data) {
        self.init(decoded: Self.decode(data) ?? ("", .ansi))
    }

    /// Nil when the bytes cannot be decoded in the encoding their start announces.
    internal init?(strict data: Data) {
        guard let decoded = Self.decode(data) else {
            return nil
        }
        self.init(decoded: decoded)
    }

    private init(decoded: (String, Encoding)) {
        let (text, found) = decoded
        encoding = found
        // Lines are cut where the file has a line feed, whatever stands next to it: taken by
        // characters, a line feed that follows a carriage return would be half of one.
        for line in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = Self.parse(line.last == "\r" ? line.dropLast() : line) { entries.append(entry) }
        }
    }

    private static func decode(_ data: Data) -> (String, Encoding)? {
        func text(_ data: Data, _ encoding: String.Encoding) -> String? { String(data: data, encoding: encoding) }
        if data.starts(with: [0xFF, 0xFE]) {
            return text(data.dropFirst(2), .utf16LittleEndian).map { ($0, .utf16LittleEndian) }
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return text(data.dropFirst(2), .utf16BigEndian).map { ($0, .utf16BigEndian) }
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return text(data.dropFirst(3), .utf8).map { ($0, .utf8(bom: true)) }
        }
        // Plain ASCII reads the same either way. Text that is valid UTF-8 is taken as such;
        // anything else is the Windows code page Total Commander writes by default.
        if let utf8 = String(data: data, encoding: .utf8) {
            return (utf8, data.allSatisfy { $0 < 0x80 } ? .ansi : .utf8(bom: false))
        }
        // What the code page leaves undefined is read as Latin-1, byte for character.
        let ansi = text(data, .windowsCP1252) ?? String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) }))
        return (ansi, .ansi)
    }

    /// Reads one line.
    ///
    /// The separators (the quotes around a name, the space after it) are looked for scalar by
    /// scalar, as the file has them: taken by characters, a space or a quote followed by a
    /// combining mark is one character with it and would not be found.
    private static func parse(_ line: Substring.UnicodeScalarView) -> Entry? {
        var name: Substring.UnicodeScalarView
        var rest: Substring.UnicodeScalarView
        if line.first == "\"" {
            let body = line.dropFirst()
            guard let quote = body.firstIndex(of: "\"") else {
                return nil
            }
            (name, rest) = (body[..<quote], body[body.index(after: quote)...])
        } else {
            let space = line.firstIndex(of: " ") ?? line.endIndex
            (name, rest) = (line[..<space], line[space...])
        }
        if rest.first == " " { rest = rest.dropFirst() }
        guard !name.isEmpty else {
            return nil
        }
        var comment = String(Substring(rest))
        let marker = Array(multilineMarker.unicodeScalars)
        if rest.count >= marker.count, Array(rest.suffix(marker.count)) == marker {
            comment = String(Substring(rest.dropLast(marker.count)))
                .replacingOccurrences(
                    of: "\\n",
                    with: "\n",
                    options: .literal
                )
        }
        return Entry(name: String(Substring(name)), comment: comment)
    }

    /// Whether the file can hold a comment for this name and give it back: a name is written
    /// as it is, or between quotes when it holds a space, and nothing in the format escapes a
    /// quote or a line break.
    internal static func canName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        if scalars.isEmpty || scalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return false
        }
        let hasQuote = scalars.contains("\"")
        return !(scalars.first == "\"" || (hasQuote && scalars.contains(" ")))
    }

    /// Line ends as `\n`, and no empty lines or spaces at the end.
    internal static func normalized(_ comment: String) -> String {
        var text = comment.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while let last = text.last, last == "\n" || last == " " { text.removeLast() }
        return text
    }

    /// The text in UTF-16, without a byte-order mark.
    private static func utf16(_ text: String, bigEndian: Bool) -> Data {
        Data(
            text.utf16.flatMap { unit in
                let (high, low) = (UInt8(unit >> 8), UInt8(unit & 0xFF))
                return bigEndian ? [high, low] : [low, high]
            }
        )
    }

    /// Names are compared without regard to case, as the shipped `DESCRIPT.ION` writes them in
    /// capitals.
    internal func comment(for name: String) -> String? {
        let wanted = name.lowercased()
        return entries.first { $0.name.lowercased() == wanted }?.comment
    }

    /// Sets, replaces or (with an empty text) removes the comment of a file.
    internal mutating func setComment(_ comment: String, for name: String) {
        let text = Self.normalized(comment)
        let wanted = name.lowercased()
        let index = entries.firstIndex { $0.name.lowercased() == wanted }
        switch (index, text.isEmpty) {
        case (let index?, true):
            entries.remove(at: index)

        case (let index?, false):
            entries[index].comment = text

        case (nil, false):
            entries.append(Entry(name: name, comment: text))

        case (nil, true):
            break
        }
    }

    /// The file's bytes.
    ///
    /// The encoding the file was read in is kept as long as it can hold every character; plain text
    /// that cannot becomes UTF-16 LE with a byte-order mark.
    internal func data() -> Data {
        var text = ""
        for entry in entries {
            text += entry.name.unicodeScalars.contains(" ") ? "\"\(entry.name)\"" : entry.name
            text += " "
            if entry.comment.unicodeScalars.contains("\n") {
                text +=
                    entry.comment.replacingOccurrences(of: "\n", with: "\\n", options: .literal)
                    + Self.multilineMarker
            } else {
                text += entry.comment
            }
            text += "\r\n"
        }
        // A file without a byte-order mark must not begin with the bytes of one (a first name
        // such as `ÿþ…` would): it would be read in another encoding, or not at all. An empty
        // line in front, which every reader skips, keeps them from the start.
        func unmarked(_ data: Data) -> Data {
            let marks: [[UInt8]] = [[0xFF, 0xFE], [0xFE, 0xFF], [0xEF, 0xBB, 0xBF]]
            return marks.contains { data.starts(with: $0) } ? Data([0x0D, 0x0A]) + data : data
        }
        switch encoding {
        case .ansi:
            if let plain = text.data(using: .windowsCP1252) {
                let bytes = unmarked(plain)
                // A file without a mark is read as UTF-8 when its bytes happen to be valid
                // UTF-8, and only otherwise in the Windows code page. Names whose code-page
                // bytes are valid UTF-8 (`Ã©`, or the three bytes of a byte-order mark,
                // `ï»¿`) would come back as other names. Such a file is written as UTF-8
                // with its mark, which says what it is: every name reads back as it was.
                if bytes.contains(where: { $0 >= 0x80 }), String(data: bytes, encoding: .utf8) != nil {
                    return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
                }
                return bytes
            }
            return Data([0xFF, 0xFE]) + Self.utf16(text, bigEndian: false)

        case .utf8(let bom):
            return bom ? Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8) : unmarked(Data(text.utf8))

        case .utf16LittleEndian:
            return Data([0xFF, 0xFE]) + Self.utf16(text, bigEndian: false)

        case .utf16BigEndian:
            return Data([0xFE, 0xFF]) + Self.utf16(text, bigEndian: true)
        }
    }
}
