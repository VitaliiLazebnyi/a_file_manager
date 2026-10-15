import AppKit

/// How the progress window comes on screen and goes.
///
/// AppKit's calls; a test puts its own in their place, so that nothing comes on the screen it
/// runs on. Main thread only.
@MainActor
internal struct ProgressScreen {
    /// Whether the main window is on screen, so that the progress window can be shown with it.
    internal var isShown: (NSWindow) -> Bool = \.isVisible
    /// Puts the panel on the main window as a sheet.
    internal var beginSheet: (NSPanel, NSWindow) -> Void = { $1.beginSheet($0) }
    /// Takes the sheet off the main window.
    internal var endSheet: (NSPanel, NSWindow) -> Void = { $1.endSheet($0) }
    /// Puts the panel on screen by itself and leaves the keyboard with the main window.
    internal var orderFront: (NSPanel, NSWindow) -> Void = { panel, window in
        panel.orderFront(nil)
        window.makeKey()
    }
    /// Takes the panel of its own off the screen.
    internal var orderOut: (NSPanel) -> Void = { $0.orderOut(nil) }
}
