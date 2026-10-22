import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// A page of the Options window.
///
/// What the user changes on it is pending until `commit`.
@MainActor
protocol OptionsPage: AnyObject {
    var title: String { get }
    var view: NSView { get }
    var isChanged: Bool { get }
    /// Called by the page when the user changed something, so Apply can be offered.
    var onEdit: (() -> Void)? { get set }
    /// Apply and OK.
    func commit()
    /// Cancel, and every time the window opens: show what is stored.
    func discard()
}

/// A list with a column of buttons to its right, the shape of the editors of spec 14.
@MainActor
private func editorView(_ list: NSView, buttons: [NSView], below: [NSView] = []) -> NSView {
    let column = filledStack(buttons + [spacer()], vertical: true, spacing: 6)
    column.setHuggingPriority(.required, for: .horizontal)
    return filledStack([filledStack([list, column], vertical: false, spacing: 10)] + below, vertical: true)
}

@MainActor
private func note(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    return label
}

/// A page a plugin registered: one control per preference (spec 13 › The dialog framework).
final class PreferencesPage: NSObject, OptionsPage, NSTextFieldDelegate {
    private let model: PreferencePageModel
    private var controls: [(preference: Preference, control: NSControl)] = []
    let view = NSView()
    var onEdit: (() -> Void)?

    init(model: PreferencePageModel) {
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
            if case .flag = preference.kind { return [NSGridCell.emptyContentView, control] }
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

    var title: String { model.title }
    var isChanged: Bool { model.isChanged }

    @objc private func changed() {
        for (preference, control) in controls {
            switch preference.kind {
            case .flag: model.set(.flag((control as? NSButton)?.state == .on), for: preference)
            case .text: model.set(.text(control.stringValue), for: preference)
            case .choice:
                if let popUp = control as? NSPopUpButton {
                    model.set(.index(popUp.indexOfSelectedItem), for: preference)
                }
            }
        }
        onEdit?()
    }

    func controlTextDidChange(_: Notification) { changed() }

    private func show() {
        for (preference, control) in controls {
            switch model.value(of: preference) {
            case .flag(let isOn): (control as? NSButton)?.state = isOn ? .on : .off
            case .text(let text): control.stringValue = text
            case .index(let index): (control as? NSPopUpButton)?.selectItem(at: index)
            }
        }
    }

    func commit() { model.commit() }

    func discard() {
        model.discard()
        show()
    }
}

/// Redefine hotkeys (spec 14 › Redefining hotkeys and aliases; 06 › Redefining keys): every
/// command with its keys; a new key is chosen by pressing it.
final class KeyboardPage: NSObject, OptionsPage, NSSearchFieldDelegate {
    private unowned let center: ConfigurationCenter
    private var editor: KeyBindingEditor
    private var rows: [CommandRow] = []
    private let table = RowsTable(columns: [("Command", 210), ("Name", 170), ("Keys", 150)])
    private let filter = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private var monitor: Any?
    let title = "Keyboard"
    private(set) lazy var view: NSView = {
        filter.placeholderString = "Filter by command, name or key"
        filter.delegate = self
        let buttons = [
            ActionButton("Set Shortcut…") { [unowned self] in record(adding: false) },
            ActionButton("Add Shortcut…") { [unowned self] in record(adding: true) },
            ActionButton("Remove Shortcuts") { [unowned self] in change { editor.set([], for: $0) } },
            ActionButton("Reset to Default") { [unowned self] in change { editor.reset($0) } },
            ActionButton("Reset All") { [unowned self] in
                editor.resetAll()
                edited()
            }
        ]
        status.lineBreakMode = .byTruncatingTail
        return filledStack(
            [
                filter, editorView(table, buttons: buttons), status,
                note(
                    "A key belongs to one command. Menus show the new keys at once; the function-key bar after a restart."
                )
            ],
            vertical: true
        )
    }()
    var onEdit: (() -> Void)?

    init(center: ConfigurationCenter) {
        self.center = center
        editor = KeyBindingEditor(kernel: center.kernel)
        super.init()
        center.keysCommitted = { [weak self] in self?.bindingsStoredElsewhere() }
    }

    var isChanged: Bool { editor.isChanged }

    private func reload() {
        let kernel = center.kernel
        let all = CommandCatalog.rows(
            commands: kernel.commands.all,
            menus: kernel.menus.menus,
            shortcuts: editor.shortcuts(for:)
        )
        rows = CommandCatalog.filter(all, text: filter.stringValue)
        table.show(rows.map { [$0.title, $0.id.rawValue, $0.keys + (editor.isCustomized($0.id) ? "  •" : "")] })
    }

