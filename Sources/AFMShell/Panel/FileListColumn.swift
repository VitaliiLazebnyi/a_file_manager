import AFMContracts
import AFMKernel
import AppKit
import UniformTypeIdentifiers

/// The columns of the Full view and how a row is drawn in each (spec 03 › Rows in Full view).
/// The raw values are the columns' identifiers in the table and in the remembered widths.
@MainActor
internal enum FileListColumn: String {
    /// The permissions.
    case attr = "attr"
    /// The date of the last change.
    case date = "date"
    /// The extension.
    case ext = "ext"
    /// The name without its extension; folders in brackets.
    case name = "name"
    /// The size, or what a folder is.
    case size = "size"

    /// The columns of the Full view, from left to right.
    internal static let fullView: [Self] = [.name, .ext, .size, .date, .attr]
    /// The icon of the `[..]` row.
    internal static let parentIcon = NSImage(
        systemSymbolName: "arrow.turn.left.up",
        accessibilityDescription: "Parent directory"
    )
    /// The cells of all plugin columns are alike, so they share one kind of cell.
    internal static let extraCellIdentifier = NSUserInterfaceItemIdentifier("extra")

    /// The icons of file types, by extension; main thread only. Extensions are whatever the
    /// names in a folder end in, so the store is bounded like the others.
    private static var typeIcons = TwoGenerationCache<String, NSImage>(limit: 2_000)

    /// What the table knows the column and its cells by.
    internal var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    /// The caption of the column's header.
    internal var title: String {
        switch self {
        case .name:
            return "Name"

        case .ext:
            return "Ext"

        case .size:
            return "Size"

        case .date:
            return "Date"

        case .attr:
            return "Attr"
        }
    }

    /// The sort key a click on the header chooses; Attr does not sort.
    internal var sortKey: SortKey? {
        switch self {
        case .name:
            return .name

        case .ext:
            return .ext

        case .size:
            return .size

        case .date:
            return .date

        case .attr:
            return nil
        }
    }

    /// The command a click on the header runs.
    internal var sortCommand: CommandID? {
        switch self {
        case .name:
            return .sortByName

        case .ext:
            return .sortByExtension

        case .size:
            return .sortBySize

        case .date:
            return .sortByTime

        case .attr:
            return nil
        }
    }

    /// The width a column starts with.
    private var width: CGFloat {
        switch self {
        case .name:
            return 260

        case .ext:
            return 60

        case .size:
            return 100

        case .date:
            return 125

        case .attr:
            return 85
        }
    }

    /// What a column shows in the `[..]` row: its name, `<DIR>` as its size, nothing else.
    private var parentText: String {
        switch self {
        case .name:
            return "[..]"

        case .size:
            return "<DIR>"

        case .ext, .date, .attr:
            return ""
        }
    }

    /// On a local disk a file shows its own icon. Asking the system for it reads the file's
    /// surroundings, which takes 30 µs for a plain file on a good day and for ever on a disk
    /// that does not answer, so it is never asked on the main thread: until the icon has been
    /// fetched in the background (`IconStore`) the file shows the icon of its type, which is
    /// looked up once per extension. A file that is not on a volume of this machine (a share,
    /// whatever the folder it is listed in says) is never asked at all: there every question
    /// is a trip to the server.
    internal static func icon(for item: FileItem, own: Bool) -> NSImage {
        if own, item.url.isFileURL {
            let path = item.url.path
            if Mounts.isLocal(path: path), let icon = IconStore.shared.icon(forPath: path, modified: item.modified) {
                return icon
            }
        }
        let key = item.isFolder ? "/folder" : item.url.pathExtension.lowercased()
        if let cached = typeIcons[key] {
            return cached
        }
        let icon =
            item.isFolder
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        typeIcons[key] = icon
        return icon
    }

