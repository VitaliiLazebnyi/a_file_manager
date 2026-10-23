import Foundation

/// What identifies an entry on a local disk, so that two spellings of one place (another
/// letter case on a case-insensitive volume, `/tmp` and `/private/tmp`) are told apart from
/// two files.
///
/// Anything that is not a local path has no identity and compares as different.
internal enum FileIdentity {
    /// The status of the entry at a local path, or of what a link there points to; nil when it is not there.
    private static func status(_ path: String, followingLinks: Bool) -> stat? {
        var info = stat()
        return (followingLinks ? stat(path, &info) : lstat(path, &info)) == 0 ? info : nil
    }

    /// The same for a location; nil for anything that is not a local path.
    private static func status(_ url: URL, followingLinks: Bool) -> stat? {
        url.isFileURL ? status(url.path, followingLinks: followingLinks) : nil
    }

    /// The path of the folder above, down to the root, which has none.
    private static func parent(of path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else {
            return nil
        }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// The flags of the entry itself (the Finder's lock among them); nil when it cannot be asked.
    internal static func flags(of url: URL) -> UInt32? {
        status(url, followingLinks: false)?.st_flags
    }

    /// Gives an entry back the flags it had.
    internal static func restoreFlags(_ flags: UInt32, of url: URL) {
        guard url.isFileURL, let now = status(url, followingLinks: false), now.st_flags != flags else {
            return
        }
        lchflags(url.path, flags)
    }

    /// The volume the entry is on.
    internal static func device(of url: URL) -> dev_t? {
        status(url, followingLinks: true)?.st_dev
    }

    /// The volume of `url`, or of the nearest folder above it that exists.
    internal static func device(ofNearest url: URL) -> dev_t? {
        guard url.isFileURL else {
            return nil
        }
        var path = url.path
        // The nearest folder that is there: the root always is.
        while status(path, followingLinks: true) == nil, let above = parent(of: path) {
            path = above
        }
        return status(path, followingLinks: true)?.st_dev
    }

    /// True when both names are the same directory entry: the same file in the same folder,
    /// the names differing at most in letter case or in the form of an accented letter.
    ///
    /// Two hard links to one file are not.
    internal static func sameEntry(_ one: URL, _ other: URL) -> Bool {
        guard one.isFileURL, other.isFileURL,
            one.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                == other.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased(),
            let first = status(one, followingLinks: false), let second = status(other, followingLinks: false),
            first.st_dev == second.st_dev, first.st_ino == second.st_ino,
            let oneFolder = status(one.deletingLastPathComponent(), followingLinks: true),
            let otherFolder = status(other.deletingLastPathComponent(), followingLinks: true)
        else { return false }
        return oneFolder.st_dev == otherFolder.st_dev && oneFolder.st_ino == otherFolder.st_ino
    }

    /// True when `destination` is somewhere below `folder` as the disk sees it: in the folder
    /// itself or any folder inside it, whichever way the path is spelled or through whatever
    /// links it leads.
    ///
    /// Looks at the folders above `destination` that exist.
    internal static func isInside(_ destination: URL, folder: URL) -> Bool {
        guard destination.isFileURL, let own = status(folder, followingLinks: false) else {
            return false
        }
        var path = parent(of: destination.path)
        while let current = path {
            if let found = status(current, followingLinks: true),
                found.st_dev == own.st_dev, found.st_ino == own.st_ino
            {
                return true
            }
            path = parent(of: current)
        }
        return false
    }

    /// Device and inode of the entry itself (a link is not followed); nil for what is not a
    /// local path or is not there.
    internal static func id(of url: URL, followingLinks: Bool) -> (device: dev_t, inode: ino_t)? {
        guard url.isFileURL else {
            return nil
        }
        var info = stat()
        guard (followingLinks ? stat(url.path, &info) : lstat(url.path, &info)) == 0 else {
            return nil
        }
        return (info.st_dev, info.st_ino)
    }

    /// True when both locations are known to be one and the same file on disk right now.
    internal static func sameFile(_ one: URL, _ other: URL) -> Bool {
        guard let first = id(of: one, followingLinks: false), let second = id(of: other, followingLinks: false) else {
            return false
        }
        return first.device == second.device && first.inode == second.inode
    }

    /// A pipe, a device or a socket (or, with `followingLinks`, a link to one): opening it to
    /// read may wait for ever.
    ///
    /// False for what is not a local path or is not there.
    internal static func isSpecialNode(_ url: URL, followingLinks: Bool) -> Bool {
        guard url.isFileURL else {
            return false
        }
        var info = stat()
        guard (followingLinks ? stat(url.path, &info) : lstat(url.path, &info)) == 0 else {
            return false
        }
        let type = info.st_mode & S_IFMT
        return type != S_IFREG && type != S_IFDIR && type != S_IFLNK
    }

    /// True when `url` is a symbolic link itself on a local disk.
    internal static func isSymlink(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Whether the item may carry a flag that makes the system refuse to change or remove it
    /// (the Finder's Locked among them).
    ///
    /// False only when the flags of a local item were read and hold none of them: for what is not
    /// a local path, or is not there, nobody knows.
    internal static func mayBeLocked(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return true
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return true
        }
        return info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) != 0
    }

    /// True when `folder` is on another volume than the folder it lies in: a mounted disk, disk
    /// image or share.
    ///
    /// False when either cannot be asked.
    internal static func isMountPoint(_ folder: URL) -> Bool {
        guard let own = id(of: folder, followingLinks: false),
            let above = id(of: folder.deletingLastPathComponent(), followingLinks: true)
        else { return false }
        return own.device != above.device
    }

    /// How coarsely the volume of `url` (or of the nearest folder above it that exists) keeps
    /// the time of last change, in seconds: 0 where it keeps it exactly.
    internal static func timestampGrain(of url: URL) -> TimeInterval {
        // A server or an archive: FTP lists minutes, ZIP stores even seconds.
        guard url.isFileURL else {
            return 2
        }
        var folder = url
        var info = statfs()
        // The nearest folder that is there: the root always is.
        while statfs(folder.path, &info) != 0, folder.path != "/" {
            folder.deleteLastPathComponent()
        }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        return timestampGrain(ofType: type, isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0)
    }

    /// The same for a volume of the file system type `type` (`apfs`, `hfs`, `msdos` …), local or not.
    internal static func timestampGrain(ofType type: String, isLocal: Bool) -> TimeInterval {
        // A share keeps what its server keeps, which nobody can tell from here.
        guard isLocal else {
            return 2
        }
        switch type {
        case "apfs":
            return 0

        case "hfs":
            return 1

        default:
            // FAT and exFAT keep even seconds; whatever else there is gets the same caution.
            return 2
        }
    }
}
