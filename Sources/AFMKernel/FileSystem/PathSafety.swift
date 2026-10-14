public import Foundation

/// Checks on names and paths that come from outside the program: the entries of an archive,
/// the answers of a server, the lines of a list file. Whoever writes a file at such a path
/// must end up below the folder it was told to fill, whatever the path says.
///
/// Everything here goes by **bytes**. A path is cut at the byte `/` and nowhere else. Cutting
/// a `String` by its characters does not find every separator: a `/` followed by a combining
/// mark is one character that is not `/`, so a path of `..`, such a `/`, and more looked like
/// a single harmless name to code that split on characters, and the file system, which goes
/// by bytes, walked up a folder.
public enum PathSafety: Sendable {
    /// Whether `name` can be the name of one entry: not empty, not `.` or `..`, and holding
    /// neither the byte `/` nor a zero byte.
    public static func isSafeName(_ name: String) -> Bool {
        var name = name
        return name.withUTF8 { isSafeName($0) }
    }

    private static func isSafeName(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        if name.isEmpty || name.contains(0x2F) || name.contains(0) { return false }
        if name.count == 1, name[0] == 0x2E { return false }
        if name.count == 2, name[0] == 0x2E, name[1] == 0x2E { return false }
        return true
    }

    /// The names a relative path is made of, cut at every `/` byte. Nil unless every one of
    /// them is a safe name: no empty one (a leading, doubled or trailing `/`), no `.`, no
    /// `..`, no zero byte. With `allowingTrailingSeparator`, one `/` at the end is let pass,
    /// as archives write their folders.
    public static func components(ofRelativePath path: String, allowingTrailingSeparator: Bool = false) -> [String]? {
        var bytes = Array(path.utf8)
        if allowingTrailingSeparator, bytes.last == 0x2F { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        var names: [String] = []
        for part in bytes.split(separator: 0x2F, omittingEmptySubsequences: false) {
            guard part.withUnsafeBufferPointer({ isSafeName($0) }) else { return nil }
            // Cut at an ASCII byte, valid UTF-8 stays valid UTF-8.
            names.append(String(decoding: part, as: UTF8.self))
        }
        return names
    }

    /// Whether `url` lies below `root` once both are written out in full: the paths are read
    /// the way the file system reads them (an empty name is no name, so `a//..` is the folder
    /// above `a`; `.` is the folder itself, `..` the one above) and compared byte for byte,
    /// component by component. A path whose `..` leads above its start lies nowhere. With
    /// `resolvingLinks`, symbolic links on the way are followed first, for both, which asks
    /// the disk and is for local files only: a link inside the folder that points out of it
    /// is then seen for what it is, also when the file at the end does not exist yet.
    public static func isContained(_ url: URL, in root: URL, resolvingLinks: Bool = false) -> Bool {
        guard (url.scheme ?? "file") == (root.scheme ?? "file"), url.host == root.host, url.port == root.port else {
            return false
        }
        func bytes(_ url: URL) -> [UInt8]? {
            written(Array((resolvingLinks && url.isFileURL ? resolved(url.path) : url.path).utf8))
        }
        guard let own = bytes(url), let above = bytes(root), own.count > above.count, own.starts(with: above) else {
            return false
        }
        return above.last == 0x2F || own[above.count] == 0x2F
    }

    /// A path written out in full, by its text alone: empty names and `.` left out, each `..`
    /// taking away the name before it. Nil when a `..` has nothing left to take away.
    private static func written(_ path: [UInt8]) -> [UInt8]? {
        var names: [ArraySlice<UInt8>] = []
        for name in path.split(separator: 0x2F) where !name.elementsEqual([0x2E]) {
            if name.elementsEqual([0x2E, 0x2E]) {
                guard names.popLast() != nil else { return nil }
            } else {
                names.append(name)
            }
        }
        let joined = Array(names.joined(separator: [0x2F]))
        return path.first == 0x2F ? [0x2F] + joined : joined
    }

    /// The path of a local file (which starts at the root) with every link on the way
    /// followed: the longest start of the path that exists is resolved by the system (links
    /// and `..` as the disk has them), and what does not exist yet follows it as written.
    private static func resolved(_ path: String) -> String {
        let names = Array(path.utf8).split(separator: 0x2F)
        for count in stride(from: names.count, to: 0, by: -1) {
            let start = "/" + names[..<count].map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
            guard let real = realpath(start, nil) else { continue }
            defer { free(real) }
            return names[count...]
                .reduce(String(cString: real)) { text, name in
                    text + "/" + String(decoding: name, as: UTF8.self)
                }
        }
        // Nothing but the root exists, and the root is itself.
        return path
    }
}
