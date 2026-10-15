import AppKit

/// A window that is never put on screen and says it has a sheet open while `openSheet` is set: a
/// real sheet would show both windows.
internal final class CovViewSheetWindow: NSWindow {
    /// The sheet the window claims to have open.
    internal var openSheet: NSWindow?

    /// `openSheet`.
    override internal var attachedSheet: NSWindow? { openSheet }
}
