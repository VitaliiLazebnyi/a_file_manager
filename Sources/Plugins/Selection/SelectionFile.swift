import AFMKernel
import Foundation

/// The file a selection is saved to and loaded from (spec 19 › Selection files): one name per
/// line without a path, folders with a trailing `\`, CRLF between the lines and none after
/// the last.
///
/// Pure functions, usable on any thread.
internal enum SelectionFile {
    /// The encoding a selection file is written in.
    internal enum Encoding {
        /// Windows-1252 (`cm_SaveSelectionToFileA`); characters outside it are approximated.
        case ansi
        /// UTF-16 LE with a byte-order mark (`cm_SaveSelectionToFileW`, and the default).
        case unicode
    }

    /// The selection file of the entries, in the encoding given.
    internal static func encode(_ items: [FileItem], as encoding: Encoding) -> Data {
        let text = items.map { $0.isFolder ? $0.name + "\\" : $0.name }.joined(separator: "\r\n")
        switch encoding {
        case .unicode:
            return Data([0xFF, 0xFE]) + Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

        case .ansi:
            return windows1252(text)
        }
    }

    /// The text in Windows-1252, one character at a time.
    ///
    /// A character outside it is written as its base letter where it has one (`ą` as `a`), else as
    /// `?`. Foundation's lossy conversion of the whole text is not used: for some names (`U+3000
    /// U+0300`) it raises an exception that nothing catches.
    internal static func windows1252(_ text: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var known: [UInt32: UInt8] = [:]
        func code(_ scalar: Unicode.Scalar) -> UInt8? {
            guard let data = String(scalar).data(using: .windowsCP1252, allowLossyConversion: false), data.count == 1
            else { return nil }
            return data[data.startIndex]
        }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x80 {
                bytes.append(UInt8(scalar.value))
            } else if let byte = known[scalar.value] {
                bytes.append(byte)
            } else {
                let byte =
                    code(scalar) ?? String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first
                    .flatMap(
                        code
                    ) ?? UInt8(ascii: "?")
                known[scalar.value] = byte
                bytes.append(byte)
            }
        }
        return Data(bytes)
    }

    /// The text of a selection file: UTF-16 or UTF-8 by its byte-order mark, else UTF-8 when
    /// the bytes are valid UTF-8, else Windows-1252.
    internal static func text(from data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }

    /// The names a text lists, one per line, that are among `known`.
    ///
    /// A line may be a name, a folder's name with a trailing `\` or `/`, or a full path, of which
    /// the last part counts: so the lists of *Copy Names To Clipboard* can be loaded as well.
    internal static func names(in text: String, among known: Set<String>) -> Set<String> {
        Set(listed(in: text, among: known))
    }

    /// The same in the order of the lines, each as the text writes it: a name that reads like
    /// two entries' names still finds the one written exactly like it (`PanelModel.setSelection(names:)`).
    internal static func listed(in text: String, among known: Set<String>) -> [String] {
        var names: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var name = String(line)
            if known.contains(name) {
                names.append(name)
                continue
            }
            while let last = name.last, last == "\\" || last == "/" { name.removeLast() }
            if !known.contains(name), let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
                name = String(name[name.index(after: slash)...])
            }
            if known.contains(name) { names.append(name) }
        }
        return names
    }
}
