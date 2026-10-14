import AppKit

/// Lays its items out in a row and wraps them into further rows when they do not fit, as the
/// button bars do (spec 02 › Horizontal button bar: "the bar wraps into further rows"). The
/// items keep the size they come with; the view takes the height its rows need. An item in
/// `lineBreaks` always starts a new row.
final class FlowView: NSView {
    private let spacing: CGFloat = 2
    private let inset: CGFloat = 4
    private var layoutWidth: CGFloat = 0

    /// Indices of the items that start a row of their own.
    var lineBreaks: Set<Int> = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Empty room below the last row (a place to drop something in a new row).
    var extraHeight: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    var items: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            items.forEach(addSubview)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder _: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Where each item goes in a bar of the given width, and the height that takes. A width
    /// of zero (not laid out yet) means one row.
    func arrangement(forWidth width: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        var frames: [NSRect] = []
        var x = inset
        var y = inset
        var rowHeight: CGFloat = 0
        for (index, item) in items.enumerated() {
            let size = item.frame.size
            if x > inset, lineBreaks.contains(index) || (width > 0 && x + size.width + inset > width) {
                x = inset
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(NSRect(origin: NSPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, items.isEmpty ? 0 : y + rowHeight + inset + extraHeight)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrangement(forWidth: bounds.width).height)
    }

    override func layout() {
        super.layout()
        let arrangement = arrangement(forWidth: bounds.width)
        for (item, frame) in zip(items, arrangement.frames) where item.frame != frame { item.frame = frame }
        if layoutWidth != bounds.width {
            layoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
