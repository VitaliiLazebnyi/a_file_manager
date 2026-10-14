import AFMContracts
import AFMKernel
import Foundation

/// The names of files as text, in the forms of spec 07 › Names to the clipboard: one item per
/// line, no header unless asked for, no line break after the last line, folders with a
/// trailing `/` (the Mac's `\`).
///
/// A value type without state of its own: it may be used from any thread. `details` calls the
/// columns' `value`, which may block, so that one is for a job's thread.
struct NameList {
    /// What stands in the first field of a line.
    enum Style {
        /// `name.ext`
        case name
        /// The full path as the file system writes it.
        case fullPath
        /// The item's URL (`file:///…`): what TC's UNC variants are on the Mac.
        case url
    }

    /// One column of the details form.
    struct Column {
        let title: String
        let value: @Sendable (FileItem) -> String
    }

    /// How a file system writes a location; answers at once (`FileSystemRegistry.displayPath`).
    let displayPath: @Sendable (URL) -> String

    func entry(_ item: FileItem, _ style: Style) -> String {
        let text: String
        switch style {
        case .name: text = item.name
        case .fullPath: text = displayPath(item.url)
        case .url: text = item.url.absoluteString
        }
        return item.isFolder && !text.hasSuffix("/") ? text + "/" : text
    }

    func names(_ items: [FileItem], _ style: Style) -> String {
        items.map { entry($0, style) }.joined(separator: "\n")
    }

    /// The folder of each item, one line per item (`cm_CopyPathOfFilesToClip`).
    func parentPaths(_ items: [FileItem]) -> String {
        items.map { displayPath($0.url.deletingLastPathComponent()) }.joined(separator: "\n")
    }

    /// The columns every panel has, after the name: size in raw bytes or `<DIR>`, date as in
    /// the panel, permissions (spec 07 › Names to the clipboard).
    static let standardColumns = [
        Column(title: "Size") { item in
            item.isFolder ? (item.computedSize.map { String($0) } ?? "<DIR>") : String(item.size)
        },
        Column(title: "Date") { Format.date($0.modified) },
        Column(title: "Attr") { Format.permissions($0.permissions) }
    ]

    /// All shown columns, tab-separated. `extra` are the plugin columns the panel shows; their
    /// values may block, so the rows are worked out on all cores and this belongs on a job's
    /// thread. `mask` picks columns by bit (1 = name, 2 = the first column after it, 4 = the
    /// next, …; spec 17 › Commands with parameters); nil, 0 and 1 give every column.
    func details(_ items: [FileItem], _ style: Style, headers: Bool, extra: [Column] = [], mask: Int? = nil) -> String {
        var columns = [Column(title: "Name") { entry($0, style) }] + Self.standardColumns + extra
        if let mask, mask > 1 {
            columns = columns.enumerated().filter { $0.offset < Int.bitWidth - 1 && mask & (1 << $0.offset) != 0 }.map(
                \.element)
        }
        let picked = columns
        var lines = Parallel.map(items, serialBelow: extra.isEmpty ? Int.max : 2) { item in
            picked.map { Self.field($0.value(item)) }.joined(separator: "\t")
        }
        if headers { lines.insert(picked.map(\.title).joined(separator: "\t"), at: 0) }
        return lines.joined(separator: "\n")
    }

    /// A value on one line: tabs and line breaks inside it would break the table.
    private static func field(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }
}

/// What Paste makes a new file of when the clipboard holds no files.
enum PastedContent: Equatable {
    case text(String)
    /// PNG data, or any other picture format AppKit reads (converted on the job's thread).
    case image(Data)

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .image: return "png"
        }
    }

    /// The first name of the form `Clipboard.txt`, `Clipboard (2).txt`, … that `isTaken`
    /// does not report as used.
    static func freeName(extension ext: String, isTaken: (String) -> Bool) -> String {
        var name = "Clipboard.\(ext)"
        var number = 2
        while isTaken(name) {
            name = "Clipboard (\(number)).\(ext)"
            number += 1
        }
        return name
    }
}
