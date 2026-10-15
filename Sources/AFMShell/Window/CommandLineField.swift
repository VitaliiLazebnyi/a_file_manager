import AppKit

/// The combo box of the command line.
///
/// While it is being typed in, its own keys come before the menu's: Ctrl+W deletes a word here
/// and closes a folder tab only in a panel (spec 02 › Keys in the command line). Main thread
/// only.
internal final class CommandLineField: NSComboBox {
    /// Gets the keys while the field is typed in; returns true when the key was used up.
    internal var onKey: ((NSEvent) -> Bool)?

    /// A key goes to `onKey` first while the field is typed in, then to the menus.
    override internal func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, currentEditor() != nil, onKey?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
