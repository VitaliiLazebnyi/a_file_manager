import AFMKernel
import AppKit

/// The header of the Brief and Thumbnails views: the sort keys as buttons, and nothing else
/// (spec 03 › The header).
internal final class SortHeaderView: NSView {
    /// The columns that have a button, in their order.
    internal static let columns: [FileListColumn] = [.name, .ext, .size, .date]
    private static let buttonWidth: CGFloat = 76

    /// Called with the column whose button was clicked.
    internal var onClick: ((FileListColumn) -> Void)?
    /// The menu of the header.
    internal var menuProvider: (() -> NSMenu?)?
    /// The order of the list, whose key is shown with an arrow.
    internal var order = ListOrder() {
        didSet { needsDisplay = true }
    }

    /// Drawn from the top down.
    override internal var isFlipped: Bool { true }
    /// As high as a header, as wide as it is made.
    override internal var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }

    /// The buttons, the one of the sort key with its direction.
    override internal func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (index, column) in Self.columns.enumerated() {
            let frame = frame(of: index)
            NSRect(x: frame.maxX - 1, y: 4, width: 1, height: frame.height - 8).fill()
            let isSortKey = column.sortKey == order.key
            let title = (isSortKey ? (order.descending ? "↓" : "↑") : "") + column.title
            NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: isSortKey ? .semibold : .regular),
                    .foregroundColor: NSColor.headerTextColor
                ]
            )
            .draw(at: NSPoint(x: frame.minX + 8, y: 4))
        }
    }

    /// A click on a button: `onClick` hears which.
    override internal func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = Self.columns.indices.first(where: { frame(of: $0).contains(point) }) {
            onClick?(Self.columns[index])
        }
    }

    /// The menu of the header.
    override internal func menu(for _: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    /// Where the button at `index` is.
    private func frame(of index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * Self.buttonWidth, y: 0, width: Self.buttonWidth, height: bounds.height)
    }
}
