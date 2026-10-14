import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// What the configuration windows and commands share: the user's commands and Start menu, the
/// key bindings, and the settings as a whole. Main thread only.
final class ConfigurationCenter {
    unowned let kernel: Kernel
    let store: ConfigurationStore
    let runner: CommandRunner
    private let enumeratedKeys: () -> [String]
    private var slotCount = 0
    /// The windows, made when they are first asked for.
    var optionsWindow: OptionsWindowController?
    var browserWindow: CommandBrowserController?
    var textWindows: [String: TextWindowController] = [:]
    /// Told when key bindings were stored from outside the Keyboard page, which then takes them over.
    var keysCommitted: (() -> Void)?
    private lazy var startMenuTarget = StartMenuTarget(kernel: kernel)

    static let startMenuHint = """
        ? as the first parameter: asks for the parameters before the command runs
        %P source path   %T target path   %N name under the cursor   %S selected names
        %L a file listing the selected names with their paths   %% the percent sign
        """

    init(kernel: Kernel, runner: CommandRunner, enumeratedKeys: @escaping () -> [String]) {
        self.kernel = kernel
        self.runner = runner
        self.enumeratedKeys = enumeratedKeys
        store = ConfigurationStore(settings: kernel.settings)
        runner.userCommand = { [unowned self] in userCommand(named: $0) }
        runner.startMenuEntry = { [unowned self] id in
            let prefix = "cm_UserMenu"
            guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number >= 1 else { return nil }
            let entries = store.startMenu
            return entries.indices.contains(number - 1) && !entries[number - 1].isSeparator ? entries[number - 1] : nil
        }
        store.onProblem = { [unowned kernel] in
            kernel.ui.inform("Some settings could not be read", detail: $0, style: .warning)
        }
    }

    // MARK: User commands

    func userCommand(named name: String) -> UserCommand? {
        store.userCommand(named: name)
    }

    /// Makes a user command a command of the program. It looks its definition up when it runs,
    /// so a later change takes effect at once; its title in menus is the one it started with.
    func register(_ command: UserCommand) {
        let name = command.name
        guard kernel.commands[command.id] == nil else { return }
        kernel.commands.register(
            Command(command.id, DisplayText.oneLine(command.caption, limit: 120)),
            enabled: { [unowned self] in userCommand(named: name) != nil },
            parameterized: { [unowned self] argument in
                guard let current = userCommand(named: name) else { return }
                runner.run(current.action, arguments: argument.text ?? "", as: name, title: current.caption)
            })
    }

