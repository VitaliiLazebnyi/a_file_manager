import AppKit

/// Events as the window server delivers them, made for the tests.
internal enum CoverageViewerEvents {
    /// The errors of making an event.
    internal enum Failure: Error {
        /// The event could not be made.
        case notMade
    }

    /// A turn of the scroll wheel by `lines` rows (positive: up), with `flags`.
    internal static func scroll(lines: Int32, flags: CGEventFlags) throws -> NSEvent {
        try wheel(lines, 0, flags: flags, units: .line)
    }

    /// A trackpad's precise scroll of `vertical` and `horizontal` points.
    internal static func preciseScroll(vertical: Int32, horizontal: Int32) throws -> NSEvent {
        try wheel(vertical, horizontal, flags: [], units: .pixel)
    }

    /// A pinch on the trackpad that magnifies by `amount` (0.5 is half as big again).
    internal static func magnify(_ amount: Double) throws -> NSEvent {
        guard let event = CGEvent(source: nil), let gesture = CGEventType(rawValue: 29),
            let kind = CGEventField(rawValue: 110), let value = CGEventField(rawValue: 113)
        else {
            throw Failure.notMade
        }
        event.type = gesture
        // A gesture of the zoom kind, and its amount.
        event.setIntegerValueField(kind, value: 8)
        event.setDoubleValueField(value, value: amount)
        guard let made = NSEvent(cgEvent: event), made.type == .magnify else {
            throw Failure.notMade
        }
        return made
    }

    private static func wheel(_ vertical: Int32, _ horizontal: Int32, flags: CGEventFlags, units: CGScrollEventUnit)
        throws -> NSEvent
    {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: units,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0
            )
        else {
            throw Failure.notMade
        }
        event.flags = flags
        guard let made = NSEvent(cgEvent: event) else {
            throw Failure.notMade
        }
        return made
    }
}
