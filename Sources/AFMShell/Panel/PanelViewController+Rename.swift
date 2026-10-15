import AFMContracts
import AFMKernel
import AppKit

/// The in-place name editor (spec 07 › In-place rename): a box over the name of the cursor's
/// item, the same in every view; Enter runs the Rename command with what was typed.
extension PanelViewController {
    /// True while a name is being edited in place.
    internal var isRenaming: Bool { renameField != nil }

    /// Whether a click is a second, unhurried click on the item under the cursor, which starts
    /// renaming as in Finder. `wasFocused`: the list had the keyboard before the click, so a
    /// click that only brings the panel to the front renames nothing.
    internal func isRenameClick(row: Int, event: NSEvent, wasFocused: Bool) -> Bool {
        cancelPendingRename()
        return wasFocused && isActive && event.clickCount == 1 && !isRenaming && row == model.cursor
            && model.item(atRow: row) != nil
            && event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control])
    }

    /// Starts renaming after `delay` (the double-click time), once it is clear that the click
    /// was not the first half of a double click, unless the cursor has moved on by then.
    internal func scheduleRename(row: Int, after delay: TimeInterval) {
        let tab = model
        let name = tab.item(atRow: row)?.name
        // From the run loop (`MainLoop`), like everything that ends in a command.
        pendingRename = MainLoop.after(delay) { [weak self] in
            guard let self else {
                return
            }
            pendingRename = nil
            guard model === tab, tab.cursor == row, tab.cursorItem?.name == name, isActive else {
                return
            }
            // Refused wherever the Rename command is (a read-only file system, a running job).
            if commands.isEnabled(.renameOnly) {
                commands.perform(.editNameInPlace, .nothing)
            }
        }
    }

    /// Gives up a rename that waits for the double-click time.
    internal func cancelPendingRename() {
        pendingRename?()
        pendingRename = nil
    }

    /// Opens the editor over the name of the cursor's item, with the name selected.
    internal func beginRename() {
        guard renameField == nil, let item = model.cursorItem else {
            return
        }
        let row = model.cursor
        renamingRow = row
        renaming = PanelRenameTarget(
            tab: ObjectIdentifier(model),
            location: model.directory.locationKey,
            name: item.name
        )
        redrawName(ofRow: row)
        let field = NSTextField(string: item.name)
        if showsGrid {
            gridView.scrollRowToVisible(row)
        } else {
            tableView.scrollRowToVisible(row)
        }
        field.frame = renameFrame(ofRow: row)
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.focusRingType = .none
        field.setAccessibilityLabel("New name")
        // The box covers the name it replaces: opaque, and above the rows, which the list
        // draws again (and would otherwise draw over it) whenever the selection changes.
        field.isBezeled = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.wantsLayer = true
        field.layer?.zPosition = 100
        listView.addSubview(field)
        renameField = field
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Before the list is drawn again: the editor stays when its item is still in the list of the
    /// tab and folder it was opened in (the list was sorted, read again, got another volume
    /// figure), and follows the item to its row.
    ///
    /// It goes away, and what was typed with it, only when the item is gone or the panel shows
    /// something else.
    internal func keepRenameIfItemRemains() {
        guard renameField != nil, let renaming else {
            return
        }
        guard renaming.tab == ObjectIdentifier(model), renaming.location == model.directory.locationKey,
            let row = model.row(ofName: renaming.name)
        else {
            cancelRename(restoringKeyboard: true)
            return
        }
        renamingRow = row
    }

    /// After the list was drawn again: the box stands where its row is now.
    internal func placeRenameField() {
        guard let field = renameField, let row = renamingRow else {
            return
        }
        // A list that was taken anew has let go of the box with its other views.
        if field.superview !== listView {
            listView.addSubview(field)
        }
        let frame = renameFrame(ofRow: row)
        if field.frame != frame {
            field.frame = frame
        }
    }

    /// Enter in the box renames, Esc takes it away; other keys are the box's own.
    internal func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else {
            return false
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let newName = control.stringValue
            cancelRename(restoringKeyboard: false)
            focus()
            // The rename itself is the Rename command with the new name as its argument.
            commands.perform(.renameOnly, .text(newName))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename(restoringKeyboard: false)
            view.window?.makeFirstResponder(listView)
            return true
        }
        return false
    }

    /// A click outside the box cancels.
    internal func controlTextDidEndEditing(_: Notification) {
        cancelRename(restoringKeyboard: false)
    }

    /// Draws the name of `row` again, which the list leaves out while the box is there.
    private func redrawName(ofRow row: Int) {
        if showsGrid {
            gridView.setNeedsDisplay(gridView.bounds)
        } else if row < tableView.numberOfRows {
            tableView.reloadData(
                forRowIndexes: [row],
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }
    }

    /// Where the box for the name of a row stands in the list that is on screen.
    private func renameFrame(ofRow row: Int) -> NSRect {
        if showsGrid {
            return gridView.nameFrame(ofRow: row)
        }
        let frame = tableView.rect(ofRow: row)
            .intersection(tableView.rect(ofColumn: 0).union(tableView.rect(ofColumn: 1)))
        return frame.insetBy(dx: 20, dy: 0).offsetBy(dx: 10, dy: 0)
    }

    /// Takes the editor away. `restoringKeyboard`: the program does this, not the user, so the
    /// keyboard goes back to the list if the box had it (it would otherwise be left with the
    /// window, where keys only beep).
    private func cancelRename(restoringKeyboard: Bool) {
        guard let field = renameField else {
            return
        }
        let hadKeyboard = field.currentEditor().map { view.window?.firstResponder === $0 } ?? false
        renameField = nil
        renaming = nil
        field.removeFromSuperview()
        if let row = renamingRow {
            renamingRow = nil
            redrawName(ofRow: row)
        }
        // A change of the folder that was turned away while the box was open is picked up now,
        // after whatever ended the rename (the Rename command, say) has had its turn.
        if dirty[ObjectIdentifier(model)] != nil {
            MainLoop.perform { [weak self] in self?.rereadIfDirty() }
        }
        if restoringKeyboard, hadKeyboard {
            view.window?.makeFirstResponder(listView)
        }
    }
}
