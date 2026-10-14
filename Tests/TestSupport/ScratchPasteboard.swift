public import AppKit

/// A pasteboard of a test's own, given back to the pasteboard server when the test ends. A
/// pasteboard made with `NSPasteboard.withUniqueName()` stays in memory until it is released
/// with `releaseGlobally`, whoever still holds it.
public final class ScratchPasteboard {
    /// The pasteboard, for the plugins under test.
    public let pasteboard: NSPasteboard

    /// Makes a pasteboard with a name nobody else uses.
    public init() {
        pasteboard = NSPasteboard.withUniqueName()
    }

    deinit { pasteboard.releaseGlobally() }
}
