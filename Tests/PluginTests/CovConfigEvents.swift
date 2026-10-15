import AppKit

@testable import ConfigurationPlugin

/// Key presses as the user makes them, and the texts of the configuration windows' lists.
@MainActor
internal enum CovConfigEvents {
    /// A key press in `window` (none: in no window).
    internal static func key(
        _ characters: String,
        code: UInt16,
        in window: NSWindow?,
        _ flags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )
    }

    /// The text of a cell of a list; empty when there is none.
    internal static func cell(_ table: RowsTable, row: Int, column: Int) -> String {
        let view = table.tableView(table.tableView, viewFor: table.tableView.tableColumns[column], row: row)
        return (view as? NSTableCellView)?.textField?.stringValue ?? ""
    }
}
