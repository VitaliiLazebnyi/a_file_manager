import AFMKernel
import AppKit

/// The file list of the Full view.
///
/// The table's single selected row is the cursor; marked items are kept in the panel model. Keys,
/// clicks and the context menu go to the panel, which treats them as it does those of the other
/// views; Cut, Copy and Paste go up the responder chain to the panel as well.
internal final class FileTableView: NSTableView {
    /// The panel the list belongs to.
    internal weak var panel: PanelViewController?

    /// Keys that are bound to commands go to the commands.
    ///
    /// A key that types something and is bound to nothing finds a file by the start of its name,
    /// which is the panel's doing (`typeToFind`) and not the table's own.
    override internal func keyDown(with event: NSEvent) {
        guard let panel, panel.handleListKey(event, arrowsMoveCursor: false) else {
            super.keyDown(with: event)
            return
        }
    }

    /// What was read of another program's drag is let go of when the drag has left.
    override internal func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        PanelDrop.dragLeft(sender)
    }

    /// What was read of a drag is let go of when the drag is over.
    override internal func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        PanelDrop.endSession(sender.draggingSequenceNumber)
    }

    /// The list takes the keyboard: its panel becomes the source.
    override internal func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            panel?.didBecomeFirstResponder()
        }
        return accepted
    }

    /// A click marks with Cmd or Shift (the panel's doing), otherwise moves the cursor as the
    /// table does; a second, unhurried click on the cursor's row starts renaming.
    override internal func mouseDown(with event: NSEvent) {
        let wasFocused = window?.firstResponder === self
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let renames = row >= 0 && panel?.isRenameClick(row: row, event: event, wasFocused: wasFocused) == true
        if row >= 0, panel?.handleClick(row: row, modifiers: event.modifierFlags) == true {
            return
        }
        // Returns when the button is released, also after a drag.
        super.mouseDown(with: event)
        guard renames, let window else {
            return
        }
        let released = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if abs(released.x - point.x) <= 4, abs(released.y - point.y) <= 4 {
            panel?.scheduleRename(row: row, after: NSEvent.doubleClickInterval)
        }
    }

    /// The context menu of the row under the mouse.
    override internal func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return panel?.contextMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    /// Cmd+A arrives as the standard editing action: the panel's Select All command.
    override internal func selectAll(_: Any?) {
        panel?.perform(.selectAll)
    }

    /// A command's menu item can be chosen while its command can run; other items as the table says.
    override internal func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let id = PanelViewController.command(of: item) else {
            return super.validateUserInterfaceItem(item)
        }
        return panel?.commands.isEnabled(id) ?? false
    }

    deinit {
        // Nothing to release.
    }
}
