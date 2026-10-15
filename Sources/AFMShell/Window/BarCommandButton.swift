import AppKit

/// A button of the button bar.
///
/// It draws its own frame, a rounded square over the whole button (the system's bezels keep a
/// fixed height, a strip lower than a large picture): grey under the mouse, darker while
/// pressed, in the accent colour while its command is on. A ⌘-press is handed to the bar, which
/// may start a drag, instead of pressing the button. Main thread only.
internal final class BarCommandButton: NSButton {
    /// Takes a press with ⌘ instead of the button; nil leaves it to the button.
    internal var onCommandMouseDown: ((NSEvent) -> Void)?
    /// The area that tells of the mouse coming and going.
    ///
    /// Only this one is replaced: the others belong to AppKit (the tool tip's among them).
    private var hoverArea: NSTrackingArea?

    /// The picture turns white on the accent colour while the command is on.
    override internal var state: NSControl.StateValue {
        didSet { contentTintColor = state == .on ? .white : nil }
    }

    /// True while the mouse is over the button.
    internal private(set) var isMouseInside = false {
        didSet {
            if isMouseInside != oldValue {
                needsDisplay = true
            }
        }
    }

    /// A press with ⌘ goes to the bar; any other to the button.
    override internal func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandMouseDown else {
            super.mouseDown(with: event)
            return
        }
        onCommandMouseDown(event)
    }

    /// Follows the mouse over the visible part of the button.
    override internal func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
        if let window {
            isMouseInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    /// The mouse came over the button.
    override internal func mouseEntered(with _: NSEvent) {
        isMouseInside = true
    }

    /// The mouse left the button.
    override internal func mouseExited(with _: NSEvent) {
        isMouseInside = false
    }

    /// The frame for the state and the mouse, then the button's picture or title.
    override internal func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if state == .on {
            fill = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? (isHighlighted ? 0.8 : 1) : 0.4)
        } else if isEnabled, isHighlighted {
            fill = NSColor.labelColor.withAlphaComponent(0.2)
        } else if isEnabled, isMouseInside {
            fill = NSColor.labelColor.withAlphaComponent(0.1)
        } else {
            fill = nil
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
