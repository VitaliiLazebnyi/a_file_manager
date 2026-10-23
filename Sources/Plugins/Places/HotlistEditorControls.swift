import AppKit

/// The controls of the hotlist editor and their layout (spec 12 › Directory hotlist editor).
///
/// Made with the dialog's buttons and the actions they send; the editor sets itself as their target, and as the
/// list's data source and the fields' delegate. Main thread only.
@MainActor
internal struct HotlistEditorControls {
    /// A button of the dialog: its title and the action it sends.
    internal typealias Action = (title: String, selector: Selector)

    /// The list of entries, which hands the keys it is sent to `onKey` first.
    internal final class EntryTableView: NSTableView {
        /// Handles a key; true when it was used, otherwise the table handles it.
        internal var onKey: ((NSEvent) -> Bool)?

        /// Offers the key to `onKey`, then to the table.
        override internal func keyDown(with event: NSEvent) {
            if onKey?(event) != true {
                super.keyDown(with: event)
            }
        }
    }

    /// The list of entries.
    internal let table = EntryTableView()
    /// "Entry n of m" below the list.
    internal let numberLabel = NSTextField(labelWithString: "")
    /// The command of the selected entry.
    internal let commandField = NSTextField()
    /// The target path of the selected entry.
    internal let targetField = NSTextField()
    /// Whether entries marked with the hide character are hidden.
    internal let hideBox = NSButton(
        checkboxWithTitle: "Hide menu items starting with this character:",
        target: nil,
        action: nil
    )
    /// The hide character.
    internal let hideField = NSTextField()
    /// The buttons that add entries, in the order of `addActions`.
    internal let listButtons: [NSButton]
    /// The buttons that act on the selected entry, in the order of `entryActions`.
    internal let entryButtons: [NSButton]
    /// Cancel and OK.
    internal let footerButtons: [NSButton]
    /// Everything, laid out for the window's content.
    internal let content: NSStackView

    /// The buttons that send actions, all of them.
    internal var buttons: [NSButton] { listButtons + entryButtons + footerButtons + [hideBox] }

    /// The controls with buttons for `addActions`, `entryActions` and the footer's Cancel and OK, laid out.
    internal init(addActions: [Action], entryActions: [Action], cancel: Selector, accept: Selector) {
        listButtons = addActions.map(Self.button)
        entryButtons = entryActions.map(Self.button)
        let okButton = NSButton(title: "OK", target: nil, action: accept)
        okButton.keyEquivalent = "\r"
        footerButtons = [NSButton(title: "Cancel", target: nil, action: cancel), okButton]
        content = NSStackView()
        layOut()
    }

    /// A button of the column next to the list, all of one width.
    private static func button(_ action: Action) -> NSButton {
        let made = NSButton(title: action.title, target: nil, action: action.selector)
        made.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return made
    }

    /// A label for a field, aligned to the field.
    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    /// Puts the parts into `content`: the list with its buttons, the fields, the hiding settings, a hint, the footer.
    private func layOut() {
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")))
        table.headerView = nil
        table.rowHeight = 18
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let buttonColumn = NSStackView(views: listButtons + entryButtons)
        buttonColumn.orientation = .vertical
        buttonColumn.alignment = .leading
        let top = NSStackView(views: [scroll, buttonColumn])
        top.alignment = .top

        commandField.placeholderString = "cd /path/to/folder   (or the name of a command, e.g. cm_GoToRoot)"
        targetField.placeholderString = "optional: a path shown in the other panel at the same time"
        hideField.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let fields = NSGridView(views: [
            [Self.label("Command:"), commandField], [Self.label("Target path:"), targetField]
        ])
        fields.column(at: 0).xPlacement = .trailing
        let hiding = NSStackView(views: [hideBox, hideField])
        let hint = NSTextField(
            labelWithString: "Double click a menu item to hide or show it. Shift+↑ and Shift+↓ move it."
        )
        hint.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [numberLabel, NSView()] + footerButtons)
        numberLabel.textColor = .secondaryLabelColor

        for part in [top, fields, hiding, hint, footer] as [NSView] {
            content.addArrangedSubview(part)
        }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        for part in [top, fields, footer] as [NSView] {
            part.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
        }
    }
}
