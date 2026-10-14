import AFMContracts
import AFMKernel
import Foundation

/// A location as the file system it really lies on names it.
///
/// A file system that only shows the files of others (a branch view, a list of files) names a
/// folder by the path of the real one and answers `parent(of:)` with that real folder: the
/// same path under another scheme. Whatever is built from such a location (a target, a new
/// name) would be a second spelling of a real place, which no comparison of locations sees
/// through; so the real one is taken before anything is planned.
enum RealLocation {
    /// The real place behind `url`; `url` itself when it stands for nothing else. Works on the
    /// text of the locations alone, so it may be asked on the main thread.
    ///
    /// A file system that shows the files of others says so itself
    /// (`FileSystemProvider.realLocation(of:)`), and that answer is taken first. One that
    /// does not is still seen through by what its `parent(of:)` answers.
    static func resolve(_ url: URL, in fileSystems: FileSystemRegistry) -> URL {
        var current = fileSystems.realLocation(of: url)
        // A view of a view is as deep as it gets; the bound keeps a confused provider from looping.
        for _ in 0..<4 {
            guard !current.isFileURL, let provider = try? fileSystems.provider(for: current),
                let real = provider.parent(of: current),
                (real.scheme ?? "file") != (current.scheme ?? "file"), path(of: real) == path(of: current)
            else { break }
            current = fileSystems.realLocation(of: real)
        }
        return current
    }

    private static func path(of url: URL) -> String {
        let path = url.standardized.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// True when files can be addressed below `directory` by writing its displayed path with
    /// a name after it, which is how the target field of a dialog names them. A list of files
    /// from anywhere is not such a place.
    static func takesNames(_ directory: URL, in fileSystems: FileSystemRegistry) -> Bool {
        if directory.isFileURL { return true }
        let typed = fileSystems.displayPath(directory)
        // Read from somewhere else: a path that only means something relative to where one
        // stands is not the name of this place.
        let probe = fileSystems.location(
            from: (typed.hasSuffix("/") ? typed : typed + "/") + "x", relativeTo: URL(fileURLWithPath: "/"))
        return (probe.scheme ?? "file") == (directory.scheme ?? "file")
    }
}

/// Names as they are shown in questions and written to the log. A file name may hold anything
/// but `/` and NUL: line breaks, characters that turn the reading direction around, characters
/// without width. Shown raw, such a name can make a question say something else than it asks,
/// or add lines to a log.
public enum DisplayName {
    /// The text with every such character written out as `<U+202E>`: the program's one
    /// rule for it (`Format.displayName`), so that every message shows a name the same way.
    public static func escaped(_ text: String) -> String {
        Format.displayName(text)
    }
}

extension FileIdentity {
    /// Device and inode of the entry itself (a link is not followed); nil for what is not a
    /// local path or is not there.
    static func id(of url: URL, followingLinks: Bool = false) -> (device: dev_t, inode: ino_t)? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard (followingLinks ? stat(url.path, &info) : lstat(url.path, &info)) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    /// True when both locations are known to be one and the same file on disk right now.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let first = id(of: a), let second = id(of: b) else { return false }
        return first.device == second.device && first.inode == second.inode
    }

    /// A pipe, a device or a socket (or, with `followingLinks`, a link to one): opening it to
    /// read may wait for ever. False for what is not a local path or is not there.
    static func isSpecialNode(_ url: URL, followingLinks: Bool) -> Bool {
        guard url.isFileURL else { return false }
        var info = stat()
        guard (followingLinks ? stat(url.path, &info) : lstat(url.path, &info)) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return type != S_IFREG && type != S_IFDIR && type != S_IFLNK
    }

    static func isSymlink(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Whether the item carries a flag that makes the system refuse to change or remove it
    /// (the Finder's Locked among them). Nil for what is not a local path: there nobody knows.
    static func isLocked(_ url: URL) -> Bool? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND) != 0
    }

    /// True when `folder` is on another volume than the folder it lies in: a mounted disk, disk
    /// image or share. False when either cannot be asked.
    static func isMountPoint(_ folder: URL) -> Bool {
        guard let own = id(of: folder), let above = id(of: folder.deletingLastPathComponent(), followingLinks: true)
        else { return false }
        return own.device != above.device
    }

    /// How coarsely the volume of `url` (or of the nearest folder above it that exists) keeps
    /// the time of last change, in seconds: 0 where it keeps it exactly.
    static func timestampGrain(of url: URL) -> TimeInterval {
        // A server or an archive: FTP lists minutes, ZIP stores even seconds.
        guard url.isFileURL else { return 2 }
        var path: String? = url.path
        var info = statfs()
        while let current = path {
            if statfs(current, &info) == 0 { break }
            path = current == "/" || current.isEmpty ? nil : (current as NSString).deletingLastPathComponent
        }
        guard path != nil else { return 2 }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        // A share keeps what its server keeps, which nobody can tell from here.
        guard info.f_flags & UInt32(MNT_LOCAL) != 0 else { return 2 }
        switch type {
        case "apfs": return 0
        case "hfs": return 1
        default: return 2  // FAT and exFAT keep even seconds; whatever else there is gets the same caution
        }
    }
}
