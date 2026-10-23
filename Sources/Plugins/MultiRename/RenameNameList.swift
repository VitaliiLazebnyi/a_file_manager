import Foundation

/// Reads a list of names from a text file (spec 09 › Name-list menu): UTF-8 with or without
/// a byte-order mark, UTF-16, or the Western code page; Windows or Unix line ends.
internal enum RenameNameList {
    /// The text of a file of names, in whichever of the encodings it is.
    internal static func text(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return repairedUTF8(data.dropFirst(3))
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        // UTF-16 without a mark shows in the zero bytes between Latin letters.
        if data.count >= 2, data.count.isMultiple(of: 2), data[data.startIndex + 1] == 0,
            let text = String(data: data, encoding: .utf16LittleEndian)
        {
            return text
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? repairedUTF8(data)
    }

    /// One name per line; empty lines at the end do not count.
    internal static func names(in text: String) -> [String] {
        var lines =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// The bytes as UTF-8, with what is no UTF-8 replaced, not refused: a list with one bad byte keeps
    /// its other names.
    private static func repairedUTF8(_ bytes: Data) -> String {
        String(unsafeUninitializedCapacity: bytes.count) { buffer in
            let (_, copied) = buffer.initialize(from: bytes)
            return copied
        }
    }
}
