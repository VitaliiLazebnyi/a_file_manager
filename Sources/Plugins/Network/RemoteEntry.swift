import AFMKernel
public import Foundation

/// One entry of a directory on a server, as far as the server told.
public struct RemoteEntry: Equatable, Sendable {
    /// The entry's name: one path component, checked with `isSafeName` before it is used.
    public var name: String
    /// Whether the entry is a folder (for a link: whether the server listed it as one).
    public var isDirectory: Bool
    /// Whether the entry is a symbolic link.
    public var isSymlink: Bool
    /// Where a symbolic link points, when the listing says so.
    public var linkTarget: String?
    /// The size in bytes; 0 when the listing gives none.
    public var size: Int64
    /// The time of the last change, when the listing gives one that is a date.
    public var modified: Date?
    /// The Unix permission bits (with set-user-id, set-group-id and sticky), when the listing gives them.
    public var permissions: UInt16?
    /// A device, a pipe or a socket, where the listing tells the type (`FileItem.isSpecial`).
    public var isSpecial = false

    /// An entry with what a listing told; what it left out keeps its default.
    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        linkTarget: String? = nil,
        size: Int64 = 0,
        modified: Date? = nil,
        permissions: UInt16? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    /// Whether a name from a server may become a path below a local or remote folder.
    ///
    /// A name is one path component: a server that sends `../../x` or `a/b` must not be able to
    /// place a file outside the folder the user chose.
    ///
    /// The name must also stay one component when the path it becomes part of is read as
    /// text: a name that begins with a combining mark would melt into the slash before it
    /// (`RemotePath.hasSeparableNames`), and is left out like the others.
    internal static func isSafeName(_ name: String) -> Bool {
        // The kernel's check of a single name (by bytes: not empty, no `.` or `..`, no slash, no
        // zero byte), and what only a server's listing adds to it.
        PathSafety.isSafeName(name) && RemotePath.hasSeparableNames(name)
    }

    /// `isSafeName` for a name from a Windows/DOS listing, which also rejects the backslash: Windows
    /// servers use it as a separator.
    internal static func isSafeDOSName(_ name: String) -> Bool {
        !name.utf8.contains(0x5C) && isSafeName(name)
    }

    /// The entry as a panel shows it.
    internal func item(in directory: URL) -> FileItem {
        FileItem(
            url: directory.appending(name: name),
            name: name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                isHidden: name.hasPrefix("."),
                isSpecial: isSpecial
            ),
            stat: .init(
                size: isDirectory ? 0 : size,
                modified: modified ?? Date(timeIntervalSince1970: 0),
                permissions: permissions ?? (isDirectory ? 0o755 : 0o644)
            )
        )
    }
}