    /// Stores a new or changed user command; `oldName` is the one it replaces when it was renamed.
    func save(_ command: UserCommand, replacing oldName: String? = nil) {
        var commands = store.userCommands
        if let index = commands.firstIndex(where: { $0.name == oldName ?? command.name }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
        store.userCommands = commands
        register(command)
        applySymbol(of: command)
        if let oldName, oldName != command.name { pruneDeadKeys() }
    }

    func removeUserCommand(named name: String) {
        store.userCommands = store.userCommands.filter { $0.name != name }
        pruneDeadKeys()
    }

    /// A deleted or renamed user command leaves no key binding behind.
    private func pruneDeadKeys() {
        let live = Set(store.userCommands.map(\.name))
        let editor = KeyBindingEditor(kernel: kernel)
        editor.discardOverrides { $0.hasPrefix(UserCommand.prefix) && !live.contains($0) }
        if editor.isChanged { commitKeys(editor) }
    }

    /// Stores and applies the bindings of an editor made here, and lets the Keyboard page know.
    private func commitKeys(_ editor: KeyBindingEditor) {
        editor.commit(to: kernel.settings, keyBindings: kernel.keyBindings)
        keysCommitted?()
    }

    private func applySymbol(of command: UserCommand) {
        guard !command.symbol.isEmpty, store.symbols[command.name] == nil else { return }
        kernel.toolbar.setSymbol(command.symbol, for: command.id)
        kernel.toolbar.onChange?()
    }

    /// The definition dialog of a user command (spec 14 › Defining). Nil when the user gave
    /// up or the name cannot be used.
    func editUserCommand(_ existing: UserCommand?, proposing action: CommandAction = CommandAction()) -> UserCommand? {
        let action = existing?.action ?? action
        let keys = existing.map { kernel.keyBindings.shortcuts(for: $0.id) } ?? []
        let fields: [FormField] = [
            .text("name", "Name:  em_", existing.map { String($0.name.dropFirst(UserCommand.prefix.count)) } ?? ""),
            .text("title", "Title:", existing?.title ?? ""),
            .text("command", "Command:", action.command),
            .text("parameters", "Parameters:", action.parameters),
            .text("path", "Start path:", action.startPath),
            .text("shortcut", "Shortcut:", keys.first?.notation ?? ""),
            .text("symbol", "Symbol:", existing?.symbol ?? ""),
            .note(
                "Command: a command of the program (cm_…, several separated by commas), cd <folder>, or a program or shell line.\n"
                    + "Shortcut: for example ctrl+shift+n or f9.  Symbol: the name of a system symbol for the button bar.\n"
                    + ConfigurationCenter.startMenuHint)
        ]
        guard let answer = kernel.ui.form(existing == nil ? "New User Command" : "Edit User Command", fields: fields)
        else { return nil }
        guard let name = UserCommand.name(from: answer.text("name")) else {
            kernel.ui.inform(
                "The command needs a name", detail: "Use letters, digits and the underscore.", style: .warning)
            return nil
        }
        if name != existing?.name, userCommand(named: name) != nil {
            kernel.ui.inform(
                "\(name) exists already", detail: "Choose another name, or edit that command.", style: .warning)
            return nil
        }
        let command = UserCommand(
            name: name, title: answer.text("title").trimmingCharacters(in: .whitespaces),
            action: CommandAction(
                command: answer.text("command").trimmingCharacters(in: .whitespaces),
                parameters: answer.text("parameters"),
                startPath: answer.text("path").trimmingCharacters(in: .whitespaces)),
            symbol: answer.text("symbol").trimmingCharacters(in: .whitespaces))
        save(command, replacing: existing?.name)
        if answer.text("shortcut") != (keys.first?.notation ?? "") || name != existing?.name {
            setShortcut(answer.text("shortcut"), for: command.id)
        }
        return command
    }

    // MARK: Start menu

    /// The Start menu with the keys its entries have now.
    func startMenuDraft() -> StartMenuDraft {
        StartMenuDraft(
            rows: store.startMenu.enumerated().map { index, entry in
                StartMenuDraft.Row(
                    entry: entry,
                    shortcut: kernel.keyBindings.shortcuts(for: StartMenuEntry.commandID(at: index)).first?.notation
                        ?? "")
            })
    }

    /// Registers `cm_UserMenu1` … for every position there is, and at least the ten the
    /// specification names (17 › User). A command runs whatever entry is at its position now.
    func ensureSlots(_ count: Int) {
        let entries = store.startMenu
        while slotCount < max(10, min(count, ConfigurationStore.startMenuLimit)) {
            let index = slotCount
            let title =
                entries.indices.contains(index) && !entries[index].isSeparator
                ? entries[index].title : "Start Menu Item \(index + 1)"
            func entry() -> StartMenuEntry? {
                let current = store.startMenu
                return current.indices.contains(index) && !current[index].isSeparator ? current[index] : nil
            }
            kernel.commands.register(
                Command(
                    StartMenuEntry.commandID(at: index),
                    DisplayText.oneLine(title.replacingOccurrences(of: "&", with: ""), limit: 120)),
                enabled: { entry() != nil },
                parameterized: { [unowned self] argument in
                    guard let entry = entry() else { return }
                    runner.run(
                        entry.action, arguments: argument.text ?? "", as: StartMenuEntry.commandID(at: index).rawValue,
                        title: entry.title)
                })
            slotCount += 1
        }
    }

    /// The entries as the menu registry takes them at start-up: one section per run of entries
    /// between separators.
    func startMenuSections() -> [[CommandID]] {
        var sections: [[CommandID]] = [[]]
        for (index, entry) in store.startMenu.enumerated() {
            if entry.isSeparator {
                sections.append([])
            } else {
                sections[sections.count - 1].append(StartMenuEntry.commandID(at: index))
            }
        }
        return sections.filter { !$0.isEmpty }
    }

    /// Stores the edited Start menu with its keys and shows it in the menu bar.
    func commit(_ draft: StartMenuDraft) {
        let oldCount = store.startMenu.count
        store.startMenu = draft.rows.map(\.entry)
        ensureSlots(draft.rows.count)
        let editor = KeyBindingEditor(kernel: kernel)
        for index in 0..<max(oldCount, draft.rows.count) { editor.reset(StartMenuEntry.commandID(at: index)) }
        for (index, row) in draft.rows.enumerated() where !row.entry.isSeparator {
            guard let shortcut = ShortcutText.parse(row.shortcut) else { continue }
            editor.assign(shortcut, to: StartMenuEntry.commandID(at: index), adding: false, asking: kernel.ui)
        }
        commitKeys(editor)
        refreshMenus()
    }

    /// The dialog of one Start-menu entry (spec 14 › The Change start menu dialog).
    func editStartMenuRow(
        _ row: StartMenuDraft.Row?, proposing action: CommandAction = CommandAction(), title: String = ""
    ) -> StartMenuDraft.Row? {
        let action = row?.entry.action ?? action
        let fields: [FormField] = [
            .text("title", "Title:", row?.entry.title ?? title),
            .text("command", "Command:", action.command),
            .text("parameters", "Parameters:", action.parameters),
            .text("path", "Start path:", action.startPath),
            .text("shortcut", "Shortcut key:", row?.shortcut ?? ""),
            .note(ConfigurationCenter.startMenuHint)
        ]
        guard
            let answer = kernel.ui.form(row == nil ? "Add Start Menu Item" : "Change Start Menu Item", fields: fields)
        else { return nil }
        let title = answer.text("title").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        var shortcut = answer.text("shortcut").trimmingCharacters(in: .whitespaces)
        if !shortcut.isEmpty, ShortcutText.parse(shortcut) == nil {
            kernel.ui.inform(
                "“\(shortcut)” is not a shortcut", detail: "Write it like ctrl+shift+n or f9.", style: .warning)
            shortcut = ""
        }
        let entry = StartMenuEntry(
            title: title,
            action: CommandAction(
                command: answer.text("command").trimmingCharacters(in: .whitespaces),
                parameters: answer.text("parameters"),
                startPath: answer.text("path").trimmingCharacters(in: .whitespaces)))
        return StartMenuDraft.Row(entry: entry, shortcut: ShortcutText.parse(shortcut)?.notation ?? "")
    }

    // MARK: Keys

    /// Gives a command the key written in `text` as its only key, or none for an empty text.
    /// Returns false when the text is not a shortcut or the user left the key with its owner.
    @discardableResult
    func setShortcut(_ text: String, for command: CommandID) -> Bool {
        let editor = KeyBindingEditor(kernel: kernel)
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard !editor.shortcuts(for: command).isEmpty else { return true }
            editor.set([], for: command)
        } else if let shortcut = ShortcutText.parse(text) {
            guard editor.assign(shortcut, to: command, adding: false, asking: kernel.ui) else { return false }
        } else {
            kernel.ui.inform(
                "“\(text)” is not a shortcut", detail: "Write it like ctrl+shift+n or f9.", style: .warning)
            return false
        }
        commitKeys(editor)
        refreshMenus()
        return true
    }

