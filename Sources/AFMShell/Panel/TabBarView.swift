import AppKit

/// The folder-tab strip above the path bar. Hidden while the panel has a single tab
/// (spec 03 › Tab header appearance). A click shows a tab, a double or middle click closes
/// it, a right click opens its menu, and a tab can be dragged to another place in the strip
/// (spec 03 › Renaming and rearranging).
final class TabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// A tab was dragged to another position.
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    /// A double or middle click on the free space of the strip.
    var onNewTab: (() -> Void)?
    /// The menu of a tab.
    var menuProvider: ((Int) -> NSMenu?)?
    private let stack = NSStackView()
    private let marker = NSView()

    private final class TabButton: NSButton {
        weak var bar: TabBarView?

        /// The button follows the mouse itself, so that a press can turn into a drag.
        override func mouseDown(with event: NSEvent) {
            guard let bar else { return super.mouseDown(with: event) }
            if event.clickCount == 2 { return bar.onClose?(tag) ?? () }
            let start = event.locationInWindow
            var isDragging = false
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                let x = bar.convert(next.locationInWindow, from: nil).x
                if next.type == .leftMouseUp {
                    bar.showMarker(at: nil)
                    if isDragging {
                        let destination = TabBarView.destination(forX: x, dragging: tag, frames: bar.tabFrames)
                        if destination != tag { bar.onMove?(tag, destination) }
                    } else {
                        bar.onSelect?(tag)
                    }
                    return
                }
                if abs(next.locationInWindow.x - start.x) > 5 { isDragging = true }
                if isDragging { bar.showMarker(at: TabBarView.destination(forX: x, dragging: tag, frames: bar.tabFrames), dragging: tag) }
            }
        }

        override func otherMouseDown(with event: NSEvent) { bar?.onClose?(tag) }

        override func menu(for event: NSEvent) -> NSMenu? { bar?.menuProvider?(tag) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        marker.isHidden = true
        addSubview(marker)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The captions of the tabs, for checks.
    var titles: [String] { stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    func update(titles: [String], paths: [String], active: Int) {
        isHidden = titles.count < 2
        // The tabs that are there are changed in place, so a tab that is being dragged stays.
        if stack.arrangedSubviews.count == titles.count {
            for (index, view) in stack.arrangedSubviews.enumerated() {
                guard let button = view as? TabButton else { continue }
                if button.title != titles[index] { button.title = titles[index] }
                let state: NSControl.StateValue = index == active ? .on : .off
                if button.state != state { button.state = state }
                if button.toolTip != paths[index] { button.toolTip = paths[index] }
            }
            return
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            let button = TabButton(title: title, target: nil, action: nil)
            button.bar = self
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.state = index == active ? .on : .off
            button.tag = index
            button.toolTip = paths[index]
            button.refusesFirstResponder = true
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(button)
        }
    }

    /// Where the tabs are in the strip.
    private var tabFrames: [NSRect] {
        stack.arrangedSubviews.map { convert($0.bounds, from: $0) }
    }

    /// The position a dragged tab takes when it is let go at `x`: that of the tab whose middle
    /// it has passed, counted from where it came.
    static func destination(forX x: CGFloat, dragging index: Int, frames: [NSRect]) -> Int {
        guard frames.indices.contains(index) else { return index }
        var destination = index
        for other in frames.indices where other != index {
            if other < index, x < frames[other].midX { destination = min(destination, other) }
            if other > index, x > frames[other].midX { destination = max(destination, other) }
        }
        return destination
    }

    /// Shows where the dragged tab would land; nil takes the mark away.
    private func showMarker(at destination: Int?, dragging index: Int = 0) {
        let frames = tabFrames
        guard let destination, destination != index, frames.indices.contains(destination) else {
            marker.isHidden = true
            return
        }
        let x = destination < index ? frames[destination].minX - 2 : frames[destination].maxX
        marker.frame = NSRect(x: x, y: 2, width: 2, height: bounds.height - 4)
        marker.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onNewTab?() }
    }

    override func otherMouseDown(with event: NSEvent) { onNewTab?() }
}
