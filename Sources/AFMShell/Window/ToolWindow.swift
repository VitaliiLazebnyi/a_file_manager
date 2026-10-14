import AFMKernel
public import AppKit

/// A secondary window for plugins (viewer, Find Files): Esc and Cmd+W close it.
open class ToolWindow: NSWindow {
    /// Called for Esc before the window closes; return true when Esc was used up.
    public var onEscape: (() -> Bool)?

    override open func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        performClose(sender)
    }

    override open func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Shortcut.cmd("w").matches(event) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
