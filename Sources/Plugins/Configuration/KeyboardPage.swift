import AFMKernel
import AppKit

/// Redefine hotkeys (spec 14 › Redefining hotkeys and aliases; 06 › Redefining keys): every
/// command with its keys; a new key is chosen by pressing it.
internal final class KeyboardPage: NSObject, OptionsPage, NSSearchFieldDelegate {
    private unowned let center: ConfigurationCenter
    private var editor: KeyBindingEditor
    private var rows: [CommandRow] = []
    private let table = RowsTable(columns: [("Command", 210), ("Name", 170), ("Keys", 150)])
    private let filter = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private var monitor: Any?
    /// The page's name, "Keyboard".
    internal let title = "Keyboard"
    /// The filter, the list of commands with their keys and the buttons that change them.
    internal private(set) lazy var view: NSView = {
        filter.placeholderString = "Filter by command, name or key"
        filter.delegate = self
        let buttons = [
            ActionButton("Set Shortcut…") { [weak self] in self?.record(adding: false) },
            ActionButton("Add Shortcut…") { [weak self] in self?.record(adding: true) },
            ActionButton("Remove Shortcuts") { [weak self] in self?.removeShortcuts() },
            ActionButton("Reset to Default") { [weak self] in self?.resetSelected() },
            ActionButton("Reset All") { [weak self] in self?.resetAll() }
        ]
        status.lineBreakMode = .byTruncatingTail
        return filledStack(
            [
                filter, OptionsLayout.editor(table, buttons: buttons, below: []), status,
                OptionsLayout.note(
                    "A key belongs to one command. Menus show the new keys at once; "
                        + "the function-key bar after a restart."
                )
            ],
            vertical: true,
            spacing: 8
        )
    }()
    /// Called after every change of a binding.
    internal var onEdit: (() -> Void)?

    /// Whether the bindings differ from the stored ones.
    internal var isChanged: Bool { editor.isChanged }

    private var selected: CommandRow? { table.selectedRow.flatMap { rows.dropFirst($0).first } }

    /// A page that edits the bindings of the center's kernel and follows bindings stored elsewhere.
    internal init(center: ConfigurationCenter) {
        self.center = center
        editor = KeyBindingEditor(kernel: center.kernel)
        super.init()
        center.keysCommitted = { [weak self] in self?.bindingsStoredElsewhere() }
    }

    private func reload() {
        let kernel = center.kernel
        let all = CommandCatalog.rows(
            commands: kernel.commands.all,
            menus: kernel.menus.menus,
            shortcuts: editor.shortcuts(for:)
        )
        rows = CommandCatalog.filter(all, text: filter.stringValue, category: nil)
        table.show(
            rows.map { [$0.title, $0.id.rawValue, $0.keys + (editor.isCustomized($0.id) ? "  •" : "")] },
            symbols: [],
            selecting: nil
        )
    }

    private func edited() {
        reload()
        onEdit?()
    }

    private func change(_ body: (CommandID) -> Void) {
        stopRecording()
        guard let row = selected else {
            center.effects.beep()
            return
        }
        body(row.id)
        edited()
    }

    private func removeShortcuts() {
        change { editor.set([], for: $0) }
    }

    private func resetSelected() {
        change { editor.reset($0) }
    }

    private func resetAll() {
        editor.resetAll()
        edited()
    }

    /// Each change of the filter narrows the list again.
    internal func controlTextDidChange(_: Notification) { reload() }

    private func stopRecording() {
        if let monitor { center.effects.removeKeyMonitor(monitor) }
        monitor = nil
        status.stringValue = ""
    }

    /// The next key press in this window becomes the command's key; Esc gives up.
    private func record(adding: Bool) {
        stopRecording()
        guard let row = selected else {
            center.effects.beep()
            return
        }
        status.stringValue = "Press the new shortcut for “\(row.title)”. Esc cancels."
        view.window?.makeFirstResponder(table.tableView)
        monitor = center.effects.monitorKeys { [weak self] event in
            guard let self, event.window === view.window else {
                return event
            }
            stopRecording()
            var modifiers: KeyModifiers = []
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            let isEscape = event.keyCode == 53 && modifiers.isEmpty
            guard !isEscape,
                let shortcut = ShortcutText.shortcut(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers,
                    modifiers: modifiers
                )
            else { return nil }
            // The question about a key that is in use is asked after the key press is dealt with,
            // when the window may have gone (weak).
            MainLoop.perform { [weak self] in self?.assign(shortcut, to: row.id, adding: adding) }
            return nil
        }
    }

    /// Gives `shortcut` to the command `id`, asking about a key that is in use.
    private func assign(_ shortcut: Shortcut, to id: CommandID, adding: Bool) {
        if editor.assign(shortcut, to: id, adding: adding, asking: center.kernel.interaction) { edited() }
    }

    /// Stores the bindings, applies them to the program and its menus, and starts again from them.
    internal func commit() {
        stopRecording()
        guard editor.isChanged else {
            return
        }
        editor.commit(to: center.kernel.settings, keyBindings: center.kernel.keyBindings)
        center.refreshMenus()
        discard()
    }

    /// Drops the edits and shows the stored bindings.
    internal func discard() {
        stopRecording()
        editor = KeyBindingEditor(kernel: center.kernel)
        reload()
    }

    /// Bindings were stored elsewhere (the Start menu, a command's shortcut field, an import):
    /// this page's editor starts from them, with its own unapplied edits kept on top.
    internal func bindingsStoredElsewhere() {
        editor.rebase(kernel: center.kernel)
        reload()
        onEdit?()
    }
}