    private var selected: CommandRow? { table.selectedRow.flatMap { rows.dropFirst($0).first } }

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

    func controlTextDidChange(_: Notification) { reload() }

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
            guard let self, event.window === view.window else { return event }
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

    func commit() {
        stopRecording()
        guard editor.isChanged else { return }
        editor.commit(to: center.kernel.settings, keyBindings: center.kernel.keyBindings)
        center.refreshMenus()
        discard()
    }

    func discard() {
        stopRecording()
        editor = KeyBindingEditor(kernel: center.kernel)
        reload()
    }

    /// Bindings were stored elsewhere (the Start menu, a command's shortcut field, an import):
    /// this page's editor starts from them, with its own unapplied edits kept on top.
    func bindingsStoredElsewhere() {
        editor.rebase(kernel: center.kernel)
        reload()
        onEdit?()
    }
}

/// The button-bar editor (spec 14 › The Change button bar dialog), as a list.
final class ButtonBarPage: NSObject, OptionsPage {
    private unowned let center: ConfigurationCenter
    private let editor: ToolbarEditor
    private let table = RowsTable(columns: [("Button", 250), ("Command", 200)])
    let title = "Button Bar"
    private(set) lazy var view: NSView = editorView(
        table,
        buttons: [
            ActionButton("Add Command…") { [unowned self] in
                guard let picked = center.pickCommand() else { return }
                edited(selecting: editor.insert(picked.id, after: table.selectedRow))
            },
            ActionButton("Add Separator") { [unowned self] in
                edited(selecting: editor.insert(nil, after: table.selectedRow))
            },
            ActionButton("Add Line Break") { [unowned self] in
                edited(selecting: editor.insert(ToolbarRegistry.lineBreak, after: table.selectedRow))
            },
            ActionButton("Remove") { [unowned self] in
                guard let row = table.selectedRow else { return center.effects.beep() }
                editor.remove(at: row)
                edited(selecting: row)
            },
            ActionButton("Move Up") { [unowned self] in move(-1) },
            ActionButton("Move Down") { [unowned self] in move(1) },
            ActionButton("Symbol…") { [unowned self] in chooseSymbol() },
            ActionButton("Reset to Default") { [unowned self] in
                editor.resetToDefault()
                edited(selecting: nil)
            }
        ],
        below: [
            note(
                "A new button goes directly after the selected one. A program with parameters goes on the bar as a user command "
                    + "(Configuration › User Commands)."
            )
        ]
    )
    var onEdit: (() -> Void)?

    init(center: ConfigurationCenter) {
        self.center = center
        editor = ToolbarEditor(toolbar: center.kernel.toolbar, settings: center.kernel.settings, store: center.store)
        super.init()
    }

    var isChanged: Bool { editor.isChanged }

    private func reload(selecting row: Int? = nil) {
        let commands = center.kernel.commands
        table.show(
            editor.items.map { id in
                guard let id else { return ["———", ""] }
                return id == ToolbarRegistry.lineBreak
                    ? ["═══ New line ═══", ""] : [commands[id]?.title ?? "(unknown command)", id.rawValue]
            },
            symbols: editor.items.map { id in
                id.flatMap { $0 == ToolbarRegistry.lineBreak ? nil : editor.symbol(for: $0) }
            },
            selecting: row
        )
    }

    private func edited(selecting row: Int?) {
        reload(selecting: row)
        onEdit?()
    }

    private func move(_ offset: Int) {
        guard let row = table.selectedRow else {
            center.effects.beep()
            return
        }
        edited(selecting: editor.move(row, by: offset))
    }

    /// The picture of a button is a system symbol, chosen by its name.
    private func chooseSymbol() {
        guard let row = table.selectedRow, editor.items.indices.contains(row), let id = editor.items[row],
            id != ToolbarRegistry.lineBreak
        else {
            center.effects.beep()
            return
        }
        let ui = center.kernel.interaction
        guard
            let name = ui.prompt(
                "Symbol for “\(center.kernel.commands[id]?.title ?? id.rawValue)”:",
                value: editor.symbol(for: id),
                detail:
                    "The name of a system symbol (SF Symbols), such as folder.badge.plus. Empty: the command's own."
            )?
            .trimmingCharacters(in: .whitespaces)
        else { return }
        guard name.isEmpty || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            ui.inform(
                "No symbol is called “\(name)”",
                detail: "The SF Symbols app lists the names.",
                style: .warning
            )
            return
        }
        editor.setSymbol(name, for: id)
        edited(selecting: row)
    }

