import AFMKernel
import Foundation
import UniformTypeIdentifiers

/// What the Mac's own file system knows about an item beyond the provider interface: owner,
/// further dates, flags and the space it really takes.
internal struct LocalDetails: Equatable {
    internal var mode: UInt16
    internal var ownerID: uid_t
    internal var groupID: gid_t
    internal var created: Date
    internal var modified: Date
    internal var accessed: Date
    /// `st_flags`: `UF_HIDDEN`, `UF_IMMUTABLE` (Finder's Locked) and the rest.
    internal var flags: UInt32
    /// The bytes the item takes on its volume.
    internal var allocated: Int64
    internal var linkCount: Int

    internal var isHidden: Bool { flags & UInt32(UF_HIDDEN) != 0 }
    internal var isLocked: Bool { flags & UInt32(UF_IMMUTABLE) != 0 }
}

/// Questions and changes that only make sense for `file:` URLs, done with POSIX calls.
///
/// **Threading.** Everything here blocks on the disk and is meant for background threads; all
/// of it may be called from several threads at once. The name caches are the only shared state
/// and are guarded by a lock.
internal enum LocalInfo {
    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var userNames: [uid_t: String] = [:]
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var groupNames: [gid_t: String] = [:]

    /// How often a name had to be asked of the system (which may be a directory server on
    /// the network) because it was not known yet.
    ///
    /// For tests: they check that this happens on a job's thread and not when a dialog is put
    /// together.
    internal static var nameLookups: Int { lock.withLock { lookups } }
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var lookups = 0

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    internal static func posixError(_ code: Int32, _ url: URL) -> any Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)) + ": " + url.path]
        )
    }

    /// The item itself; a link is not followed.
    ///
    /// Nil when nothing is there.
    internal static func details(_ url: URL) -> LocalDetails? {
        guard url.isFileURL else {
            return nil
        }
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return nil
        }
        return LocalDetails(
            mode: UInt16(st.st_mode & 0o7777),
            ownerID: st.st_uid,
            groupID: st.st_gid,
            created: date(st.st_birthtimespec),
            modified: date(st.st_mtimespec),
            accessed: date(st.st_atimespec),
            flags: st.st_flags,
            allocated: Int64(st.st_blocks) * 512,
            linkCount: Int(st.st_nlink)
        )
    }

    /// Whether the entry itself is a symbolic link, asked from the disk now.
    internal static func isSymlink(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// False when reading `url` could wait for ever: it is, or leads to, a pipe, a device or
    /// a socket.
    ///
    /// True for everything else, and for what is not on a local disk.
    internal static func canBeRead(_ url: URL) -> Bool {
        guard url.isFileURL else {
            return true
        }
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            return true
        }
        let type = st.st_mode & S_IFMT
        return type == S_IFREG || type == S_IFDIR
    }

    internal static func userName(_ id: uid_t) -> String {
        lock.lock()
        let known = userNames[id]
        if known == nil { lookups += 1 }
        lock.unlock()
        if let known {
            return known
        }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        let name =
            getpwuid_r(id, &entry, &buffer, buffer.count, &result) == 0 && result != nil
            ? String(cString: entry.pw_name) : String(id)
        lock.lock()
        userNames[id] = name
        lock.unlock()
        return name
    }

    internal static func groupName(_ id: gid_t) -> String {
        lock.lock()
        let known = groupNames[id]
        if known == nil { lookups += 1 }
        lock.unlock()
        if let known {
            return known
        }
        var entry = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        let name =
            getgrgid_r(id, &entry, &buffer, buffer.count, &result) == 0 && result != nil
            ? String(cString: entry.gr_name) : String(id)
        lock.lock()
        groupNames[id] = name
        lock.unlock()
        return name
    }

    /// A user by name or number; nil when there is no such user.
    internal static func userID(_ text: String) -> uid_t? {
        if let number = uid_t(text) {
            return number
        }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        return getpwnam_r(text, &entry, &buffer, buffer.count, &result) == 0 && result != nil ? entry.pw_uid : nil
    }

    internal static func groupID(_ text: String) -> gid_t? {
        if let number = gid_t(text) {
            return number
        }
        var entry = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 4_096)
        return getgrnam_r(text, &entry, &buffer, buffer.count, &result) == 0 && result != nil ? entry.gr_gid : nil
    }

    /// Where a symbolic link points, as it is written in the link.
    internal static func linkTarget(_ url: URL) -> String? {
        guard url.isFileURL else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(url.path, &buffer, Int(PATH_MAX))
        guard length >= 0 else {
            return nil
        }
        buffer[length] = 0
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The item a link leads to: the target of a symbolic link (relative targets count from
    /// the link's folder) or the original of a Finder alias.
    ///
    /// Nil when `url` is neither. An alias is resolved without mounting volumes and without any
    /// dialog.
    internal static func resolvedLinkTarget(_ url: URL) -> URL? {
        if let target = linkTarget(url) {
            return URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
            let bookmark = try? URL.bookmarkData(withContentsOf: url)
        else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// The names of the item's extended attributes; a link is not followed.
    internal static func extendedAttributeNames(_ url: URL) -> [String] {
        guard url.isFileURL else {
            return []
        }
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else {
            return []
        }
        var buffer = [CChar](repeating: 0, count: length)
        // The names may have gone meanwhile: what the second call fills is what there is.
        let filled = listxattr(url.path, &buffer, length, XATTR_NOFOLLOW)
        return buffer.prefix(max(filled, 0)).split(separator: 0)
            .map {
                (Array($0) + [0]).withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
    }

    internal static func tags(_ url: URL) -> [String] {
        guard url.isFileURL else {
            return []
        }
        return (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// What kind of file this is, in the user's language: "PNG image", "Folder".
    ///
    /// Local files are asked from the system; elsewhere the extension decides.
    internal static func kind(of item: FileItem) -> String {
        if item.url.isFileURL,
            let kind = try? item.url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        {
            return kind
        }
        if item.isSymlink {
            return "Symbolic link"
        }
        if item.isFolder {
            return "Folder"
        }
        let ext = FileItem.split(item.name).ext
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
    }

    /// Sets or clears a flag of `st_flags` on the item itself (a link is not followed).
    internal static func setFlag(_ flag: UInt32, _ isOn: Bool, of url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw posixError(errno, url) }
        let flags = isOn ? st.st_flags | flag : st.st_flags & ~flag
        guard flags != st.st_flags else {
            return
        }
        if lchflags(url.path, flags) != 0 { throw posixError(errno, url) }
    }

    /// Changes owner and group of the item itself; nil leaves one as it is.
    internal static func setOwner(_ owner: uid_t?, group: gid_t?, of url: URL) throws {
        // The all-ones value means "unchanged" to the system.
        if lchown(url.path, owner ?? uid_t.max, group ?? gid_t.max) != 0 { throw posixError(errno, url) }
    }

    /// The allocation unit of the volume `url` is on; sizes on disk are multiples of it.
    internal static func clusterSize(at url: URL) -> Int64? {
        guard url.isFileURL else {
            return nil
        }
        var info = statfs()
        guard statfs(url.path, &info) == 0, info.f_bsize > 0 else {
            return nil
        }
        return Int64(info.f_bsize)
    }
}
