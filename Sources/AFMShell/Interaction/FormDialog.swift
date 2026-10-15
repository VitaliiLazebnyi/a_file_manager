import AFMKernel
import AppKit

/// Shows a plugin's form (`UserInteraction.form`) as an alert with one row per field.
///
/// A form with more rows than fit is scrolled; a long list gets a field that narrows it down.
/// Return takes the first button, Esc cancels, a double click on a list row accepts. Main
/// thread only.
@MainActor
internal final class FormDialog: NSObject, NSTextViewDelegate {
    /// A clip view that starts at the top, so a scrolled form starts at its first row.
    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }

        deinit {
            // Nothing to release.
        }
    }

    /// The width of a field.
    internal static let fieldWidth: CGFloat = 380
    /// The widest a label in front of a field gets before it wraps.
    internal static let labelWidth: CGFloat = 200

    /// The height the rows may take before they are scrolled.
    ///
    /// What the screen has left beside the alert's own title, text and buttons.
    internal static var maximumHeight: CGFloat {
        maximumHeight(forScreenHeight: NSScreen.main?.visibleFrame.height)
    }

    /// The list fields, in the order of the form.
    internal private(set) var lists: [FormList] = []
    /// The view that takes the keyboard when the dialog opens.
    internal private(set) var firstInput: NSView?
    /// The scroll view around the rows, when they do not fit.
    internal private(set) var scrollView: NSScrollView?
    /// The fields of the form.
    private let fields: [FormField]
    /// Each field that holds a value, with how to read it.
    private var controls: [(field: FormField, read: () -> FormValues.Value)] = []
    /// The alert, while it is shown.
    private weak var alert: NSAlert?
    /// Brings a field reached with Tab into view in a scrolled form.
    private var focusObservation: NSKeyValueObservation?

    /// A dialog for `fields`.
    internal init(fields: [FormField]) {
        self.fields = fields
    }

    /// The height the rows may take on a screen `height` points high; as on a screen 800
    /// points high when there is none to ask.
    internal static func maximumHeight(forScreenHeight height: CGFloat?) -> CGFloat {
        guard let height else {
            return 460
        }
        return min(560, max(240, height - 340))
    }

    /// Shows the form and waits for an answer; nil when the user cancels.
    internal func run(title: String, detail: String, buttons: [String]) -> FormValues? {
        answer(after: makeAlert(title: title, detail: detail, buttons: buttons).runModal(), buttons: buttons)
    }

    /// The answer of the form once `response` ended it: the fields with the button pressed, nil
    /// for Cancel (the button after `buttons`).
    internal func answer(after response: NSApplication.ModalResponse, buttons: [String]) -> FormValues? {
        let index = AlertInteraction.index(of: response)
        focusObservation = nil
        return buttons.indices.contains(index) ? values(button: index) : nil
    }

    /// What the fields hold now, as the answer given with a button.
    internal func values(button: Int) -> FormValues {
        var answer = FormValues(button: button)
        for control in controls {
            answer.values[control.field.key] = control.read()
        }
        return answer
    }

    /// Builds the dialog without showing it, for the screen it would be shown on.
    internal func makeAlert(title: String, detail: String, buttons: [String]) -> NSAlert {
        makeAlert(title: title, detail: detail, buttons: buttons, maximumHeight: Self.maximumHeight)
    }

    /// Builds the dialog without showing it; rows higher than `maximumHeight` are scrolled.
    internal func makeAlert(title: String, detail: String, buttons: [String], maximumHeight: CGFloat) -> NSAlert {
        let question = NSAlert()
        // Titles and texts may name files and servers; see `AlertInteraction`.
        question.messageText = DisplayText.clean(title, keepingLines: true)
        question.informativeText = DisplayText.clean(detail, keepingLines: true)
        for button in buttons {
            question.addButton(withTitle: button)
        }
        question.addButton(withTitle: "Cancel")
        question.buttons.last?.keyEquivalent = "\u{1b}"
        alert = question
        let grid = makeGrid()
        if grid.frame.height > maximumHeight {
            question.accessoryView = makeScrollView(around: grid, height: maximumHeight)
        } else {
            question.accessoryView = grid
        }
        question.window.initialFirstResponder = firstInput
        question.window.recalculateKeyViewLoop()
        question.layout()
        for list in lists {
            list.showSelection()
        }
        if scrollView != nil {
            observeFocus(in: question.window)
        }
        return question
    }

    /// In a box for several lines Return starts a new line; Tab goes on to the next field
    /// instead of writing a tab, so the dialog can be left with the keyboard.
    internal func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectNextKeyView(nil)

        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil)

        default:
            return false
        }
        return true
    }

    /// The rows of the form in a grid of labels and controls, at the size it needs.
    private func makeGrid() -> NSGridView {
        let rows: [[NSView]] = fields.map { field in
            let label = NSTextField(labelWithString: field.label)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            guard let control = makeControl(for: field) else {
                // A note takes the whole width.
                label.preferredMaxLayoutWidth = Self.fieldWidth + 120
                return [label]
            }
            if case .checkbox = field.kind {
                return [NSGridCell.emptyContentView, control]
            }
            control.setAccessibilityLabel(field.label)
            label.alignment = .right
            label.preferredMaxLayoutWidth = Self.labelWidth
            return field.label.isEmpty ? [control] : [label, control]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for (index, row) in rows.enumerated() where row.count == 1 {
            grid.mergeCells(
                inHorizontalRange: NSRange(location: 0, length: grid.numberOfColumns),
                verticalRange: NSRange(location: index, length: 1)
            )
        }
        if grid.numberOfColumns > 1 {
            grid.column(at: 0).xPlacement = .trailing
        }
        grid.rowAlignment = .firstBaseline
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        return grid
    }

    /// A scroll view of `height` around the rows.
    private func makeScrollView(around grid: NSGridView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: grid.frame.width + 20, height: height))
        // Flipped, so the form starts at its first row.
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scrollView = scroll
        return scroll
    }

    /// Brings a field reached with Tab into view.
    private func observeFocus(in window: NSWindow) {
        focusObservation = window.observe(\.firstResponder) { window, _ in
            // The first responder changes on the main thread, where this is called.
            MainActor.assumeIsolated {
                // The field editor stands in for the text field it edits.
                let responder = window.firstResponder
                let view = ((responder as? NSTextView)?.delegate as? NSView) ?? responder as? NSView
                view?.scrollToVisible(view?.bounds.insetBy(dx: 0, dy: -8) ?? .zero)
            }
        }
    }

    /// The first view that can take the keyboard is the one that has it when the dialog opens.
    private func takesKeyboard(_ view: NSView) {
        if firstInput == nil {
            firstInput = view
        }
    }

    /// The control of a field, which also notes how to read it; nil for a note.
    private func makeControl(for field: FormField) -> NSView? {
        switch field.kind {
        case .note:
            return nil

        case .text(let value):
            return makeTextField(NSTextField(string: value), for: field)

        case .secureText:
            return makeTextField(NSSecureTextField(string: ""), for: field)

        case .multilineText(let value):
            return makeTextBox(value, for: field)

        case .checkbox(let isOn):
            let box = NSButton(checkboxWithTitle: field.label, target: nil, action: nil)
            box.state = isOn ? .on : .off
            controls.append((field, { .flag(box.state == .on) }))
            return box

        case .choice(let options, let selected):
            return makePopUp(options, selected: selected, for: field)

        case .list(let rows, let selected):
            let list = FormList(rows: rows, selected: selected, width: Self.fieldWidth)
            list.onAccept = { [weak self] in self?.alert?.buttons.first?.performClick(nil) }
            lists.append(list)
            takesKeyboard(list.keyboardView)
            controls.append((field, { .index(list.selectedRow) }))
            return list.view
        }
    }

    /// A one-line field; a long path scrolls inside its line instead of being cut off.
    private func makeTextField(_ input: NSTextField, for field: FormField) -> NSView {
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        takesKeyboard(input)
        controls.append((field, { .text(input.stringValue) }))
        return input
    }

    /// A box for several lines of plain text, starting with `value`.
    private func makeTextBox(_ value: String, for field: FormField) -> NSView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: Self.fieldWidth, height: 120))
        textView.string = value
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        takesKeyboard(textView)
        controls.append((field, { .text(textView.string) }))
        return scroll
    }

    /// A pop-up menu of `options` with `selected` chosen.
    private func makePopUp(_ options: [String], selected: Int, for field: FormField) -> NSView {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        // Added one by one: `addItems` drops options with the same caption.
        for option in options {
            popUp.menu?.addItem(NSMenuItem(title: option, action: nil, keyEquivalent: ""))
        }
        if options.indices.contains(selected) {
            popUp.selectItem(at: selected)
        }
        popUp.widthAnchor.constraint(lessThanOrEqualToConstant: Self.fieldWidth).isActive = true
        controls.append((field, { .index(popUp.indexOfSelectedItem) }))
        return popUp
    }

    deinit {
        // Nothing to release.
    }
}
