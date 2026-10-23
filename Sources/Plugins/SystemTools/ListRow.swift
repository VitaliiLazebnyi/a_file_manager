import AFMKernel
import Foundation

/// One line of a printed file list (spec 12 › Printing).
internal struct ListRow: Equatable {
    /// The name, or the path below the list's base folder for an item of a subfolder.
    internal let name: String
    /// The row stands for a folder: it shows `<DIR>` and is not counted among the files.
    internal let isFolder: Bool
    /// The size in bytes; for a folder the size computed for it, 0 when none was.
    internal let size: Int64
    /// When the item was last changed.
    internal let modified: Date
    /// The POSIX permission bits, shown as `rwxr-xr-x`.
    internal let permissions: UInt16

    /// A row of the values given.
    internal init(name: String, isFolder: Bool, size: Int64, modified: Date, permissions: UInt16) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    /// The row of `item`, shown under `path` (its name, or its path below the base folder).
    internal init(_ item: FileItem, path: String) {
        self.init(
            name: path,
            isFolder: item.isFolder,
            size: item.isFolder ? (item.computedSize ?? 0) : item.size,
            modified: item.modified,
            permissions: item.permissions
        )
    }
}
