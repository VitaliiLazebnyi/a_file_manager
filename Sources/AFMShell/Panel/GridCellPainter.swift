import AFMKernel
import AppKit

/// How the cells of the Brief and Thumbnails views are measured and drawn: a Brief cell is an
/// icon and a name in a line, a tile a picture (or the icon) with the name below
/// (spec 03 › Brief, 03 › Thumbnails).
@MainActor
internal enum GridCellPainter {
    /// The height of a Brief cell.
    internal static let briefRowHeight: CGFloat = 20
    /// The font of the names in Brief.
    internal static let nameFont = NSFont.systemFont(ofSize: 12)
    /// The font of the names below the tiles.
    internal static let captionFont = NSFont.systemFont(ofSize: 11)

    private static let briefStyle = paragraph(.left)
    private static let captionStyle = paragraph(.center)

    /// The name as the lists write it: folders in brackets (spec 03 › Names, extensions and folders).
    internal static func caption(for item: FileItem?) -> String {
        guard let item else {
            return "[..]"
        }
        return DisplayText.clean(item.isFolder ? "[\(item.name)]" : item.name)
    }

    /// The width of the widest of the longest names of the list, as drawn.
    ///
    /// Measuring text is slow, so only the names with the most characters are measured; finding
    /// those is one quick pass over the list.
    internal static func widestBriefName(in items: [FileItem]) -> CGFloat {
        var longest: [(length: Int, name: String)] = []
        var shortestKept = 0
        for item in items {
            let length = item.name.utf16.count
            guard longest.count < 6 || length > shortestKept else {
                continue
            }
            // Kept longest first: the last is the shortest kept.
            longest.append((length, item.name))
            longest.sort { $0.length > $1.length }
            if longest.count > 6 {
                longest.removeLast()
            }
            shortestKept = longest[longest.count - 1].length
        }
        return
            longest.map { NSAttributedString(string: "[" + $0.name + "]", attributes: [.font: nameFont]).size().width }
            .max() ?? 0
    }

    /// A Brief column is as wide as the longest name (`widest`), up to `limit` and the width
    /// of the panel (spec 03 › Brief).
    internal static func briefColumnWidth(widest: CGFloat, limit: CGFloat?, viewport: CGFloat) -> CGFloat {
        // The icon, the gaps around it and a little air to the next column.
        let wanted = ceil(widest) + 16 + 20
        let most = max(80, min(limit ?? .greatestFiniteMagnitude, viewport > 0 ? viewport : .greatestFiniteMagnitude))
        return min(max(wanted, 80), most)
    }

    /// A Brief cell: the icon, and the name beside it.
    internal static func drawBriefCell(_ cell: RowLook, in frame: NSRect) {
        icon(of: cell)?
            .draw(
                in: NSRect(x: frame.minX + 3, y: frame.midY - 8, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: cell.item?.isHidden == true ? 0.5 : 1,
                respectFlipped: true,
                hints: nil
            )
        drawName(
            of: cell,
            in: NSRect(x: frame.minX + 24, y: frame.minY + 2, width: frame.width - 30, height: frame.height - 4),
            font: nameFont,
            style: briefStyle
        )
    }

    /// A tile `side` points square: `picture` (the file's own, when there is one), or the icon,
    /// and the name below (spec 03 › Thumbnails).
    internal static func drawTile(_ cell: RowLook, in frame: NSRect, side: CGFloat, picture: NSImage?) {
        let box = NSRect(x: frame.midX - side / 2, y: frame.minY + 4, width: side, height: side)
        if let picture {
            let scale = min(side / max(picture.size.width, 1), side / max(picture.size.height, 1), 1)
            let size = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
            picture.draw(
                in: NSRect(
                    x: box.midX - size.width / 2,
                    y: box.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        } else {
            let iconSide = min(side, max(32, side / 2))
            icon(of: cell)?
                .draw(
                    in: NSRect(
                        x: box.midX - iconSide / 2,
                        y: box.midY - iconSide / 2,
                        width: iconSide,
                        height: iconSide
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: cell.item?.isHidden == true ? 0.5 : 1,
                    respectFlipped: true,
                    hints: nil
                )
        }
        drawName(
            of: cell,
            in: NSRect(x: frame.minX + 3, y: box.maxY + 4, width: frame.width - 6, height: 16),
            font: captionFont,
            style: captionStyle
        )
    }

    /// The icon of a cell's entry; the parent icon for `[..]`.
    private static func icon(of cell: RowLook) -> NSImage? {
        cell.item.map { FileListColumn.icon(for: $0, own: cell.ownIcons) } ?? FileListColumn.parentIcon
    }

    /// The caption of a cell, cut in the middle where it is too long for `rect`.
    private static func drawName(of cell: RowLook, in rect: NSRect, font: NSFont, style: NSParagraphStyle) {
        NSAttributedString(
            string: caption(for: cell.item),
            attributes: [.font: font, .foregroundColor: cell.color, .paragraphStyle: style]
        )
        .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A paragraph with this alignment that cuts long text in the middle.
    private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }
}