    /// Brings the menu bar in line with the key bindings and the Start menu. The shell builds
    /// its menus once; this changes the items in place.
    func refreshMenus() {
        guard let menu = NSApp?.mainMenu else { return }
        LiveMenus.rebuildStartMenu(in: menu, entries: store.startMenu, target: startMenuTarget)
        LiveMenus.refreshKeys(in: menu, kernel: kernel)
    }

    // MARK: Settings as a whole

    /// Every settings key that can be known: the preferences of all pages, the key bindings,
    /// the button bar, the panels' tabs, this plugin's own, and whatever the store can list.
    func settingsKeys() -> [String] {
        var keys = kernel.preferences.pages.flatMap { $0.preferences.map(\.key) }
        keys += [
            KeyBindings.settingsKey, ToolbarRegistry.settingsKey, ListingCache.settingsKey, "listingCache.readAhead",
            "left.tabs", "right.tabs"
        ]
        keys += ConfigurationStore.keys + enumeratedKeys()
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// What is known about the settings now, for import and export.
    func settingsSchema() -> SettingsSchema {
        var schema = SettingsSchema()
        for preference in kernel.preferences.pages.flatMap(\.preferences) {
            schema.preferences[preference.key] = preference.kind
        }
        schema.known = Set(settingsKeys())
        let declared = kernel.settingsKeys
        schema.declaredKind = { declared.kind(of: $0) }
        return schema
    }

    /// Asks what an export is to hold besides the settings themselves. Nil when the user gave up.
    func askExportOptions() -> SettingsExportOptions? {
        let fields: [FormField] = [
            .note(
                "The file holds the options of all pages, the key bindings, the button bar, the user commands, the Start menu, the directory "
                    + "hotlist and the panels' tabs. Passwords are never in it, and only you can read the file."),
            .checkbox("history", "Also include " + SettingsExportOptions.historyNote),
            .checkbox("connections", "Also include " + SettingsExportOptions.connectionsNote)
        ]
        guard let answer = kernel.ui.form("Export Settings", detail: "", fields: fields, buttons: ["Export…"]) else {
            return nil
        }
        return SettingsExportOptions(
            includesHistory: answer.flag("history"), includesConnections: answer.flag("connections"))
    }

    /// Writes the settings to a file only the user can read. What the user did rather than set
    /// up (histories), and the servers the user connects to, are in it only when `options` says so.
    func exportSettings(
        to url: URL, options: SettingsExportOptions = SettingsExportOptions(), tellsWhatIsIncluded: Bool = true
    ) {
        let keys = options.included(settingsKeys(), schema: settingsSchema())
        let archive = SettingsArchive.capture(from: kernel.settings, keys: keys)
        runner.offMain(
            { Result { try archive.write(to: url) } },
            then: { [self] result in
                switch result {
                case .failure(let error): kernel.ui.report(error, title: "The settings could not be exported")
                case .success:
                    if tellsWhatIsIncluded {
                        kernel.ui.inform(
                            "The settings were exported", detail: options.description(count: archive.values.count),
                            style: .information)
                    }
                }
            })
    }

    /// Reads a settings file, checks it, shows what it would change and stores it when the
    /// user agrees. What can run programs, rebind keys or change whom the program trusts is
    /// stored only when the user ticks it. Nothing is ever imported without this question,
    /// whoever asked for the import.
    func importSettings(from url: URL) {
        let schema = settingsSchema()
        let knownKeys = settingsKeys()
        runner.offMain(
            { Result { try CheckedSettings(SettingsArchive(data: CheckedSettings.read(url)), schema: schema) } },
            then: { [self] result in
                switch result {
                case .failure(let error):
                    kernel.ui.report(error, title: "The settings could not be imported")
                case .success(let checked):
                    var current: [String: Data] = [:]
                    for key in Set(knownKeys).union(checked.values.keys) {
                        current[key] = kernel.settings.data(forKey: key)
                    }
                    runner.offMain(
                        { SettingsImportPlan(checked, current: current, knownKeys: knownKeys, schema: schema) },
                        then: { [self] plan in
                            confirmAndApply(plan, fileName: url.lastPathComponent)
                        })
                }
            })
    }

    private func confirmAndApply(_ plan: SettingsImportPlan, fileName: String) {
        guard !plan.isEmpty else {
            return kernel.ui.inform("Nothing to import", detail: plan.summary(fileName: fileName), style: .information)
        }
        var fields: [FormField] = [.note(plan.summary(fileName: fileName))]
        for part in plan.parts {
            fields.append(.checkbox(part.group.rawValue, part.title, false))
            fields.append(.lines(part.group.rawValue + ".contents", "", part.lines.joined(separator: "\n")))
        }
        guard let answer = kernel.ui.form("Import Settings", detail: "", fields: fields, buttons: ["Import"]) else {
            return
        }
        let accepted = Set(plan.parts.map(\.group).filter { answer.flag($0.rawValue) })
        plan.apply(to: kernel.settings, accepting: accepted)
        applyStoredSettings()
        let skipped = plan.parts.filter { !accepted.contains($0.group) }.count
        kernel.ui.inform(
            "The settings were imported",
            detail: (skipped > 0 ? "\(skipped) parts were not ticked and stay as they were. " : "")
                + "Some settings take effect when the program is started again.", style: .information)
    }

    /// Removes every known setting after asking; returns whether it did.
    @discardableResult
    func resetSettings() -> Bool {
        let answer = kernel.ui.choose(
            "Reset all settings?",
            detail: "Options, key bindings, the button bar, user commands and the Start menu "
                + "go back to how the program came. Export the settings first to keep them.",
            buttons: ["Reset", "Cancel"], style: .critical)
        guard answer == 0 else { return false }
        SettingsArchive().restore(into: kernel.settings, replacing: settingsKeys())
        applyStoredSettings()
        return true
    }

    /// Makes the running program follow settings that were replaced as a whole, as far as that
    /// is possible without a restart.
    func applyStoredSettings() {
        store.invalidate()
        kernel.listingCache.isEnabled = kernel.settings.flag(ListingCache.settingsKey, default: true)
        store.userCommands.forEach(register)
        ensureSlots(store.startMenu.count)
        KeyBindingEditor.reapply(in: kernel)
        keysCommitted?()
        applySymbols()
        kernel.preferences.pages.forEach { $0.onChange() }
        kernel.toolbar.onChange?()
        refreshMenus()
    }

    /// The pictures the user chose replace the plugins' (spec 14 › Button bars).
    func applySymbols() {
        for command in store.userCommands where !command.symbol.isEmpty {
            kernel.toolbar.setSymbol(command.symbol, for: command.id)
        }
        for (name, symbol) in store.symbols { kernel.toolbar.setSymbol(symbol, for: CommandID(rawValue: name)) }
    }

    /// Writes down now what the shell writes when the program quits: the panels' tabs and
    /// directories (spec 19 › Save Position, Save Settings). Everything else is stored the
    /// moment it changes.
    func saveSettingsNow() {
        kernel.settings.set(kernel.panels.left.tabs.state, forKey: "left.tabs")
        kernel.settings.set(kernel.panels.right.tabs.state, forKey: "right.tabs")
        savePosition()
    }

    func savePosition() {
        for window in NSApp?.windows ?? [] where !window.frameAutosaveName.isEmpty {
            window.saveFrame(usingName: window.frameAutosaveName)
        }
        // Handing the preferences to the system's store is a call to another process: not here.
        runner.offMain({ UserDefaults.standard.synchronize() }, then: { _ in })
    }

    // MARK: Command list

    func commandRows() -> [CommandRow] {
        CommandCatalog.rows(
            commands: kernel.commands.all, menus: kernel.menus.menus, shortcuts: kernel.keyBindings.shortcuts(for:))
    }
}
