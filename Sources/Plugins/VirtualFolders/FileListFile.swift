public import AFMKernel
public import Foundation

/// A text file that names one file per line (spec 19 › List files).
///
/// Lines are full paths or paths relative to a base directory; empty lines are skipped.
///
/// A name that holds a line break or another control character, or starts or ends with a
/// space or a quote, cannot stand on a line as it is. It is written in quotes with backslash
/// escapes (`"a\nb"`: `\\`, `\"`, `\n`, `\r`, `\t` and `\u{XXXX}`), and a quoted line is read
/// back that way. Every other line is read as it stands, so list files made without quoting
/// (and names with backslashes in them) keep their meaning.
public enum FileListFile {
    /// Thrown for a list file over `sizeLimit` bytes or `lineLimit` lines.
    public struct TooLarge: LocalizedError {
        /// The message the user reads.
        public var errorDescription: String? { "The list of files is too large to load." }
    }

    /// The most a list file may hold (bytes) and name (lines): more is not a list a person made.
    public static let sizeLimit = 16 << 20
    /// The most lines a list file may have; see `sizeLimit`.
    public static let lineLimit = 1_000_000

    /// The lines of a list file.
    ///
    /// UTF-8 with or without a byte-order mark and UTF-16 with one are read; line ends may be LF or
    /// CRLF.
    public static func lines(in data: Data) -> [String] {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text =
                String(data: data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }
        return (text ?? "").split(whereSeparator: \.isNewline)
            .compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    return nil
                }
                return unquoted(line) ?? line
            }
    }

    /// The name a quoted line stands for; nil when the line is not quoted, or holds an escape
    /// that is none of ours (then it is an old, unquoted line).
    internal static func unquoted(_ line: String) -> String? {
        guard line.unicodeScalars.count >= 2, line.unicodeScalars.first == "\"", line.unicodeScalars.last == "\"" else {
            return nil
        }
        let body = Array(line.unicodeScalars.dropFirst().dropLast())
        var result = String.UnicodeScalarView()
        var index = 0
        while index < body.count {
            let scalar = body[index]
            index += 1
            guard scalar == "\\" else {
                // An unescaped quote inside means the line is no quoted name.
                if scalar == "\"" {
                    return nil
                }
                result.append(scalar)
                continue
            }
            guard let escaped = unescaped(body, at: &index) else {
                return nil
            }
            result.append(escaped)
        }
        return String(result)
    }

    /// One line for a name: as it is when that reads back the same, otherwise quoted.
    public static func line(for name: String) -> String {
        let scalars = name.unicodeScalars
        let needsQuotes =
            scalars.first == "\"" || scalars.contains { isUnsafe($0) }
            || scalars.first.map(\.properties.isWhitespace) == true
            || scalars.last.map(\.properties.isWhitespace) == true
        guard needsQuotes else {
            return name
        }
        var text = "\""
        for scalar in scalars {
            switch scalar {
            case "\\":
                text += "\\\\"

            case "\"":
                text += "\\\""

            case "\n":
                text += "\\n"

            case "\r":
                text += "\\r"

            case "\t":
                text += "\\t"

            default:
                if isUnsafe(scalar) {
                    text += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        return text + "\""
    }

    /// The text of a list file naming `names`, one per line.
    public static func text(for names: [String]) -> String {
        names.map(line(for:)).joined(separator: "\n") + (names.isEmpty ? "" : "\n")
    }

    /// Reads a list file from any file system.
    ///
    /// Blocks: for a background thread. Only files of this computer and of the file system the list
    /// file is on are taken over from it: a list file must not make the program connect to any host
    /// it names.
    public static func read(_ file: URL, fileSystems: FileSystemRegistry, relativeTo base: URL) throws -> [URL] {
        let reader = try fileSystems.provider(for: file).read(file)
        defer { reader.close() }
        var data = Data()
        while let block = try reader.read(upToCount: 1 << 20), !block.isEmpty {
            data.append(block)
            if data.count > sizeLimit { throw TooLarge() }
        }
        let lines = lines(in: data)
        if lines.count > lineLimit { throw TooLarge() }
        return lines.map { fileSystems.location(from: $0, relativeTo: base) }.filter { isTrusted($0, listedIn: file) }
    }

    /// Whether a file named by a list file may be listed: a local file, or one on the very
    /// server (scheme, host, port) the list file itself was read from.
    internal static func isTrusted(_ url: URL, listedIn file: URL) -> Bool {
        if url.isFileURL {
            return true
        }
        return url.scheme == file.scheme && url.host == file.host && url.port == file.port
    }

    /// The scalar an escape stands for, read from `body` at `index` (just after the backslash),
    /// with `index` moved past it; nil for an escape that is none of ours.
    private static func unescaped(_ body: [Unicode.Scalar], at index: inout Int) -> Unicode.Scalar? {
        guard index < body.count else {
            return nil
        }
        let escape = body[index]
        index += 1
        switch escape {
        case "\\", "\"":
            return escape

        case "n":
            return "\n"

        case "r":
            return "\r"

        case "t":
            return "\t"

        case "u":
            guard index < body.count, body[index] == "{", let close = body[index...].firstIndex(of: "}") else {
                return nil
            }
            let digits = String(String.UnicodeScalarView(body[(index + 1)..<close]))
            guard !digits.isEmpty, digits.count <= 6, let value = UInt32(digits, radix: 16),
                let unicode = Unicode.Scalar(value)
            else { return nil }
            index = close + 1
            return unicode

        default:
            return nil
        }
    }

    /// A scalar that cannot stand in a line as it is: a control character or a line or
    /// paragraph break.
    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true

        default:
            return false
        }
    }
}
