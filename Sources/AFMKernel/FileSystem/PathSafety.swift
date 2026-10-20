public import Foundation

/// Checks on names and paths that come from outside the program: the entries of an archive, the answers of a server,
/// the lines of a list file.
///
/// Whoever writes a file at such a path must end up below the folder it was told to fill, whatever the path says.
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
        isSafeName(name.utf8)
    }

    /// The names a relative path is made of, cut at every `/` byte.
    ///
    /// Empty unless every one of them is a safe name: no empty one (a leading, doubled or trailing `/`), no `.`, no
    /// `..`, no zero byte. (A path that is safe has at least one name.) With `allowingTrailingSeparator`, one `/` at
    /// the end is let pass, as archives write their folders.
    public static func components(ofRelativePath path: String, allowingTrailingSeparator: Bool = false) -> [String] {
        var bytes = Substring(path).utf8
        if allowingTrailingSeparator, bytes.last == 0x2F {
            bytes = bytes.dropLast()
        }
        let parts = bytes.split(separator: 0x2F, omittingEmptySubsequences: false)
        guard !bytes.isEmpty, parts.allSatisfy(isSafeName) else {
            return []
        }
        // Cut at an ASCII byte, valid UTF-8 stays valid UTF-8.
        return parts.map { String(Substring($0)) }
    }

    /// Whether `url` lies below `root` once both are written out in full: the paths are read the way the file system
    /// reads them (an empty name is no name, so `a//..` is the folder above `a`; `.` is the folder itself, `..` the one
    /// above) and compared byte for byte, component by component.
    ///
    /// A path whose `..` leads above its start lies nowhere. With `resolvingLinks`, symbolic links on the way are
    /// followed first, for both, which asks the disk and is for local files only: a link inside the folder that points
    /// out of it is then seen for what it is, also when the file at the end does not exist yet.
    public static func isContained(_ url: URL, in root: URL, resolvingLinks: Bool = false) -> Bool {
        guard (url.scheme ?? "file") == (root.scheme ?? "file"), url.host == root.host, url.port == root.port else {
            return false
        }
        func bytes(_ url: URL) -> (path: [UInt8], leavesStart: Bool) {
            written(Array((resolvingLinks && url.isFileURL ? resolved(url.path) : url.path).utf8))
        }
        let (own, above) = (bytes(url), bytes(root))
        guard !own.leavesStart, !above.leavesStart, own.path.count > above.path.count,
            own.path.starts(with: above.path)
        else {
            return false
        }
        return above.path.last == 0x2F || own.path[above.path.count] == 0x2F
    }

    /// Whether some bytes can be the name of one entry (see `isSafeName(_:)`).
    private static func isSafeName(_ name: some Collection<UInt8>) -> Bool {
        if name.isEmpty || name.contains(0x2F) || name.contains(0) {
            return false
        }
        return !name.elementsEqual([0x2E]) && !name.elementsEqual([0x2E, 0x2E])
    }

    /// A path written out in full, by its text alone: empty names and `.` left out, each `..`
    /// taking away the name before it. `leavesStart` when a `..` had nothing left to take away.
    private static func written(_ path: [UInt8]) -> (path: [UInt8], leavesStart: Bool) {
        var names: [ArraySlice<UInt8>] = []
        for name in path.split(separator: 0x2F) where !name.elementsEqual([0x2E]) {
            if !name.elementsEqual([0x2E, 0x2E]) {
                names.append(name)
            } else if names.popLast() == nil {
                return ([], true)
            }
        }
        let joined = Array(names.joined(separator: [0x2F]))
        // A relative path stays relative.
        return (path.first != 0x2F ? joined : [0x2F] + joined, false)
    }

    /// The path of a local file (which starts at the root) with every link on the way
    /// followed: the longest start of the path that exists is resolved by the system (links
    /// and `..` as the disk has them), and what does not exist yet follows it as written.
    private static func resolved(_ path: String) -> String {
        let names = Substring(path).utf8.split(separator: 0x2F).map { String(Substring($0)) }
        for count in stride(from: names.count, to: 0, by: -1) {
            guard let real = realpath("/" + names[..<count].joined(separator: "/"), nil) else {
                continue
            }
            defer { free(real) }
            return names[count...].reduce(String(cString: real)) { $0 + "/" + $1 }
        }
        // Nothing but the root exists, and the root is itself.
        return path
    }
}
