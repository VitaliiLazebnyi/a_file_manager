import AFMKernel
import AFMShell
import AppKit

/// Editing and the keys of the panes: copying lines across, Undo, Save, Resync, Swap and the clipboard.
extension CompareWindowController {
    /// Copies the difference or the selected lines to the right (Option+Right).
    @objc
    internal func copyToRight() {
        if let rows = rowsToCopy {
            session.copy(rows: rows, to: .right)
        }
    }

    /// Copies the difference or the selected lines to the left (Option+Left).
    @objc
    internal func copyToLeft() {
        if let rows = rowsToCopy {
            session.copy(rows: rows, to: .left)
        }
    }

    /// Takes the last edit back.
    @objc
    internal func undoEdit() {
        session.undo()
    }

    /// Saves the edited files.
    @objc
    internal func save() {
        session.save()
    }

    /// A cell's text was edited: the line of its row takes it.
    @objc
    internal func cellEdited(_ sender: NSTextField) {
        for (table, side) in [(leftTable, CompareSide.left), (rightTable, .right)] {
            let row = table.row(for: sender)
            if row >= 0 {
                session.setText(sender.stringValue, side, row: row)
            }
        }
    }

    /// Marks the cursor's line in the focused pane; with a line marked on each side, the two are resynchronized.
    @objc
    internal func markResync() {
        let row = currentRow
        if focusedSide == .left {
            resyncMarks.left = row
        } else {
            resyncMarks.right = row
        }
        if let left = resyncMarks.left, let right = resyncMarks.right {
            resyncMarks = (nil, nil)
            session.resync(leftRow: left, rightRow: right)
        } else {
            statusLabel.stringValue =
                "Line marked on the \(focusedSide == .left ? "left" : "right"). "
                + "Now select the line that belongs to it in the other pane and choose Resync again."
        }
    }

    /// Forgets the marks and every resynchronized pair of lines.
    @objc
    internal func clearResync() {
        resyncMarks = (nil, nil)
        session.clearResync()
    }

    /// Swaps the two files (Ctrl+U).
    @objc
    internal func swapSides() {
        session.swap()
        pullControls()
    }

    /// Puts the selected lines of the focused pane on the clipboard, one per line.
    @objc
    internal func copySelection() {
        let side = focusedSide
        let lines = leftTable.selectedRowIndexes.compactMap { row in session.text(side, row: row) }
        effects.pasteboard.clearContents()
        effects.pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Turns edit mode on or off (F6).
    private func toggleEditing() {
        session.setEditing(!session.isEditing)
        pullControls()
    }

    /// The keys of the panes (spec 09 › Compare by content › Keys); false for a key that is not one of them.
    internal func handleKey(_ event: NSEvent) -> Bool {
        func key(_ character: String, _ modifiers: KeyModifiers) -> Bool {
            Shortcut(.character(character), modifiers).matches(event)
        }
        func shortcut(_ shortcut: Shortcut) -> Bool {
            shortcut.matches(event)
        }
        let editing = session.isEditing
        let keys: [(matches: Bool, run: () -> Void)] = [
            (shortcut(Shortcut(.downArrow, .option)), nextDifference),
            (shortcut(Shortcut(.upArrow, .option)), previousDifference),
            (shortcut(.f(6)), toggleEditing),
            (shortcut(.f(3)), { [self] in search(forward: true) }),
            (shortcut(.f(3, .shift)), { [self] in search(forward: false) }),
            (
                key("f", .control) || key("f", .command) || shortcut(.f(7)),
                { [self] in window?.makeFirstResponder(searchField) }
            ),
            (key("s", .control) || key("s", .command), save),
            (key("z", .control) || key("z", .command) || shortcut(Shortcut(.backspace, .option)), undoEdit),
            (key("u", .control), swapSides),
            (key("c", .command) || key("c", .control), copySelection),
            (editing && shortcut(Shortcut(.rightArrow, .option)), copyToRight),
            (editing && shortcut(Shortcut(.leftArrow, .option)), copyToLeft)
        ]
        guard let found = keys.first(where: \.matches) else {
            return false
        }
        found.run()
        return true
    }
}
