import AFMKernel
import Foundation

/// One file or folder inside an archive, whatever the archive's format.
internal struct ArchiveEntry {
    /// Where the bytes of a member come from.
    internal enum Content {
        /// Nothing to read: folders, empty files.
        case empty
        /// A ZIP member, with everything its directory says.
        case zip(ZipRecord)
        /// A stretch of the archive file (TAR) or of its unpacked copy.
        case range(offset: UInt64, length: UInt64)
        /// The n-th member of an archive that can only be read from the start.
        case member(index: Int)
        /// The whole decompressed file (`.gz`, `.bz2`, `.xz`).
        case whole
        /// Text held in memory: the target of a symbolic link.
        case text(String)
        /// A member that is listed but cannot be read; the text says what it is.
        case unsupported(String)
    }

    /// The path inside the archive: names joined by `/`, none at either end.
    internal var path: String
    /// True for a folder, made up or listed by the archive.
    internal var isDirectory: Bool
    /// A folder the archive has no entry for; it exists because something lies inside it.
    internal var isImplicit = false
    /// True for a symbolic link; its target is the member's content.
    internal var isSymbolicLink = false
    /// A device, a pipe or a socket in the archive's own terms (`FileItem.isSpecial`).
    internal var isSpecial = false
    /// Unpacked size.
    internal var size: Int64 = 0
    /// False when the size is only what the file claims in a place that cannot be trusted
    /// (the last bytes of a large `.gz`): it is shown, and nothing is checked against it.
    internal var sizeIsExact = true
    /// The size the member takes in the archive, compressed; 0 when the format does not say.
    internal var packedSize: Int64 = 0
    /// The date of last change the archive gives the member.
    internal var modified = Date(timeIntervalSince1970: 0)
    /// The POSIX permission bits the archive gives the member.
    internal var permissions: UInt16 = 0o644
    /// True when the member's data is encrypted: reading it needs the password.
    internal var isEncrypted = false
    /// The position in the archive; members are unpacked and rewritten in this order.
    internal var order = 0
    /// Where the member's bytes are read from.
    internal var content = Content.empty

    /// The last name of the path.
    internal var name: String { ArchiveTree.name(of: path) }

    /// The entry as a panel item at `url`, the location that names it inside the archive.
    internal func item(at url: URL) -> FileItem {
        FileItem(
            url: url,
            name: name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymbolicLink,
                isHidden: name.hasPrefix("."),
                isSpecial: isSpecial
            ),
            stat: .init(size: isDirectory ? 0 : size, modified: modified, permissions: permissions)
        )
    }
}
