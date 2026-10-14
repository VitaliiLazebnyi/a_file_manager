import AFMContracts
import AFMKernel
import AppKit

/// The file list. The table's single selected row is the cursor; marked items are kept in the panel model.
final class FileTableView: NSTableView {
    weak var panel: PanelViewController?

    /// Keys that are bound to commands go to the commands. A key that types something and is
    /// bound to nothing finds a file by the start of its name, which is the panel's doing
    /// (`typeToFind`) and not the table's own.
    override func keyDown(with event: NSEvent) {
        guard let panel else {
            super.keyDown(with: event)
            return
        }
        if panel.handleKey(event) { return }
        if event.modifierFlags.isDisjoint(with: [.command, .control]), let typed = FileGridView.typedText(of: event) {
            panel.typeToFind(typed, at: event.timestamp)
            return
        }
        super.keyDown(with: event)
    }

    // What was read of a drag is let go of when the drag is over or has left.

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        if PanelDrop.current == nil { PanelDrop.endSession(sender?.draggingSequenceNumber) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        PanelDrop.endSession(sender.draggingSequenceNumber)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { panel?.didBecomeFirstResponder() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let wasFocused = window?.firstResponder === self
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let renames = row >= 0 && panel?.isRenameClick(row: row, event: event, wasFocused: wasFocused) == true
        if row >= 0, panel?.handleClick(row: row, modifiers: event.modifierFlags) == true { return }
        // Returns when the button is released, also after a drag.
        super.mouseDown(with: event)
        guard renames, let window else { return }
        let released = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if abs(released.x - point.x) <= 4, abs(released.y - point.y) <= 4 { panel?.scheduleRename(row: row) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return panel?.contextMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    // Cmd+A, Cmd+C, Cmd+X and Cmd+V arrive as the standard editing actions (see `EditingRole`).

    override func selectAll(_: Any?) { panel?.perform(.selectAll) }
    @objc func copy(_: Any?) { panel?.perform(.copy) }
    @objc func cut(_: Any?) { panel?.perform(.cut) }
    @objc func paste(_: Any?) { panel?.perform(.paste) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let menuItem = item as? NSMenuItem, let id = MenuBuilder.command(of: menuItem) {
            return panel?.commands.isEnabled(id) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Draws the cursor bar: a light bar with a darker border, in the active panel only
/// (spec 03 › Cursor, selection and row states).
final class CursorRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("afm.row")
    weak var panel: PanelViewController?

    override func drawSelection(in _: NSRect) {
        guard panel?.isActive == true else { return }
        CursorBar.draw(in: bounds)
    }

    // Keeps the text in its own colour on the cursor bar.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
