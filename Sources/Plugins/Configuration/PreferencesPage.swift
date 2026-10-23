import AFMKernel
import AppKit

/// A page a plugin registered: one control per preference (spec 13 › The dialog framework).
internal final class PreferencesPage: NSObject, OptionsPage, NSTextFieldDelegate {
    private let model: PreferencePageModel
    private var controls: [(preference: Preference, control: NSControl)] = []
    /// The grid of labels and controls, one row per preference.
    internal let view = NSView()
    /// Called after every change of a control.
    internal var onEdit: (() -> Void)?

    /// The title the plugin gave the page.
    internal var title: String { model.title }
    /// Whether a control differs from what is stored.
    internal var isChanged: Bool { model.isChanged }

    /// Makes a control for every preference of the model's page and shows the stored values.
    internal init(model: PreferencePageModel) {
        self.model = model
        super.init()
        let rows: [[NSView]] = model.page.preferences.map { preference in
            let label = NSTextField(labelWithString: preference.label)
            let control: NSControl
            switch preference.kind {
            case .flag:
                control = NSButton(checkboxWithTitle: preference.label, target: self, action: #selector(changed))

            case .text:
                let field = NSTextField(string: "")
                field.delegate = self
                field.widthAnchor.constraint(equalToConstant: 300).isActive = true
                control = field

            case .choice(let options, _):
                let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
                for option in options {
                    popUp.menu?.addItem(NSMenuItem(title: option, action: nil, keyEquivalent: ""))
                }
                popUp.target = self
                popUp.action = #selector(changed)
                control = popUp
            }
            controls.append((preference, control))
            if case .flag = preference.kind {
                return [NSGridCell.emptyContentView, control]
            }
            return [label, control]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        if grid.numberOfColumns > 1 { grid.column(at: 0).xPlacement = .trailing }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        show()
    }

    @objc
    private func changed() {
        for (preference, control) in controls {
            switch preference.kind {
            case .flag:
                model.set(.flag((control as? NSButton)?.state == .on), for: preference)

            case .text:
                model.set(.text(control.stringValue), for: preference)

            case .choice:
                if let popUp = control as? NSPopUpButton {
                    model.set(.index(popUp.indexOfSelectedItem), for: preference)
                }
            }
        }
        onEdit?()
    }

    /// Typing in a text field is a change like any other.
    internal func controlTextDidChange(_: Notification) { changed() }

    private func show() {
        for (preference, control) in controls {
            switch model.value(of: preference) {
            case .flag(let isOn):
                (control as? NSButton)?.state = isOn ? .on : .off

            case .text(let text):
                control.stringValue = text

            case .index(let index):
                (control as? NSPopUpButton)?.selectItem(at: index)
            }
        }
    }

    /// Stores the values of the controls.
    internal func commit() { model.commit() }

    /// Drops the changes and shows the stored values again.
    internal func discard() {
        model.discard()
        show()
    }
}