    func commit() { editor.commit() }

    func discard() {
        editor.discard()
        reload()
    }
}

/// The Start-menu editor (spec 14 › The Change start menu dialog).
final class StartMenuPage: NSObject, OptionsPage {
    private unowned let center: ConfigurationCenter
    private var stored = StartMenuDraft()
    private var draft = StartMenuDraft()
    private let table = RowsTable(columns: [("Nr.", 34), ("Title", 170), ("Command", 190), ("Key", 80)])
    let title = "Start Menu"
    private(set) lazy var view: NSView = editorView(
        table,
        buttons: [
            ActionButton("Add Item…") { [unowned self] in add(center.editStartMenuRow(nil)) },
            ActionButton("Add Command…") { [unowned self] in
                guard let picked = center.pickCommand() else { return }
                add(
                    center.editStartMenuRow(
                        nil,
                        proposing: CommandAction(command: picked.id.rawValue),
                        title: picked.title
                    )
                )
            },
            ActionButton("Add Separator") { [unowned self] in add(StartMenuDraft.Row(entry: .separator)) },
            ActionButton("Change…") { [unowned self] in change() },
            ActionButton("Remove") { [unowned self] in
                guard let row = table.selectedRow else { return center.effects.beep() }
                draft.rows.remove(at: row)
                edited(selecting: row)
            },
            ActionButton("Move Up") { [unowned self] in move(-1) },
            ActionButton("Move Down") { [unowned self] in move(1) }
        ],
        below: [
            note(
                ConfigurationCenter.startMenuHint
                    + "\nThe n-th entry also runs as the command cm_UserMenu<n>. Submenus are not available."
            )
        ]
    )
    var onEdit: (() -> Void)?

    init(center: ConfigurationCenter) {
        self.center = center
        super.init()
        table.onActivate = { [unowned self] in change() }
    }

    var isChanged: Bool { draft != stored }

    private func reload(selecting row: Int? = nil) {
        table.show(
            draft.rows.enumerated()
                .map { index, row in
                    row.entry.isSeparator
                        ? ["\(index + 1)", "———", "", ""]
                        : [
                            "\(index + 1)", row.entry.title, row.entry.action.command,
                            ShortcutText.parse(row.shortcut).map(ShortcutText.display) ?? ""
                        ]
                },
            selecting: row
        )
    }

    private func edited(selecting row: Int?) {
        reload(selecting: row)
        onEdit?()
    }

    private func add(_ row: StartMenuDraft.Row?) {
        guard let row else { return }
        edited(selecting: draft.insert(row, after: table.selectedRow))
    }

    private func change() {
        guard let index = table.selectedRow, draft.rows.indices.contains(index), !draft.rows[index].entry.isSeparator
        else {
            center.effects.beep()
            return
        }
        guard let row = center.editStartMenuRow(draft.rows[index]) else { return }
        draft.rows[index] = row
        edited(selecting: index)
    }

    private func move(_ offset: Int) {
        guard let row = table.selectedRow else {
            center.effects.beep()
            return
        }
        edited(selecting: draft.move(row, by: offset))
    }

    func commit() {
        guard isChanged else { return }
        center.commit(draft)
        discard()
    }

    func discard() {
        stored = center.startMenuDraft()
        draft = stored
        reload()
    }
}

/// Export, import and reset of the settings as a whole (spec 19 › What is saved when, adapted:
/// the Mac keeps settings in the preferences system, not in a file the user can copy).
final class SettingsFilePage: NSObject, OptionsPage {
    let title = "Settings File"
    let view: NSView
    let isChanged = false
    var onEdit: (() -> Void)?

    init(center: ConfigurationCenter) {
        let commands = center.kernel.commands
        let buttons = filledStack(
            [
                ActionButton("Export Settings…") { commands.perform(ConfigurationPlugin.exportSettings) },
                ActionButton("Import Settings…") { commands.perform(ConfigurationPlugin.importSettings) },
                ActionButton("Reset All Settings…") { commands.perform(ConfigurationPlugin.resetSettings) },
                spacer()
            ],
            vertical: false
        )
        view = filledStack(
            [
                NSTextField(
                    wrappingLabelWithString:
                        "Settings are stored the moment they change; there is nothing to save by hand. "
                        + "To keep a copy or to take the settings to another Mac, export them to a file."
                ),
                buttons,
                note(
                    "The file holds the options of all pages, the key bindings, the button bar, the user commands, the Start menu, the directory "
                        + "hotlist and the panels' tabs. Histories (typed command lines, visited folders) and saved connections are in it only if you "
                        + "ask for them; passwords never are. Only you can read the file. Window positions are kept by macOS and are not in it.\n"
                        + "An import shows what it would change first. User commands, key bindings, programs, connections and trusted certificates "
                        + "from a file are taken over only when you tick them."
                ),
                spacer()
            ],
            vertical: true,
            spacing: 12
        )
        super.init()
    }

