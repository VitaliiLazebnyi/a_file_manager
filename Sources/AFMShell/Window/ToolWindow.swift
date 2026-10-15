import AFMKernel
public import AppKit

/// A secondary window for plugins (viewer, Find Files): Esc and Cmd+W close it.
///
/// Main thread only, like every window.
open class ToolWindow: NSWindow {
    /// Called for Esc before the window closes; return true when Esc was used up.
    public var onEscape: (() -> Bool)?

    /// Esc: the plugin's `onEscape` first, then the window closes.
    override open func cancelOperation(_ sender: Any?) {
        if onEscape?() == true {
            return
        }
        performClose(sender)
    }

    /// Cmd+W closes the window; other keys go their usual way.
    override open func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Shortcut.cmd("w").matches(event) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    deinit {
        // Nothing to release.
    }
}
