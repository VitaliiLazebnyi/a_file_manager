import AppKit

/// Lays its items out in a row and wraps them into further rows when they do not fit.
///
/// As the button bars do (spec 02 › Horizontal button bar: "the bar wraps into further rows").
/// The items keep the size they come with; the view takes the height its rows need. An item in
/// `lineBreaks` always starts a new row. Main thread only.
internal final class FlowView: NSView {
    /// The room between two items and two rows.
    private let spacing: CGFloat = 2
    /// The room around the rows.
    private let inset: CGFloat = 4
    /// The width the items were last laid out for.
    private var layoutWidth: CGFloat = 0

    /// Indices of the items that start a row of their own.
    internal var lineBreaks: Set<Int> = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Empty room below the last row (a place to drop something in a new row).
    internal var extraHeight: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// The views laid out, in order.
    internal var items: [NSView] = [] {
        didSet {
            for item in oldValue {
                item.removeFromSuperview()
            }
            for item in items {
                addSubview(item)
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Rows run from the top down.
    override internal var isFlipped: Bool { true }

    /// As high as the rows need for the present width; as wide as it is made.
    override internal var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrangement(forWidth: bounds.width).height)
    }

    /// An empty view of `frame`, which keeps the height of its rows.
    override internal init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    /// Not used: the view is made in code.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// Where each item goes in a bar of the given width, and the height that takes.
    ///
    /// A width of zero (not laid out yet) means one row.
    internal func arrangement(forWidth width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        var frames: [NSRect] = []
        var origin = NSPoint(x: inset, y: inset)
        var rowHeight: CGFloat = 0
        for (index, item) in items.enumerated() {
            let size = item.frame.size
            if origin.x > inset, lineBreaks.contains(index) || (width > 0 && origin.x + size.width + inset > width) {
                origin = NSPoint(x: inset, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(NSRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, items.isEmpty ? 0 : origin.y + rowHeight + inset + extraHeight)
    }

    /// Puts each item where `arrangement` says, and asks for a new height when the width changed.
    override internal func layout() {
        super.layout()
        let arrangement = arrangement(forWidth: bounds.width)
        for (item, frame) in zip(items, arrangement.frames) where item.frame != frame {
            item.frame = frame
        }
        if layoutWidth != bounds.width {
            layoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