    func commit() {}
    func discard() {}
}

/// The Options window (spec 13 › The dialog framework): the pages on the left, the selected
/// page on the right, OK, Cancel and Apply below.
///
/// Main thread only.
///
/// Unlike Total Commander's dialog it is not modal, as is usual on the Mac; what is pending on
/// its pages reaches the program only with Apply or OK.
final class OptionsWindowController: NSWindowController, NSWindowDelegate {
    enum Section {
        case first, keyboard, buttonBar, startMenu, settingsFile
    }

    private unowned let center: ConfigurationCenter
    private let pages: [any OptionsPage]
    private let firstOwnPage: Int
    private let pageList = RowsTable(columns: [("", 150)])
    private let caption = NSTextField(labelWithString: "")
    private let container = NSView()
    private var applyButton = NSButton()

    init(center: ConfigurationCenter) {
        self.center = center
        let registered: [any OptionsPage] = center.kernel.preferences.pages.filter { !$0.preferences.isEmpty }
            .map {
                PreferencesPage(model: PreferencePageModel(page: $0, settings: center.kernel.settings))
            }
        firstOwnPage = registered.count
        pages =
            registered + [
                KeyboardPage(center: center), ButtonBarPage(center: center), StartMenuPage(center: center),
                SettingsFilePage(center: center)
            ]
        let window = ToolWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Options"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 420)
        window.center()
        super.init(window: window)
        window.delegate = self
        for page in pages { page.onEdit = { [weak self] in self?.updateApply() } }
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    private func buildContent(in window: NSWindow) {
        pageList.onSelect = { [weak self] in self?.showSelectedPage() }
        pageList.widthAnchor.constraint(equalToConstant: 170).isActive = true
        caption.font = .boldSystemFont(ofSize: 14)
        container.translatesAutoresizingMaskIntoConstraints = false
        let top = filledStack(
            [pageList, filledStack([caption, container], vertical: true, spacing: 10)],
            vertical: false,
            spacing: 14
        )

        let ok = ActionButton("OK") { [unowned self] in
            apply()
            self.window?.close()
        }
        ok.keyEquivalent = "\r"
        applyButton = ActionButton("Apply") { [unowned self] in apply() }
        let bottom = filledStack(
            [spacer(), ActionButton("Cancel") { [unowned self] in self.window?.close() }, applyButton, ok],
            vertical: false
        )
        window.contentView = padded(filledStack([top, bottom], vertical: true, spacing: 12))
    }

    /// Opens the window on a page.
    ///
    /// A window that was closed shows what is stored now.
    func show(_ section: Section) {
        prepare(section)
        center.effects.present(self)
    }

    var pageTitles: [String] { pages.map(\.title) }
    var shownPage: String { caption.stringValue }

    /// Everything `show` does short of putting the window on screen.
    func prepare(_ section: Section) {
        if window?.isVisible != true {
            pages.forEach { $0.discard() }
            pageList.show(pages.map { [$0.title] })
        }
        let index: Int
        switch section {
        case .first: index = pageList.selectedRow ?? 0
        case .keyboard: index = firstOwnPage
        case .buttonBar: index = firstOwnPage + 1
        case .startMenu: index = firstOwnPage + 2
        case .settingsFile: index = firstOwnPage + 3
        }
        pageList.selectedRow = index
        showSelectedPage()
        updateApply()
    }

    private func showSelectedPage() {
        // (The list has a row for every page.)
        guard let page = pageList.selectedRow.flatMap({ pages.dropFirst($0).first }) else { return }
        caption.stringValue = page.title
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = page.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    /// Apply is offered once something was changed (spec 13 › Buttons, applying changes).
    private func updateApply() {
        applyButton.isEnabled = pages.contains(where: \.isChanged)
    }

    private func apply() {
        window?.makeFirstResponder(nil)
        // Each page stores what was changed on it, if anything.
        for page in pages { page.commit() }
        updateApply()
    }

    /// Closing by Cancel, Esc or the close button drops what was not applied.
    func windowWillClose(_: Notification) {
        pages.forEach { $0.discard() }
    }
}
