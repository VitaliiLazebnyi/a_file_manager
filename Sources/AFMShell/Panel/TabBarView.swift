import AppKit

/// The folder-tab strip above the path bar.
///
/// Hidden while the panel has a single tab (spec 03 › Tab header appearance). A click shows a tab,
/// a double or middle click closes it, a right click opens its menu, and a tab can be dragged to
/// another place in the strip (spec 03 › Renaming and rearranging).
internal final class TabBarView: NSView {
    /// A tab was clicked, by its position.
    internal var onSelect: ((Int) -> Void)?
    /// A tab is to be closed, by its position.
    internal var onClose: ((Int) -> Void)?
    /// A tab was dragged from one position to another.
    internal var onMove: ((_ from: Int, _ destination: Int) -> Void)?
    /// A double or middle click on the free space of the strip.
    internal var onNewTab: (() -> Void)?
    /// The menu of a tab, by its position.
    internal var menuProvider: ((Int) -> NSMenu?)?
    /// The tabs, in their order.
    internal let stack = NSStackView()
    /// The mark that shows where a dragged tab would land.
    internal let marker = NSView()

    /// Where the tabs are in the strip.
    private var tabFrames: [NSRect] {
        stack.arrangedSubviews.map { convert($0.bounds, from: $0) }
    }

    /// An empty strip.
    override internal init(frame: NSRect) {
        super.init(frame: frame)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        marker.isHidden = true
        addSubview(marker)
        // The tabs start at the leading edge and take the height; the free space is to their right.
        NSLayoutConstraint.activate(
            [NSLayoutConstraint.Attribute.top, .bottom, .leading]
                .map { edge in
                    NSLayoutConstraint(
                        item: stack,
                        attribute: edge,
                        relatedBy: .equal,
                        toItem: self,
                        attribute: edge,
                        multiplier: 1,
                        constant: 0
                    )
                } + [stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)]
        )
    }

    /// Not made from an archive.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// The position a dragged tab takes when it is let go at `position`: that of the tab whose
    /// middle it has passed, counted from where it came.
    internal static func destination(forX position: CGFloat, dragging index: Int, frames: [NSRect]) -> Int {
        guard frames.indices.contains(index) else {
            return index
        }
        var destination = index
        for other in frames.indices where other != index {
            if other < index, position < frames[other].midX {
                destination = min(destination, other)
            }
            if other > index, position > frames[other].midX {
                destination = max(destination, other)
            }
        }
        return destination
    }

    /// Shows the tabs with these captions and tool tips, `active` pressed; hides the strip
    /// while there is one tab.
    internal func update(titles: [String], paths: [String], active: Int) {
        isHidden = titles.count < 2
        // The tabs that are there are changed in place, so a tab that is being dragged stays.
        if stack.arrangedSubviews.count == titles.count {
            // The strip holds tab buttons only.
            for (index, button) in stack.arrangedSubviews.compactMap({ $0 as? TabButton }).enumerated() {
                if button.title != titles[index] {
                    button.title = titles[index]
                }
                let state: NSControl.StateValue = index == active ? .on : .off
                if button.state != state {
                    button.state = state
                }
                if button.toolTip != paths[index] {
                    button.toolTip = paths[index]
                }
            }
            return
        }
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }
        for (index, title) in titles.enumerated() {
            stack.addArrangedSubview(makeTab(title, path: paths[index], index: index, isActive: index == active))
        }
    }

    /// Follows the mouse while the tab at `index` is pressed (it went down at `start` in the
    /// window): a press that moves is a drag, which shows where the tab would land.
    ///
    /// Returns true when the button was released; the tab is then shown, or moved where it was
    /// dragged.
    internal func follow(_ event: NSEvent, pressing index: Int, from start: CGFloat, dragging: inout Bool) -> Bool {
        let position = convert(event.locationInWindow, from: nil).x
        if event.type == .leftMouseUp {
            showMarker(at: nil, dragging: index)
            if !dragging {
                onSelect?(index)
                return true
            }
            let destination = Self.destination(forX: position, dragging: index, frames: tabFrames)
            if destination != index {
                onMove?(index, destination)
            }
            return true
        }
        if abs(event.locationInWindow.x - start) > 5 {
            dragging = true
        }
        if dragging {
            showMarker(at: Self.destination(forX: position, dragging: index, frames: tabFrames), dragging: index)
        }
        return false
    }

    /// A double click on the free space opens a new tab.
    override internal func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onNewTab?()
        }
    }

    /// A middle click on the free space opens a new tab.
    override internal func otherMouseDown(with _: NSEvent) {
        onNewTab?()
    }

    /// A tab button at position `index`.
    private func makeTab(_ title: String, path: String, index: Int, isActive: Bool) -> TabButton {
        let button = TabButton(title: title, target: nil, action: nil)
        button.bar = self
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
        button.state = isActive ? .on : .off
        button.tag = index
        button.toolTip = path
        button.refusesFirstResponder = true
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    /// Shows where the tab at `index`, dragged, would land; nil takes the mark away.
    private func showMarker(at destination: Int?, dragging index: Int) {
        let frames = tabFrames
        guard let destination, destination != index, frames.indices.contains(destination) else {
            marker.isHidden = true
            return
        }
        let position = destination < index ? frames[destination].minX - 2 : frames[destination].maxX
        marker.frame = NSRect(x: position, y: 2, width: 2, height: bounds.height - 4)
        marker.isHidden = false
    }
}
