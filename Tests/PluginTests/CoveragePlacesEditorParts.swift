import AppKit
import Foundation
import Testing

@testable import PlacesPlugin

/// The parts of the hotlist editor's window, found by their place in it.
@MainActor
internal struct CoveragePlacesEditorParts {
    /// The editor's window.
    internal let window: NSWindow

    /// The editor, the delegate of its window.
    internal var controller: HotlistEditorWindowController? { window.delegate as? HotlistEditorWindowController }

    /// The window's content view, where the other parts are found.
    internal var content: NSView? { window.contentView }

    /// The list of entries.
    internal var table: NSTableView? { CoveragePlacesLoop.views(NSTableView.self, in: content).first }

    /// The editable fields, in the order they are laid out.
    internal var fields: [NSTextField] { CoveragePlacesLoop.views(NSTextField.self, in: content).filter(\.isEditable) }

    /// The field of the selected entry's command.
    internal var command: NSTextField { fields[0] }

    /// The field of the command for the other panel.
    internal var target: NSTextField { fields[1] }

    /// The field of the character that marks hidden entries.
    internal var hideCharacter: NSTextField { fields[2] }

    /// The line that tells which entry is selected, as "Entry n of m".
    internal var number: String {
        ((content as? NSStackView)?.arrangedSubviews.last as? NSStackView)?.arrangedSubviews.first
            .map { ($0 as? NSTextField)?.stringValue ?? "" } ?? ""
    }

    /// The titles of the rows as the list draws them.
    internal var titles: [String] {
        guard let table, let controller else {
            return []
        }
        return (0..<controller.numberOfRows(in: table))
            .map { row in
                (controller.tableView(table, viewFor: nil, row: row) as? NSTextField)?.stringValue ?? ""
            }
    }

    /// Clicks the button titled `title`, whether it is enabled or not.
    internal func click(_ title: String) {
        guard let button = CoveragePlacesLoop.button(title, in: content), let action = button.action else {
            Issue.record("no button \(title)")
            return
        }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    /// Selects the row `row` of the list, and only it.
    internal func select(_ row: Int) {
        table?.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// Types `text` into `field`, as if the change came from the keyboard.
    internal func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        controller?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    /// Presses a key in the list of entries.
    internal func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) throws {
        table?.keyDown(with: try CoveragePlacesLoop.key(characters, code: code, modifiers: modifiers))
    }
}
