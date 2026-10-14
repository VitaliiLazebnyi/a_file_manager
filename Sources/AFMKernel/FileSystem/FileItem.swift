import Foundation

/// One entry of a directory, on whatever file system it lives (spec 03 › Rows in Full view).
public struct FileItem: Equatable {
    public let url: URL
    public let name: String
    /// A directory, or a symbolic link that points to one.
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// A directory that is shown and opened like a file (a macOS bundle such as `.app`).
    public let isPackage: Bool
    public let isHidden: Bool
    public let size: Int64
    public let modified: Date
    public let permissions: UInt16
    /// Folder size calculated with Space; replaces `<DIR>` in the Size column.
    public var computedSize: Int64?
    /// Neither a file with contents nor a directory: a pipe, a device or a socket, or a link
    /// to one. Opening it to read may never return, so whoever reads files by the dozen
    /// (a search) leaves these out. False where the file system knows no such things.
    public let isSpecial: Bool
    /// For a link to a regular file: the size of that file; nil for everything else, and
    /// where the file system did not look.
    public var linkTargetSize: Int64? {
        get { targetSize == Self.unknown ? nil : targetSize }
        set { targetSize = newValue ?? Self.unknown }
    }
    /// The device (volume) the entry itself is on, as the system numbers it (`st_dev`); nil
    /// where the file system has no such notion. Two entries with different numbers are on
    /// different volumes: a folder whose number differs from its parent's is a mount point.
    public var device: Int64? {
        get { deviceNumber == Self.unknown ? nil : deviceNumber }
        set { deviceNumber = newValue ?? Self.unknown }
    }
    /// The two above, kept as plain numbers so that a list of a million entries does not
    /// pay for two optionals each.
    private var targetSize = Self.unknown
    private var deviceNumber = Self.unknown
    private static let unknown = Int64.min

    public init(
        url: URL, name: String, isDirectory: Bool, isSymlink: Bool = false, isPackage: Bool = false,
        isHidden: Bool = false, size: Int64 = 0, modified: Date = Date(timeIntervalSince1970: 0),
        permissions: UInt16 = 0o644, computedSize: Int64? = nil, isSpecial: Bool = false,
        linkTargetSize: Int64? = nil, device: Int64? = nil
    ) {
        targetSize = linkTargetSize ?? Self.unknown
        deviceNumber = device ?? Self.unknown
        self.isSpecial = isSpecial
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.computedSize = computedSize
    }

    /// Listed with the folders, in brackets, and entered with Enter.
    public var isFolder: Bool { isDirectory && !isPackage }

    /// A directory that is not a link; operations descend into these and treat links as links.
    public var isRealDirectory: Bool { isDirectory && !isSymlink }

    /// Name column: the name without its extension; folders keep the whole name.
    public var baseName: String { isFolder ? name : Self.split(name).base }

    /// Ext column: the extension without the dot; empty for folders.
    public var ext: String { isFolder ? "" : Self.split(name).ext }

    /// Whether two entries of the same directory look the same in a file list. Cheaper than
    /// `==`, which also compares the locations.
    public func isSameEntry(as other: Self) -> Bool {
        name == other.name && size == other.size && modified == other.modified && isDirectory == other.isDirectory
            && isSymlink == other.isSymlink && isPackage == other.isPackage && isHidden == other.isHidden
            && permissions == other.permissions && computedSize == other.computedSize && isSpecial == other.isSpecial
    }

