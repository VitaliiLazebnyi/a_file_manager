import AFMContracts
import AFMKernel
import AFMShell
import AppKit

/// What the configuration windows and commands share: the user's commands and Start menu, the
/// key bindings, and the settings as a whole.
///
/// Main thread only.
@MainActor
internal final class ConfigurationCenter {
    /// What the editors of Start-menu entries and user commands say about the parameters.
    internal static let startMenuHint = """
        ? as the first parameter: asks for the parameters before the command runs
        %P source path   %T target path   %N name under the cursor   %S selected names
        %L a file listing the selected names with their paths   %% the percent sign
        """

    /// The program the windows and commands work on.
    internal unowned let kernel: Kernel
    /// The plugin's own settings: user commands, Start menu, pictures.
    internal let store: ConfigurationStore
    /// What runs user commands and Start-menu entries.
    internal let runner: CommandRunner
    /// The settings keys the store can list, for export and reset.
    private let enumeratedKeys: () -> [String]
    /// How many `cm_UserMenu<n>` commands are registered.
    private var slotCount = 0
    /// The Options window, made when it is first asked for.
    internal var optionsWindow: OptionsWindowController?
    /// The command browser, made when it is first asked for.
    internal var browserWindow: CommandBrowserController?
    /// The text windows that are open, by their title.
    internal var textWindows: [String: TextWindowController] = [:]
    /// Told when key bindings were stored from outside the Keyboard page, which then takes them over.
    internal var keysCommitted: (() -> Void)?
    /// The beep, the modal run of the command picker and the settings file panel.
    internal var effects: ConfigurationEffects
    /// What the items of the Start menu in the menu bar run through.
    private lazy var startMenuTarget = StartMenuTarget(kernel: kernel)

    /// The center of a plugin's windows and commands; registers nothing yet.
    internal init(
        kernel: Kernel,
        runner: CommandRunner,
        effects: ConfigurationEffects,
        enumeratedKeys: @escaping () -> [String]
    ) {
        self.kernel = kernel
        self.runner = runner
        self.effects = effects
        self.enumeratedKeys = enumeratedKeys
        store = ConfigurationStore(settings: kernel.settings)
        runner.userCommand = { [weak self] name in self?.userCommand(named: name) }
        runner.startMenuEntry = { [weak self] id in self?.startMenuEntry(named: id) }
        // The problem is told later, from the run loop: by then the kernel may be gone.
        store.onProblem = { [weak kernel] message in
            kernel?.interaction.inform("Some settings could not be read", detail: message, style: .warning)
        }
    }

    // MARK: User commands

    /// The user command of this name; nil when there is none.
    internal func userCommand(named name: String) -> UserCommand? {
        store.userCommand(named: name)
    }

    /// Makes a user command a command of the program.
    ///
    /// It looks its definition up when it runs, so a later change takes effect at once; its title
    /// in menus is the one it started with.
    internal func register(_ command: UserCommand) {
        let name = command.name
        guard kernel.commands[command.id] == nil else {
            return
        }
        kernel.commands.register(
            Command(command.id, DisplayText.oneLine(command.caption, limit: 120)),
            enabled: { [weak self] in self?.userCommand(named: name) != nil },
            parameterized: { [weak self] argument in self?.runUserCommand(named: name, with: argument) }
        )
    }

    /// Runs the user command of this name with what was written after it.
    private func runUserCommand(named name: String, with argument: CommandArgument) {
        // (The registry runs only an enabled command: the definition is there.)
        if let command = userCommand(named: name) {
            runner.run(
                command.action,
                arguments: argument.text ?? "",
                as: name,
                title: command.caption,
                completion: nil
            )
        }
    }

    /// Stores a new or changed user command under its name.
    internal func save(_ command: UserCommand) {
        save(command, replacing: nil)
    }

