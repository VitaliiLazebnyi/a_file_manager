import Foundation

/// The attributes SFTP sends with a name (draft-ietf-secsh-filexfer-02 › File Attributes).
internal struct SFTPAttributes {
    /// The size in bytes; nil when the server did not say.
    internal var size: UInt64?
    /// The file type and permission bits as `stat` has them; nil when the server did not say.
    internal var permissions: UInt32?
    /// The modification time in seconds since 1970; nil when the server did not say.
    internal var modified: UInt32?

    /// Whether the type bits say directory.
    internal var isDirectory: Bool { (permissions ?? 0) & 0o170000 == 0o040000 }
    /// Whether the type bits say symbolic link.
    internal var isSymlink: Bool { (permissions ?? 0) & 0o170000 == 0o120000 }

    /// A device, a pipe or a socket.
    internal var isSpecial: Bool { [0o010000, 0o020000, 0o060000, 0o140000].contains((permissions ?? 0) & 0o170000) }

    /// The entry of a listing with these attributes and this name.
    internal func entry(named name: String) -> RemoteEntry {
        var entry = RemoteEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: Int64(clamping: size ?? 0),
            modified: modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            permissions: permissions.map { UInt16($0 & 0o7777) }
        )
        entry.isSpecial = isSpecial
        return entry
    }
}
