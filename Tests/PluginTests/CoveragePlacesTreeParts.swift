import AFMShell
import AppKit
import Foundation

@testable import PlacesPlugin

/// The parts of the Directory Tree window, found by their place in it.
@MainActor
internal struct CoveragePlacesTreeParts {
    /// The window's controller, as the plugin makes it.
    internal let controller: DirectoryTreeWindowController

    /// The window; nil only if the controller made none.
    internal var window: NSWindow? { controller.window }

    /// The pop-up of the roots to choose from.
    internal var popup: NSPopUpButton? { stack?.arrangedSubviews[0] as? NSPopUpButton }

    /// The list of folders.
    internal var outline: NSOutlineView? { CoveragePlacesLoop.views(NSOutlineView.self, in: stack).first }

    /// The path of the folder under the cursor, as the line below the list shows it.
    internal var path: String { (stack?.arrangedSubviews[2] as? NSTextField)?.stringValue ?? "" }

    /// The quick search field.
    internal var searchField: NSTextField? { row(3)?.arrangedSubviews[1] as? NSTextField }

    /// The status line: the count of folders, or what is being read.
    internal var status: String { (row(4)?.arrangedSubviews[0] as? NSTextField)?.stringValue ?? "" }

    /// The titles of the rows as they are drawn.
    internal var rows: [String] {
        guard let outline else {
            return []
        }
        return (0..<outline.numberOfRows).map(title(ofRow:))
    }

    /// The title of the selected row; nil when no row is selected.
    internal var selected: String? {
        guard let outline, outline.selectedRow >= 0 else {
            return nil
        }
        return title(ofRow: outline.selectedRow)
    }

    /// The number of folders the status line names; 0 when it names none.
    internal var count: Int {
        let token = status.split(separator: " ").first { $0.contains(where: \.isNumber) } ?? ""
        return Int(token.filter(\.isNumber)) ?? 0
    }

    /// A scan or a read of the cache is over and the count shows.
    internal var isIdle: Bool { status.hasSuffix("directories") || status.hasSuffix("F2 reads the rest") }

    private var stack: NSStackView? { window?.contentView as? NSStackView }

    private func row(_ index: Int) -> NSStackView? { stack?.arrangedSubviews[index] as? NSStackView }

    /// The title the list draws for `row`; empty for a row that is not there.
    internal func title(ofRow row: Int) -> String {
        guard let outline, let item = outline.item(atRow: row) else {
            return ""
        }
        return (controller.outlineView(outline, viewFor: nil, item: item) as? NSTextField)?.stringValue ?? ""
    }

    /// The row titled `title`, or -1.
    internal func row(titled title: String) -> Int {
        rows.firstIndex(of: title) ?? -1
    }

    /// Clicks the button titled `title`; nothing when there is none.
    internal func click(_ title: String) {
        guard let button = CoveragePlacesLoop.button(title, in: stack), let action = button.action else {
            return
        }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    /// Presses a key in the list of folders.
    internal func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) throws {
        outline?.keyDown(with: try CoveragePlacesLoop.key(characters, code: code, modifiers: modifiers))
    }

    /// Types `text` into the quick search field, as if each change came from the keyboard.
    internal func type(_ text: String) {
        searchField?.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    }

    /// Chooses the root at `index` of the pop-up; a negative index chooses none.
    internal func chooseRoot(_ index: Int) {
        guard let popup, let action = popup.action else {
            return
        }
        if index < 0 {
            popup.select(nil)
        } else {
            popup.selectItem(at: index)
        }
        NSApp.sendAction(action, to: popup.target, from: popup)
    }

    /// Presses Esc in the window; whether the window took it.
    internal func escape() -> Bool { (window as? ToolWindow)?.onEscape?() == true }
}
