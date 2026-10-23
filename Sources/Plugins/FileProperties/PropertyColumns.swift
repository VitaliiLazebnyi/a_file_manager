import AFMContracts
import AFMKernel
import Foundation

/// The columns this plugin adds to the file list (spec 03 › Custom columns, 15 › Content
/// plugins; the comment column is the Comments view of 03 › View types).
///
/// **Threading.** A column's `value` is called on background threads, several at once. Each
/// value here asks the disk about one item with calls that are safe to make concurrently
/// (`lstat`, `readlink`, `listxattr`, resource values) and keeps no state; the comment column
/// goes through `CommentStore`, which guards its own. Columns that need the Mac's file system
/// are empty for items elsewhere.
internal enum PropertyColumns {
    /// Adds every column of the plugin to `columns`, the comment column reading through `comments`.
    internal static func register(in columns: ColumnRegistry, comments: CommentStore) {
        // The comment file may lie on a server: the reading, and the wait of the other rows
        // for it, end when the panel no longer wants the answer.
        columns.register(
            ContentColumn(id: "comment", title: "Comment", width: 220) { item, cancellation in
                comments.comment(for: item, cancellation: cancellation).replacingOccurrences(of: "\n", with: " ")
            }
        )
        columns.register(local("owner", "Owner", width: 90) { LocalInfo.userName($0.ownerID) })
        columns.register(local("group", "Group", width: 90) { LocalInfo.groupName($0.groupID) })
        columns.register(local("created", "Created", width: 120) { Format.date($0.created) })
        columns.register(local("accessed", "Accessed", width: 120) { Format.date($0.accessed) })
        columns.register(
            ContentColumn(id: "octal", title: "Mode", width: 50, alignsRight: true) { item in
                PropertyText.octal(item.permissions)
            }
        )
        columns.register(
            ContentColumn(id: "linkTarget", title: "Link Target", width: 200) { item in
                item.isSymlink ? LocalInfo.linkTarget(item.url) ?? "" : ""
            }
        )
        columns.register(ContentColumn(id: "kind", title: "Kind", width: 140) { item in LocalInfo.kind(of: item) })
        columns.register(
            ContentColumn(id: "tags", title: "Tags", width: 120) { item in
                LocalInfo.tags(item.url).joined(separator: ", ")
            }
        )
        columns.register(
            ContentColumn(id: "xattrCount", title: "Ext. Attributes", width: 60, alignsRight: true) { item in
                let count = LocalInfo.extendedAttributeNames(item.url).count
                return count == 0 ? "" : String(count)
            }
        )
        columns.register(
            ContentColumn(id: "sizeOnDisk", title: "Size on Disk", width: 100, alignsRight: true) { item in
                // A folder's own entry says nothing about its contents; measuring those is a command.
                item.isRealDirectory ? "" : localText(item) { Format.bytes($0.allocated) }
            }
        )
    }

    /// A column that shows one of the facts only the Mac's own file system knows; empty for items
    /// elsewhere, and for items that are gone.
    private static func local(
        _ id: String,
        _ title: String,
        width: Int,
        text: @escaping @Sendable (LocalDetails) -> String
    ) -> ContentColumn {
        ContentColumn(id: id, title: title, width: width) { item in localText(item, text) }
    }

    /// What `text` makes of the item's local details; empty for items elsewhere, and for items that are gone.
    private static func localText(_ item: FileItem, _ text: (LocalDetails) -> String) -> String {
        LocalInfo.details(item.url).map(text) ?? ""
    }
}
