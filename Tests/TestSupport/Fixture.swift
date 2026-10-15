public import AFMKernel
public import Foundation

/// Entries, listings and panel models made up on the spot, for tests that need a list without a file system behind it.
///
/// Locations are made from the text alone; nothing is read.
public enum Fixture {
    /// A file called `name` in `folder`, of `size` bytes, last changed `modified` seconds after 1970.
    public static func file(_ name: String, in folder: URL, size: Int64 = 1, modified: TimeInterval = 0) -> FileItem {
        FileItem(
            url: folder.appending(name: name),
            name: name,
            stat: .init(size: size, modified: Date(timeIntervalSince1970: modified))
        )
    }

    /// A folder called `name` in `folder`, last changed `modified` seconds after 1970.
    public static func folder(_ name: String, in folder: URL, modified: TimeInterval = 0) -> FileItem {
        FileItem(
            url: folder.appending(name: name),
            name: name,
            kind: .directory,
            stat: .init(modified: Date(timeIntervalSince1970: modified))
        )
    }

    /// The listing of `directory` holding `items`, with the folder above as its parent and `/` as its root.
    public static func listing(_ items: [FileItem], at directory: URL) -> Listing {
        Listing(
            directory: directory,
            items: items,
            parent: directory.deletingLastPathComponent(),
            root: URL(fileURLWithPath: "/")
        )
    }

    /// A panel model sorted by `sort` that shows the listing of `directory` holding `items`.
    @MainActor
    @preconcurrency
    public static func panel(_ items: [FileItem], at directory: URL, sort: ListOrder = ListOrder()) -> PanelModel {
        let model = PanelModel(directory: directory, sort: sort)
        model.show(listing(items, at: directory))
        return model
    }
}