    /// Splits at the last dot. A leading dot (`.zshrc`) does not start an extension.
    public static func split(_ name: String) -> (base: String, ext: String) {
        // Nearly every name is cut by looking at its bytes: a dot between ASCII neighbours
        // is a character of its own. Only a dot next to other text (it may carry an
        // accent) needs the slow walk over whole characters.
        if let cut = name.utf8.withContiguousStorageIfAvailable(splitPoint) ?? nil {
            guard cut != noExtension else { return (name, "") }
            let dot = name.utf8.index(name.utf8.startIndex, offsetBy: cut)
            return (String(name[..<dot]), String(name[name.utf8.index(after: dot)...]))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Where `split` cuts a name given as UTF-8: the offset of the dot, or `noExtension`.
    /// Nil when the bytes alone cannot tell.
    static func splitPoint(_ name: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let dot = name.lastIndex(of: 0x2E) else { return noExtension }
        if dot > 0, name[dot - 1] >= 0x80 { return nil }
        if dot + 1 < name.count, name[dot + 1] >= 0x80 { return nil }
        return dot == 0 || dot + 1 == name.count ? noExtension : dot
    }

    static let noExtension = -1
}

extension URL {
    /// The location of an entry inside this directory. Unlike `appendingPathComponent(_:)`,
    /// which asks the disk whether the result is a folder (one trip to the server per call on
    /// a network share), this works on the text alone.
    ///
    /// The name is taken as it is: one that holds a `/`, or is `..`, leads somewhere else.
    /// That is wanted for a path the user typed and for nothing that comes from outside (an
    /// archive, a server, a list file): such names go through `appending(safeName:)` or
    /// `PathSafety`.
    public func appending(name: String) -> URL {
        appendingPathComponent(name, isDirectory: false)
    }

    /// The location of an entry inside this directory, for a name that comes from outside:
    /// nil unless the name is one name (`PathSafety.isSafeName`), so the result is always
    /// directly inside this directory.
    public func appending(safeName name: String) -> URL? {
        PathSafety.isSafeName(name) ? appendingPathComponent(name, isDirectory: false) : nil
    }

    /// Identifies a location across file systems: scheme, host, port and path, without a
    /// trailing slash. Two URLs show the same place exactly when their keys are equal.
    public var locationKey: String {
        let path = self.path
        let host = (self.host ?? "") + (port.map { ":\($0)" } ?? "")
        return (scheme ?? "file") + "://" + host
            + (path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    public func isSameLocation(as other: URL) -> Bool {
        locationKey == other.locationKey
    }

    /// Whether two locations are the same file: for local files the same entry of the same
    /// volume (device and inode, links not followed unless `followingLinks`), however the two
    /// paths are written; false when either is not there. For other locations, and when the
    /// disk cannot say, the same location as text. Asks the disk: not for the main thread.
    public func isSameFile(as other: URL, followingLinks: Bool = false) -> Bool {
        guard isFileURL, other.isFileURL else { return isSameLocation(as: other) }
        var (own, others) = (stat(), stat())
        let look = followingLinks ? stat : lstat
        guard look(path, &own) == 0, look(other.path, &others) == 0 else { return false }
        return own.st_dev == others.st_dev && own.st_ino == others.st_ino
    }

    /// True when `self` lies somewhere below `ancestor`. The keys are compared byte for byte:
    /// a folder whose name merely reads like the ancestor's, or goes on with an accent after
    /// the last character, is another folder.
    public func isInside(_ ancestor: URL) -> Bool {
        let (own, parent) = (locationKey, ancestor.locationKey)
        return own.utf8.starts(with: (parent.utf8.last == 0x2F ? parent : parent + "/").utf8)
    }
}

/// Checks on names and paths that come from outside the program: the entries of an archive,
/// the answers of a server, the lines of a list file. Whoever writes a file at such a path
/// must end up below the folder it was told to fill, whatever the path says.
///
/// Everything here goes by **bytes**. A path is cut at the byte `/` and nowhere else. Cutting
/// a `String` by its characters does not find every separator: a `/` followed by a combining
/// mark is one character that is not `/`, so a path of `..`, such a `/`, and more looked like
/// a single harmless name to code that split on characters, and the file system, which goes
/// by bytes, walked up a folder.
public enum PathSafety {
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

    /// The location a relative path from outside names below `root`; nil when the path is
    /// not made of safe names. Works on the text alone, and the result is checked once more
    /// to lie below `root` (`isContained`).
    public static func location(ofRelativePath path: String, below root: URL, allowingTrailingSeparator: Bool = false)
        -> URL?
    {
        guard let names = components(ofRelativePath: path, allowingTrailingSeparator: allowingTrailingSeparator) else {
            return nil
        }
        let url = names.reduce(root) { $0.appendingPathComponent($1, isDirectory: false) }
        return isContained(url, in: root) ? url : nil
    }

    /// Whether `url` lies below `root` once both are written out in full (`.` and `..`
    /// resolved): the paths are compared byte for byte, component by component. With
    /// `resolvingLinks`, symbolic links on the way are followed first, for both, which asks
    /// the disk and is for local files only: a link inside the folder that points out of it
    /// is then seen for what it is, also when the file at the end does not exist yet.
    public static func isContained(_ url: URL, in root: URL, resolvingLinks: Bool = false) -> Bool {
        guard (url.scheme ?? "file") == (root.scheme ?? "file"), url.host == root.host, url.port == root.port else {
            return false
        }
        func bytes(_ url: URL) -> [UInt8] {
            var path = Array((resolvingLinks && url.isFileURL ? resolved(url) : url.standardized.path).utf8)
            while path.count > 1, path.last == 0x2F { path.removeLast() }
            return path
        }
        let (own, above) = (bytes(url), bytes(root))
        // A path that still names a way up after being written out in full starts above its root.
        if own.split(separator: 0x2F).contains(where: { $0.elementsEqual([0x2E, 0x2E]) }) { return false }
        guard own.count > above.count, own.starts(with: above) else { return false }
        return above.last == 0x2F || own[above.count] == 0x2F
    }

    /// The path of a local file with every link on the way followed: the part of the path
    /// that exists is resolved by the system, and what does not exist yet follows it as written.
    private static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while true {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                return rest.reversed().reduce(String(cString: real)) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            guard existing.pathComponents.count > 1 else { return url.standardizedFileURL.path }
            rest.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
    }
}
