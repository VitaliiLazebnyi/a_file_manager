public import AFMKernel
public import AppKit

/// The key bindings asked with the Mac's key events.
extension KeyBindings {
    /// The command a key press is bound to.
    ///
    /// For the file list and for plugin windows that want to answer to the same keys; nil for a
    /// key no command has.
    public func command(for event: NSEvent) -> CommandID? {
        Shortcut.candidates(for: event).lazy.compactMap { self.command(for: $0) }.first
    }

    /// The key shown next to a command in a menu: its first shortcut a menu may own.
    internal func menuShortcut(for command: CommandID) -> Shortcut? {
        shortcuts(for: command).first(where: \.isMenuSafe)
    }
}
