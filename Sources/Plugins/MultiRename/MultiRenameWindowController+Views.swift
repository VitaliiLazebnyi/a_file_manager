import AFMShell
import AppKit

/// The window and the list of the tool, which hand their keys to it first.
extension MultiRenameWindowController {
    /// A window that offers its keys to the tool before the focused field sees them: F2, F5
    /// and F10 work wherever the cursor is.
    internal final class Window: ToolWindow {
        /// Answers a key; true when it was used.
        internal var onKeyDown: ((NSEvent) -> Bool)?

        /// A key the tool does not use goes on as usual.
        override internal func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, onKeyDown?(event) == true {
                return
            }
            super.sendEvent(event)
        }
    }

    /// The list of the items, which hands its keys to the tool first.
    internal final class ListView: NSTableView {
        /// Answers a key; true when it was used.
        internal var onKey: ((NSEvent) -> Bool)?

        /// A key the tool does not use goes to the table as usual.
        override internal func keyDown(with event: NSEvent) {
            if onKey?(event) != true {
                super.keyDown(with: event)
            }
        }
    }

    /// A column of the list.
    internal struct Column {
        /// Its identifier.
        internal var identifier: String
        /// Its title.
        internal var title: String
        /// Its width at the start.
        internal var width: CGFloat
    }

    /// An entry of one of the pull-down menus: its caption, what it stands for, whether it can be chosen.
    ///
    /// An empty caption is a separator.
    internal struct MenuEntry {
        /// The caption.
        internal var caption: String
        /// What the entry stands for (`representedObject`).
        internal var tag: String
        /// Whether it can be chosen.
        internal var isEnabled: Bool
    }
}