    /// A cell for a plugin column.
    internal static func makeExtraCell() -> NSTableCellView {
        let cell = Self.ext.makeCell()
        cell.identifier = extraCellIdentifier
        return cell
    }

    /// The size of a file; for a folder its calculated size, or what it is.
    private static func sizeText(of item: FileItem) -> String {
        if !item.isDirectory {
            return Format.bytes(item.size)
        }
        if let size = item.computedSize {
            return Format.bytes(size)
        }
        return item.isPackage ? "<PKG>" : item.isSymlink ? "<LNK>" : "<DIR>"
    }

    /// The column of the table, with its title, starting width and resizing.
    internal func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = 40
        column.resizingMask = self == .name ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        if self == .size {
            column.headerCell.alignment = .right
        }
        return column
    }

    /// The text of a row; `item` is nil for the `[..]` row. Names are shown with whatever
    /// could mislead made visible (`DisplayText`).
    internal func text(for item: FileItem?) -> String {
        guard let item else {
            return parentText
        }
        switch self {
        case .name:
            return DisplayText.clean(item.isFolder ? "[\(item.name)]" : item.baseName)

        case .ext:
            return DisplayText.clean(item.ext)

        case .size:
            return Self.sizeText(of: item)

        case .date:
            return Format.date(item.modified)

        case .attr:
            return Format.permissions(item.permissions)
        }
    }

    /// Makes a cell show its row as `look` says (its entry, the colour of its text and whether
    /// a file may be asked for its own icon). Only what differs from what the cell shows is set, so
    /// filling a cell that is up to date costs a few comparisons and no drawing. An empty cell
    /// (as most of the `[..]` row's are) is no element of its own to the accessibility
    /// interface: it says nothing.
    internal func fill(_ cell: NSTableCellView, with look: RowLook) {
        let item = look.item
        if let field = cell.textField {
            let text = text(for: item)
            if field.stringValue != text {
                field.stringValue = text
            }
            if field.textColor != look.color {
                field.textColor = look.color
            }
            if field.isAccessibilityElement() == text.isEmpty {
                field.setAccessibilityElement(!text.isEmpty)
            }
        }
        guard self == .name, let imageView = cell.imageView else {
            return
        }
        let icon = item.map { Self.icon(for: $0, own: look.ownIcons) } ?? Self.parentIcon
        if imageView.image !== icon {
            imageView.image = icon
        }
        let alpha: CGFloat = item?.isHidden == true ? 0.5 : 1
        if imageView.alphaValue != alpha {
            imageView.alphaValue = alpha
        }
    }

    /// A cell is a label, and for the name an icon in front of it, placed by their frames: the
    /// table makes and moves many cells while it scrolls, and layout constraints for each of
    /// them were most of what that cost. The label is called by its column's title.
    internal func makeCell() -> NSTableCellView {
        let size = NSSize(width: 120, height: 20)
        let cell = NSTableCellView(frame: NSRect(origin: .zero, size: size))
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = self == .name ? .byTruncatingMiddle : .byTruncatingTail
        label.font =
            self == .name || self == .ext ? .systemFont(ofSize: 12) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.alignment = self == .size ? .right : .left
        label.setAccessibilityLabel(title)
        var leading: CGFloat = 0
        if self == .name {
            let icon = NSImageView(frame: NSRect(x: 2, y: (size.height - 16) / 2, width: 16, height: 16))
            icon.imageScaling = .scaleProportionallyUpOrDown
            // Stays at the left edge, in the middle of the row's height.
            icon.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            cell.addSubview(icon)
            cell.imageView = icon
            leading = 2 + 16 + 5
        }
        let height = min(size.height, max(14, ceil(label.intrinsicContentSize.height)))
        label.frame = NSRect(
            x: leading,
            y: ((size.height - height) / 2).rounded(),
            width: size.width - leading,
            height: height
        )
        // As wide as the cell from where it starts, in the middle of the row's height.
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(label)
        cell.textField = label
        return cell
    }
}
