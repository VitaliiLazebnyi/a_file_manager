import AppKit

/// The small field at the bottom of a panel the quick filter is typed into.
internal final class QuickFilterBar: NSView, NSTextFieldDelegate {
    /// Called with the text after every change.
    internal var onChange: ((String) -> Void)?
    /// Esc: the filter and the field go away.
    internal var onCancel: (() -> Void)?
    /// Enter or an arrow key: back to the list, the filter stays.
    internal var onReturn: (() -> Void)?
    /// The field itself.
    internal let field = NSTextField(string: "")
    /// The button that takes the filter away.
    internal let closeButton = NSButton(title: "✕", target: nil, action: nil)

    /// What is in the field.
    internal var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// True while the field has the keyboard.
    internal var isEditing: Bool { field.currentEditor() != nil }

    /// A bar with its label, field and close button, laid out from edge to edge.
    override internal init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "Filter:")
        label.font = .systemFont(ofSize: 11)
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.placeholderString = "part of a name, or a mask such as *.txt"
        field.setAccessibilityLabel("Quick filter")
        field.delegate = self
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.refusesFirstResponder = true
        closeButton.toolTip = "Remove the filter (Esc)"
        closeButton.setAccessibilityLabel("Remove the filter")
        let stack = NSStackView(views: [label, field, closeButton])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The row fills the bar from edge to edge.
        NSLayoutConstraint.activate(
            [NSLayoutConstraint.Attribute.top, .bottom, .leading, .trailing]
                .map { edge in
                    NSLayoutConstraint(
                        item: stack,
                        attribute: edge,
                        relatedBy: .equal,
                        toItem: self,
                        attribute: edge,
                        multiplier: 1,
                        constant: 0
                    )
                }
        )
    }

    /// Not made from an archive.
    @available(*, unavailable)
    internal required init?(coder _: NSCoder) {
        fatalError("not used")
    }

    /// Puts the keyboard into the field, with the caret at the end of what is there.
    internal func beginEditing() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }

    /// The field changed: `onChange` hears the text.
    internal func controlTextDidChange(_: Notification) {
        onChange?(field.stringValue)
    }

    /// Esc ends the filter; Enter, ↑ and ↓ go back to the list.
    ///
    /// Other keys are the field's.
    internal func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()

        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)):
            onReturn?()

        default:
            return false
        }
        return true
    }

    /// The close button: as Esc.
    @objc
    private func closePressed() {
        onCancel?()
    }
}
