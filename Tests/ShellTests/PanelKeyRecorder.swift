import AppKit

/// Stands after a list in the responder chain and keeps the keys and commands the list passes
/// on, so none of them reaches the window, which would beep.
@MainActor
internal final class PanelKeyRecorder: NSResponder {
    /// The key codes of the keys that were passed on.
    internal private(set) var keys: [UInt16] = []
    /// The commands that were passed on.
    internal private(set) var commands: [Selector] = []

    /// A key passed on.
    override internal func keyDown(with event: NSEvent) {
        keys.append(event.keyCode)
    }

    /// A command passed on.
    override internal func doCommand(by selector: Selector) {
        commands.append(selector)
    }

    /// Nobody took the command: nothing happens.
    override internal func noResponder(for eventSelector: Selector) {
        commands.append(eventSelector)
    }

    deinit {
        // Nothing to release.
    }
}
