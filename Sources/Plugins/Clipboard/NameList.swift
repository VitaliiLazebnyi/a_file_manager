import AFMContracts
import AFMKernel
import Foundation

/// The names of files as text, in the forms of spec 07 › Names to the clipboard: one item per
/// line, no header unless asked for, no line break after the last line, folders with a
/// trailing `/` (the Mac's `\`).
///
/// A value type without state of its own: it may be used from any thread. `details` calls the
/// columns' `value`, which may block, so that one is for a job's thread.
internal struct NameList {
    /// What stands in the first field of a line.
    internal enum Style {
        /// `name.ext`
        case name
        /// The full path as the file system writes it.
        case fullPath
        /// The item's URL (`file:///…`): what TC's UNC variants are on the Mac.
        case url
    }

    /// One column of the details form.
    internal struct Column {
        /// The column's title, for the line of headers.
        internal let title: String
        /// The column's text for an item; it may block, so it is asked on a job's thread.
        internal let value: @Sendable (FileItem) -> String
    }

    /// The columns every panel has, after the name: size in raw bytes or `<DIR>`, date as in
    /// the panel, permissions (spec 07 › Names to the clipboard).
    internal static let standardColumns = [
        Column(title: "Size") { item in
            item.isFolder ? (item.computedSize.map { String($0) } ?? "<DIR>") : String(item.size)
        },
        Column(title: "Date") { Format.date($0.modified) },
        Column(title: "Attr") { Format.permissions($0.permissions) }
    ]

    /// How a file system writes a location; answers at once (`FileSystemRegistry.displayPath`).
    internal let displayPath: @Sendable (URL) -> String

    /// A value on one line: tabs and line breaks inside it would break the table.
    private static func field(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }

    /// The first field of an item's line: its name, path or URL, a folder's with a trailing `/`.
    internal func entry(_ item: FileItem, _ style: Style) -> String {
        let text: String
        switch style {
        case .name:
            text = item.name

        case .fullPath:
            text = displayPath(item.url)

        case .url:
            text = item.url.absoluteString
        }
        return item.isFolder && !text.hasSuffix("/") ? text + "/" : text
    }

    /// The entries of the items, one per line, without a line break after the last.
    internal func names(_ items: [FileItem], _ style: Style) -> String {
        items.map { item in entry(item, style) }.joined(separator: "\n")
    }

    /// The folder of each item, one line per item (`cm_CopyPathOfFilesToClip`).
    internal func parentPaths(_ items: [FileItem]) -> String {
        items.map { displayPath($0.url.deletingLastPathComponent()) }.joined(separator: "\n")
    }

    /// All shown columns, tab-separated. `extra` are the plugin columns the panel shows; their
    /// values may block, so the rows are worked out on all cores and this belongs on a job's
    /// thread. `mask` picks columns by bit (1 = name, 2 = the first column after it, 4 = the
    /// next, …; spec 17 › Commands with parameters); nil, 0 and 1 give every column.
    internal func details(_ items: [FileItem], _ style: Style, headers: Bool, extra: [Column], mask: Int?) -> String {
        var columns = [Column(title: "Name") { item in entry(item, style) }] + Self.standardColumns + extra
        if let mask, mask > 1 {
            columns = columns.enumerated()
                .filter { column in column.offset < Int.bitWidth - 1 && mask & (1 << column.offset) != 0 }
                .map(\.element)
        }
        let picked = columns
        var lines = Parallel.map(items, serialBelow: extra.isEmpty ? Int.max : 2) { item in
            picked.map { Self.field($0.value(item)) }.joined(separator: "\t")
        }
        if headers { lines.insert(picked.map(\.title).joined(separator: "\t"), at: 0) }
        return lines.joined(separator: "\n")
    }
}
