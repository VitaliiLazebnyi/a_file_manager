import AppKit

/// Whoever answers the menu items of commands along the responder chain: the main window.
@MainActor
@objc
internal protocol CommandResponder {
    /// Runs the command of `sender` (`MenuBuilder.command(of:)`).
    func performCommand(_ sender: NSMenuItem)
}
