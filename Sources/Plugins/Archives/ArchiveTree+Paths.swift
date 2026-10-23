/// Taking member paths apart and putting them together, at the byte `/`.
extension ArchiveTree {
    /// The last name of a path; the path itself when it has one name only.
    internal static func name(of path: String) -> String {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: 0x2F) else {
            return path
        }
        return String(Substring(bytes[bytes.index(after: slash)...]))
    }

    /// The path of the folder a path lies in; empty for a path in the top folder.
    internal static func parent(of path: String) -> String {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: 0x2F) else {
            return ""
        }
        return String(Substring(bytes[..<slash]))
    }

    /// The path of `name` inside `folder`; the empty folder is the top one.
    internal static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// The names of a path, cut at the byte `/`.
    internal static func names(of path: String) -> [String] {
        path.utf8.split(separator: 0x2F, omittingEmptySubsequences: true).map { String(Substring($0)) }
    }

    /// The part of `path` below `folder`; nil when it does not lie below it.
    ///
    /// Compared byte by byte: two paths that look alike but are written differently are two paths.
    internal static func relative(_ path: String, to folder: String) -> String? {
        if folder.isEmpty {
            return path
        }
        let (bytes, prefix) = (path.utf8, folder.utf8)
        guard bytes.count > prefix.count + 1, bytes.starts(with: prefix),
            bytes[bytes.index(bytes.startIndex, offsetBy: prefix.count)] == 0x2F
        else {
            return nil
        }
        return String(Substring(bytes.dropFirst(prefix.count + 1)))
    }

    /// A member's path as the tree keys it; nil for a path that is not shown.
    ///
    /// Leading slashes and `.` are dropped. A path is refused altogether when it has a `..` or a
    /// NUL byte, is longer or deeper than the limits above, or holds a `/` that Swift would not see
    /// as a character of its own (one followed by a combining mark, or preceded by a character that
    /// binds what follows): no member can then name a place outside the folder an archive is
    /// unpacked into, whichever way its path is taken apart.
    internal static func normalized(_ raw: String) -> String? {
        let bytes = raw.utf8
        var parts: [Substring.UTF8View.SubSequence] = []
        var (total, isASCII) = (0, true)
        for part in bytes.split(separator: 0x2F, omittingEmptySubsequences: true) {
            var dots = 0
            for byte in part {
                if byte == 0 {
                    return nil
                }
                if byte >= 0x80 { isASCII = false }
                dots = byte == 0x2E && dots >= 0 ? dots + 1 : -1
            }
            if dots == 1, part.count == 1 { continue }
            if dots == 2, part.count == 2 {
                return nil
            }
            parts.append(part)
            total += part.count + 1
            guard parts.count <= maxDepth, total - 1 <= maxPathBytes else {
                return nil
            }
        }
        guard !parts.isEmpty else {
            return nil
        }
        var joined: String
        if total - 1 == bytes.count {
            // Nothing was dropped: the path is the text as it came, and shares its storage.
            joined = raw
            joined.makeContiguousUTF8()
        } else {
            joined = parts.map { String(Substring($0)) }.joined(separator: "/")
        }
        // Plain ASCII has no character that joins its neighbour.
        if !isASCII, joined.split(separator: "/", omittingEmptySubsequences: false).count != parts.count {
            return nil
        }
        return joined
    }
}
