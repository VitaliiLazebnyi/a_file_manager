import AFMKernel
import Foundation

/// Parsing: the entries of the lines of a checksum file, in the forms the tools that write them use.
extension ChecksumFile {
    /// Reads the lines of a checksum file named `fileName`: `<digest> *<name>` (also with two
    /// spaces), the SFV form `<name> <crc>`, the OpenSSL and BSD form `SHA256(name)= <digest>`
    /// and the checksum of a stream `<digest>  -`, which stands for the file the checksum
    /// file is named after.
    ///
    /// Comment lines (`;`, `#`) are passed over, and so is nothing else.
    internal static func parse(_ text: String, fileName: String) -> [Entry] {
        parseLines(text, fileName: fileName).entries
    }

    /// Like `parse`, and says which lines could not be read.
    ///
    /// A line is a comment only when it cannot be an entry: in an SFV file `;x.txt 1A2B3C4D`
    /// and `#1 hit.txt DC186425` are entries (the name follows the same rule as the others),
    /// and a `;` line that does not end in a CRC is a comment. The other formats start every entry
    /// with a digest or a tag, so a line starting with `;` or `#` is always a comment there.
    internal static func parseLines(_ text: String, fileName: String) -> Parsed {
        let fileMethod = method(forFileNamed: fileName)
        var parsed = Parsed()
        // Lines end with LF, CR or CRLF only: other line separators of Unicode can be part of a name.
        let lines = text.split(omittingEmptySubsequences: false) { character in
            character == "\n" || character == "\r" || character == "\r\n"
        }
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                continue
            }
            if line.hasPrefix(";") || line.hasPrefix("#") {
                if fileMethod == .crc32, let entry = sfvEntry(line) {
                    parsed.entries.append(entry)
                }
                continue
            }
            if let entry = entry(in: line, fileName: fileName, fileMethod: fileMethod) {
                parsed.entries.append(entry)
            } else {
                parsed.unreadableLines.append(index + 1)
            }
        }
        return parsed
    }

    /// The entry of a line that is not a comment; nil when it is none.
    private static func entry(in text: String, fileName: String, fileMethod: ChecksumMethod?) -> Entry? {
        var line = text
        // GNU tools put a backslash in front of a line whose name holds a backslash or a line feed.
        let escaped =
            line.hasPrefix("\\")
            && line.dropFirst()
                .prefix { character in character != " " && character != "\t" }
                .allSatisfy { character in character.isASCII && character.isHexDigit }
        if escaped {
            line.removeFirst()
        }
        if let tagged = taggedEntry(line, escaped: escaped) {
            return tagged
        }
        let first = line.prefix { character in character != " " && character != "\t" }
        let rest = line[first.endIndex...]
        let known = !ChecksumMethod.candidates(hexDigits: first.count).isEmpty
        // In an SFV file a line is `name crc` even when the name starts like a checksum.
        guard isHex(first), known, rest.count >= 2,
            fileMethod != .crc32 || first.count != 8 || !isHex(line.suffix(8)) || line.count < 10
        else {
            return sfvEntry(line)
        }
        var name = rest.dropFirst()
        if name.hasPrefix("*") || name.hasPrefix(" ") {
            name = name.dropFirst()
        }
        let entryName = name == "-" ? FileItem.split(fileName).base : decoded(String(name), escaped: escaped)
        // `<digest> *` names nothing.
        guard !entryName.isEmpty else {
            return nil
        }
        let fitting = fileMethod.flatMap { method in method.digestLength * 2 == first.count ? method : nil }
        return Entry(name: entryName, digest: first.lowercased(), method: fitting)
    }

    /// `SHA256(name)= digest` or `MD5 (name) = digest`; nil when the line is not of that form.
    private static func taggedEntry(_ line: String, escaped: Bool) -> Entry? {
        guard let open = line.firstIndex(of: "("), let close = line.range(of: ")", options: .backwards)?.lowerBound,
            open < close,
            let tagged = tags[
                line[..<open].trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: "_", with: "-")
            ]
        else {
            return nil
        }
        let digest = line[line.index(after: close)...].drop { character in character == "=" || character == " " }
        let name = decoded(String(line[line.index(after: open)..<close]), escaped: escaped)
        guard isHex(digest), digest.count == tagged.digestLength * 2, !name.isEmpty else {
            return nil
        }
        return Entry(name: name, digest: digest.lowercased(), method: tagged)
    }

    /// `name crc` at the end of a line, the SFV form; nil when the line does not end so.
    private static func sfvEntry(_ line: String) -> Entry? {
        guard let space = line.lastIndex(where: { character in character == " " || character == "\t" }) else {
            return nil
        }
        let digest = line[line.index(after: space)...]
        let name = line[..<space].trimmingCharacters(in: .whitespaces)
        guard isHex(digest), digest.count == 8, !name.isEmpty else {
            return nil
        }
        return Entry(name: name, digest: digest.lowercased(), method: .crc32)
    }

    /// Whether the text is hex digits, at least one.
    private static func isHex(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { character in character.isASCII && character.isHexDigit }
    }

    /// The name as written, unescaped when its line started with a backslash.
    private static func decoded(_ name: String, escaped: Bool) -> String {
        escaped ? unescaped(name) : name
    }

    /// The name of a GNU line that starts with a backslash: `\\` stands for a backslash and `\n` for a line feed.
    private static func unescaped(_ name: String) -> String {
        guard name.contains("\\") else {
            return name
        }
        var result = ""
        var escaped = false
        for character in name {
            if escaped {
                result.append(character == "n" ? "\n" : character == "r" ? "\r" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
