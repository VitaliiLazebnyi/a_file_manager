import Foundation

/// What a rename mask sees of one item.
///
/// The name may differ from the name on disk: after "next step" the computed names stand in for the
/// old ones (spec 09 › Result list).
internal struct RenameSubject {
    /// The name the masks work on.
    internal var name: String
    /// Whether the item is a folder (`[I]` keeps the dots of folders in the name).
    internal var isFolder: Bool
    /// The size in bytes, for `[S]`.
    internal var size: Int64
    /// When the item was last changed, for the date and time placeholders.
    internal var modified: Date
    /// The folder the item is in, as the user reads it, without a trailing slash.
    internal var directoryPath: String
    /// The names of the folders above the item, from the top down.
    internal var folders: [String]
    /// Where the item is; only handed to `RenameContext.contentDate`.
    internal var url: URL?

    /// The path of the item as the user reads it.
    internal var fullPath: String { directoryPath.hasSuffix("/") ? directoryPath + name : directoryPath + "/" + name }

    /// A file of that name and nothing else known: no size, changed at the start of 1970, in no folder.
    internal init(name: String) {
        self.init(
            name: name,
            isFolder: false,
            size: 0,
            modified: Date(timeIntervalSince1970: 0),
            directoryPath: "",
            folders: [],
            url: nil
        )
    }

    /// An item as the list knows it.
    internal init(
        name: String,
        isFolder: Bool,
        size: Int64,
        modified: Date,
        directoryPath: String,
        folders: [String],
        url: URL?
    ) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.directoryPath = directoryPath
        self.folders = folders
        self.url = url
    }

    /// The names of the folders of a path, from the top down, cut at the `/` bytes.
    internal static func folders(in directoryPath: String) -> [String] {
        directoryPath.utf8.split(separator: 0x2F).map { String(directoryPath[$0.startIndex..<$0.endIndex]) }
    }
}
