import AppKit

/// The cursor bar, the same in every view: a light bar with a darker border
/// (spec 03 › Cursor, selection and row states).
@MainActor
internal enum CursorBar {
    /// Draws the bar into `rect` of the view that is drawing.
    internal static func draw(in rect: NSRect) {
        let bar = rect.insetBy(dx: 0.5, dy: 0.5)
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        bar.fill()
        NSColor.selectedContentBackgroundColor.setStroke()
        NSBezierPath(rect: bar).stroke()
    }

    /// The frame around a folder the mouse drags files over (spec 05 › Drop targets).
    internal static func drawDropFrame(in rect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
