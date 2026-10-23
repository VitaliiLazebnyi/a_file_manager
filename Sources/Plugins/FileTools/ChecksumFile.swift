import AFMKernel
import Foundation

/// The text of checksum files (spec 19 › Checksum files): written by Create checksums, read
/// by Verify.
internal enum ChecksumFile {
    /// One line of a checksum file: a file and its digest.
    internal struct Entry: Equatable {
        /// The file's name or path, as the line has it.
        internal var name: String
        /// Lower-case hex.
        internal var digest: String
        /// The method, where the line or the file's extension tells it; otherwise every
        /// method with a digest of this length is tried.
        internal var method: ChecksumMethod?
    }

    /// What was read from a checksum file: its entries, and the numbers of the lines that are
    /// neither an entry nor a comment nor empty.
    internal struct Parsed {
        /// The entries, in the order of their lines.
        internal var entries: [Entry] = []
        /// The numbers (from 1) of the lines that could not be read.
        internal var unreadableLines: [Int] = []
    }

    /// The methods by the extension of a checksum file, also in the spellings other tools use.
    internal static let byExtension: [String: ChecksumMethod] = {
        var methods = Dictionary(
            uniqueKeysWithValues: ChecksumMethod.allCases.map { method in
                (method.fileExtension, method)
            }
        )
        methods["sha1"] = .sha1
        methods["crc32"] = .crc32
        methods["blake3"] = .blake3
        for method in [ChecksumMethod.sha3Bits224, .sha3Bits256, .sha3Bits384, .sha3Bits512] {
            methods[method.fileExtension.replacingOccurrences(of: "_", with: "-")] = method
        }
        return methods
    }()

    /// The methods by the tag of an OpenSSL or BSD line (`SHA256(name)= …`), also in the spellings other tools use.
    internal static let tags: [String: ChecksumMethod] = {
        var found = Dictionary(uniqueKeysWithValues: ChecksumMethod.allCases.map { method in (method.tagName, method) })
        found["SHA2-256"] = .sha256
        found["SHA2-512"] = .sha512
        found["SHA2-224"] = .sha224
        found["SHA2-384"] = .sha384
        return found
    }()

    /// One line without its end: `<digest> *<name>`, or for SFV `<name> <DIGEST>`.
    ///
    /// A name that would be taken for something else is written so that it reads back as itself.
    /// SFV: a name that starts with `;` or `#` (a comment there) or with white space gets `./` in
    /// front. The other formats (GNU): a name with a line break or, then, a backslash is escaped
    /// (`\n`, `\r`, `\\`) and the line starts with a backslash.
    internal static func line(name: String, digest: [UInt8], method: ChecksumMethod) -> String {
        if method == .crc32 {
            let needsPrefix = name.first.map { first in first == ";" || first == "#" || first.isWhitespace } ?? false
            return "\(needsPrefix ? "./" : "")\(name) \(digest.hex.uppercased())"
        }
        guard hasLineBreak(name) else {
            return "\(digest.hex) *\(name)"
        }
        var escaped = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\\":
                escaped.append(contentsOf: "\\\\".unicodeScalars)

            case "\n":
                escaped.append(contentsOf: "\\n".unicodeScalars)

            case "\r":
                escaped.append(contentsOf: "\\r".unicodeScalars)

            default:
                escaped.append(scalar)
            }
        }
        return "\\\(digest.hex) *\(String(escaped))"
    }

    /// Whether a name holds a line feed or carriage return (found on the code points: `\r\n` is one character
    /// to Swift).
    internal static func hasLineBreak(_ name: String) -> Bool {
        name.unicodeScalars.contains { scalar in scalar == "\n" || scalar == "\r" }
    }

    /// The contents of a checksum file.
    ///
    /// The Unix format ends lines with LF and keeps `/` in paths; the other one is that of the
    /// Windows original: CRLF and `\`. The text is UTF-8; `byteOrderMark` puts the mark in front
    /// that the original needs to read it as such.
    internal static func contents(
        _ entries: [(name: String, digest: [UInt8])],
        method: ChecksumMethod,
        unixFormat: Bool,
        byteOrderMark: Bool
    ) -> Data {
        let end = unixFormat ? "\n" : "\r\n"
        let text =
            entries.map { entry in
                line(
                    name: unixFormat ? entry.name : entry.name.replacingOccurrences(of: "/", with: "\\"),
                    digest: entry.digest,
                    method: method
                ) + end
            }
            .joined()
        return (byteOrderMark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
    }

    /// Whether the mark is written: always when asked for; otherwise only in the Windows
    /// format and when a name needs more than ASCII (there the original would take the text
    /// for the local code page).
    internal static func needsByteOrderMark(names: [String], unixFormat: Bool, alwaysUTF8: Bool) -> Bool {
        alwaysUTF8 || (!unixFormat && names.contains { name in !name.allSatisfy(\.isASCII) })
    }

    /// The method a checksum file's extension names; nil for an extension of no method.
    internal static func method(forFileNamed name: String) -> ChecksumMethod? {
        byExtension[FileItem.split(name).ext.lowercased()]
    }

    /// The files Verify takes for checksum files: `*.sfv *.md5 *.sha* *.bk3` and the user's
    /// extra masks (the spec's `ChecksumExtraTypes`).
    internal static func isChecksumFile(_ name: String, extraMasks: String) -> Bool {
        checksumFileTest(extraMasks: extraMasks)(name)
    }

    /// The test of `isChecksumFile`, with the mask compiled once for many names.
    internal static func checksumFileTest(extraMasks: String) -> (String) -> Bool {
        let mask = FileMask("*.sfv *.md5 *.sha* *.bk3 " + extraMasks)
        return { name in mask.matches(name) }
    }

    /// The text of a checksum file: UTF-8 with or without a mark, UTF-16, or the Western code page.
    internal static func text(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(repairingUTF8: data.dropFirst(3))
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            // Damaged UTF-16 is read as far as it goes; what it makes of the rest is not a checksum line and is
            // reported as such.
            return String(data: data, encoding: .utf16) ?? String(repairingUTF8: data)
        }
        if data.count >= 2, data.count.isMultiple(of: 2) {
            if data[data.startIndex + 1] == 0, let text = String(data: data, encoding: .utf16LittleEndian) {
                return text
            }
            if data[data.startIndex] == 0, let text = String(data: data, encoding: .utf16BigEndian) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(repairingUTF8: data)
    }
}
