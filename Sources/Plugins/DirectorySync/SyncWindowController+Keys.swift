import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// Keys: the keys of the result list (spec 09 › Keys and ini keys).
extension SyncWindowController {
    /// Handles a key of the result list; false for a key that is not one of them.
    internal func handleKey(_ event: NSEvent) -> Bool {
        let keys = rowKeys(event) + windowKeys(event)
        guard let found = keys.first(where: \.matches) else {
            return false
        }
        found.run()
        return true
    }

    /// The keys that act on the selected rows.
    ///
    /// Only the key pressed takes the selection: a million selected rows are not mapped for every key.
    private func rowKeys(_ event: NSEvent) -> [(matches: Bool, run: () -> Void)] {
        func key(_ character: String) -> Bool {
            Shortcut(.character(character), .control).matches(event)
        }
        func first(_ open: @escaping (Int) -> Void) -> () -> Void {
            { [self] in
                if let row = selectedRows.first {
                    open(row)
                }
            }
        }
        return [
            (
                Shortcut(.space).matches(event) || Shortcut(.space, .shift).matches(event),
                { [self] in session.toggle(rows: selectedRows) }
            ),
            (key("d"), { [self] in session.markDefault(rows: selectedRows) }),
            (key("m"), { [self] in session.setAction(.nothing, rows: selectedRows) }),
            (key("l"), { [self] in session.setAction(.copyToRight, rows: selectedRows) }),
            (key("r"), { [self] in session.setAction(.copyToLeft, rows: selectedRows) }),
            (key("w"), { [self] in session.reverse(rows: selectedRows) }),
            (Shortcut.f(3, .control).matches(event), { [self] in session.compareContents(row: selectedRows.first) }),
            (Shortcut.f(3).matches(event), first { [session] row in session.view(.left, row: row, command: .view) }),
            (
                Shortcut.f(3, .shift).matches(event),
                first { [session] row in session.view(.right, row: row, command: .view) }
            ),
            (Shortcut.f(4).matches(event), first { [session] row in session.view(.left, row: row, command: .edit) }),
            (
                Shortcut.f(4, .shift).matches(event),
                first { [session] row in session.view(.right, row: row, command: .edit) }
            )
        ]
    }

    /// The keys of the Show buttons, the saved sets and moving between subdirectories.
    private func windowKeys(_ event: NSEvent) -> [(matches: Bool, run: () -> Void)] {
        func showKey(_ character: String) -> Bool {
            Shortcut(.character(character), [.control, .shift]).matches(event)
        }
        return [
            (showKey("l"), { [self] in toggleShow(.copyToRight) }),
            (showKey("e"), { [self] in toggleShow(.equal) }),
            (showKey("n"), { [self] in toggleShow(.notEqual) }),
            (showKey("r"), { [self] in toggleShow(.copyToLeft) }),
            (showKey("d"), { [self] in toggleShow(.duplicates) }),
            (showKey("s"), { [self] in toggleShow(.singles) }),
            (Shortcut.f(2).matches(event), { [self] in effects.showMenu(setsButton) }),
            (Shortcut(.pageDown, .control).matches(event), { [self] in jumpToHeader(forward: true) }),
            (Shortcut(.pageUp, .control).matches(event), { [self] in jumpToHeader(forward: false) })
        ]
    }
}
