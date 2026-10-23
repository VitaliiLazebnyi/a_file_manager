import AFMKernel
import Foundation

/// One row of the rename list: the file as it is on disk, and the name the masks work on
/// (which differs from the file's after "next step").
internal struct RenameEntry {
    /// The file as it was listed.
    internal var item: FileItem
    /// The name the masks work on.
    internal var name: String

    /// The name the file has in its folder now.
    internal var diskName: String { Self.diskName(of: item) }

    /// The folder the file is in.
    internal var directory: URL { item.url.deletingLastPathComponent() }

    /// The row of `item`, its masks working on the name it has in its folder.
    internal init(_ item: FileItem) {
        self.item = item
        name = Self.diskName(of: item)
    }

    /// The name the file has in its folder.
    ///
    /// A list gathered from elsewhere (a branch view, a search result) names its items by path, on
    /// every file system; the item's own location says what it is called. (A name with a slash
    /// would otherwise be read as a folder to move into.).
    internal static func diskName(of item: FileItem) -> String {
        item.name.utf8.contains(0x2F) ? item.url.lastPathComponent : item.name
    }
}