    /// Stores a new or changed user command; `oldName` is the one it replaces when it was renamed.
    internal func save(_ command: UserCommand, replacing oldName: String?) {
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

    /// Deletes the user command of this name, and the keys bound to it.
    internal func removeUserCommand(named name: String) {
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

    /// Shows the picture a user command brings on the button bar, unless the user chose another.
    private func applySymbol(of command: UserCommand) {
        guard !command.symbol.isEmpty, store.symbols[command.name] == nil else {
            return
        }
        kernel.toolbar.setSymbol(command.symbol, for: command.id)
        kernel.toolbar.onChange?()
    }

    // MARK: Start menu

    /// Registers `cm_UserMenu1` … for every position there is, and at least the ten the
    /// specification names (17 › User).
    ///
    /// A command runs whatever entry is at its position now.
    internal func ensureSlots(_ count: Int) {
        let entries = store.startMenu
        while slotCount < max(10, min(count, ConfigurationStore.startMenuLimit)) {
            let index = slotCount
            let title =
                entries.indices.contains(index) && !entries[index].isSeparator
                ? entries[index].title : "Start Menu Item \(index + 1)"
            kernel.commands.register(
                Command(
                    StartMenuEntry.commandID(at: index),
                    DisplayText.oneLine(title.replacingOccurrences(of: "&", with: ""), limit: 120)
                ),
                enabled: { [weak self] in self?.startMenuEntry(at: index) != nil },
                parameterized: { [weak self] argument in self?.runStartMenuEntry(at: index, with: argument) }
            )
            slotCount += 1
        }
    }

    /// The entry a `cm_UserMenu<n>` runs; nil for another name, a separator or a place past the end.
    private func startMenuEntry(named id: String) -> StartMenuEntry? {
        let prefix = "cm_UserMenu"
        guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number >= 1 else {
            return nil
        }
        return startMenuEntry(at: number - 1)
    }

    /// The entry at `index` of the Start menu as it is now; nil for a separator or a place past the end.
    private func startMenuEntry(at index: Int) -> StartMenuEntry? {
        let entries = store.startMenu
        return entries.indices.contains(index) && !entries[index].isSeparator ? entries[index] : nil
    }

    /// Runs the entry at `index` with what was written after its name.
    private func runStartMenuEntry(at index: Int, with argument: CommandArgument) {
        // (The registry runs only an enabled command: the entry is there.)
        if let entry = startMenuEntry(at: index) {
            runner.run(
                entry.action,
                arguments: argument.text ?? "",
                as: StartMenuEntry.commandID(at: index).rawValue,
                title: entry.title,
                completion: nil
            )
        }
    }

    /// Stores the edited Start menu with its keys and shows it in the menu bar.
    internal func commit(_ draft: StartMenuDraft) {
        let oldCount = store.startMenu.count
        store.startMenu = draft.rows.map(\.entry)
        ensureSlots(draft.rows.count)
        let editor = KeyBindingEditor(kernel: kernel)
        for index in 0..<max(oldCount, draft.rows.count) { editor.reset(StartMenuEntry.commandID(at: index)) }
        for (index, row) in draft.rows.enumerated() where !row.entry.isSeparator {
            guard let shortcut = ShortcutText.parse(row.shortcut) else { continue }
            editor.assign(shortcut, to: StartMenuEntry.commandID(at: index), adding: false, asking: kernel.interaction)
        }
        commitKeys(editor)
        refreshMenus()
    }

    // MARK: Keys

    /// Gives a command the key written in `text` as its only key, or none for an empty text.
    ///
    /// Returns false when the text is not a shortcut or the user left the key with its owner.
    @discardableResult
    internal func setShortcut(_ text: String, for command: CommandID) -> Bool {
        let editor = KeyBindingEditor(kernel: kernel)
        let written = text.trimmingCharacters(in: .whitespaces)
        if written.isEmpty {
            guard !editor.shortcuts(for: command).isEmpty else {
                return true
            }
            editor.set([], for: command)
        } else if let shortcut = ShortcutText.parse(written) {
            guard editor.assign(shortcut, to: command, adding: false, asking: kernel.interaction) else {
                return false
            }
        } else {
            kernel.interaction.inform(
                "“\(written)” is not a shortcut",
                detail: "Write it like ctrl+shift+n or f9.",
                style: .warning
            )
            return false
        }
        commitKeys(editor)
        refreshMenus()
        return true
    }

    /// Brings the menu bar in line with the key bindings and the Start menu.
    ///
    /// The shell builds its menus once; this changes the items in place.
    internal func refreshMenus() {
        guard let menu = effects.mainMenu() else {
            return
        }
        LiveMenus.rebuildStartMenu(in: menu, entries: store.startMenu, target: startMenuTarget)
        LiveMenus.refreshKeys(in: menu, kernel: kernel)
    }

    // MARK: Settings as a whole

    /// Every settings key that can be known: the preferences of all pages, the key bindings,
    /// the button bar, the panels' tabs, this plugin's own, and whatever the store can list.
    internal func settingsKeys() -> [String] {
        var keys = kernel.preferences.pages.flatMap { $0.preferences.map(\.key) }
        keys += [
            KeyBindings.settingsKey, ToolbarRegistry.settingsKey, ListingCache.settingsKey, "listingCache.readAhead",
            "left.tabs", "right.tabs"
        ]
        keys += ConfigurationStore.keys + enumeratedKeys()
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// Makes the running program follow settings that were replaced as a whole, as far as that
    /// is possible without a restart.
    internal func applyStoredSettings() {
        store.invalidate()
        kernel.listingCache.isEnabled = kernel.settings.flag(ListingCache.settingsKey, default: true)
        store.userCommands.forEach(register)
        ensureSlots(store.startMenu.count)
        KeyBindingEditor.reapply(in: kernel)
        keysCommitted?()
        applySymbols()
        for page in kernel.preferences.pages { page.onChange() }
        kernel.toolbar.onChange?()
        refreshMenus()
    }

    /// The pictures the user chose replace the plugins' (spec 14 › Button bars).
    internal func applySymbols() {
        for command in store.userCommands where !command.symbol.isEmpty {
            kernel.toolbar.setSymbol(command.symbol, for: command.id)
        }
        for (name, symbol) in store.symbols { kernel.toolbar.setSymbol(symbol, for: CommandID(rawValue: name)) }
    }

    /// Writes down now what the shell writes when the program quits: the panels' tabs and
    /// directories (spec 19 › Save Position, Save Settings).
    ///
    /// Everything else is stored the moment it changes.
    internal func saveSettingsNow() {
        kernel.settings.set(kernel.panels.left.tabs.state, forKey: "left.tabs")
        kernel.settings.set(kernel.panels.right.tabs.state, forKey: "right.tabs")
        savePosition()
    }

    /// Stores where the windows are, and has the preferences written to disk off the main thread.
    internal func savePosition() {
        for window in effects.windows() where !window.frameAutosaveName.isEmpty {
            window.saveFrame(usingName: window.frameAutosaveName)
        }
        // Handing the preferences to the system's store is a call to another process: not here.
        runner.offMain(
            { UserDefaults.standard.synchronize() },
            then: { _ in
                // Nothing waits for it.
            }
        )
    }

    // MARK: Command list

    /// Every command of the program with its menu and its keys, for the command browser.
    internal func commandRows() -> [CommandRow] {
        CommandCatalog.rows(
            commands: kernel.commands.all,
            menus: kernel.menus.menus,
            shortcuts: kernel.keyBindings.shortcuts(for:)
        )
    }

    deinit {
        // Nothing to release.
    }
}
