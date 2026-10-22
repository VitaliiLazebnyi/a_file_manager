import AFMContracts
public import AFMKernel
import AFMShell
public import AppKit

/// The configuration dialog, hotkeys, button bar and user commands (spec 13, 14), the settings
/// as a whole (spec 19 › What is saved when) and the Help menu.
///
/// It is loaded last, so the commands of every other plugin exist when it starts; the user's
/// commands and Start-menu entries are registered then, like any plugin's commands.
/// The program's language is English: Total Commander's language files (spec 16) are Windows
/// resources and are not taken over.
public final class ConfigurationPlugin: Plugin {
    private static let listsParent = FileManager.default.temporaryDirectory.appendingPathComponent("AFileManager-lists")

    // Commands only this plugin has (spec 17 › Configuration, Help, User).
    internal static let redefineHotkeys: CommandID = "cm_Confirmation"
    internal static let buttonBarConfig: CommandID = "cm_ButtonConfig"
    internal static let changeStartMenu: CommandID = "cm_ChangeStartMenu"
    internal static let commandBrowser: CommandID = "cm_CommandBrowser"
    internal static let userCommands: CommandID = "afm_UserCommands"
    internal static let newUserCommand: CommandID = "afm_NewUserCommand"
    internal static let savePosition: CommandID = "cm_ConfigSavePos"
    internal static let saveSettings: CommandID = "cm_ConfigSaveSettings"
    internal static let exportSettings: CommandID = "afm_ExportSettings"
    internal static let importSettings: CommandID = "afm_ImportSettings"
    internal static let resetSettings: CommandID = "afm_ResetSettings"
    internal static let stopUserCommands: CommandID = "afm_StopUserCommands"
    internal static let keyboardHelp: CommandID = "cm_Keyboard"
    internal static let helpIndex: CommandID = "cm_HelpIndex"
    internal static let about: CommandID = "cm_About"

    public let name = "Configuration"
    private let launchesApplications: Bool
    private let background: DispatchQueue?
    private let listFolder: URL
    private let sweepsStaleFolders: Bool
    private let settingsKeys: (() -> [String])?
    internal private(set) var center: ConfigurationCenter?

    /// The lines of user commands that were started without a command-line plugin.
    public var launched: [String] { center?.runner.launched ?? [] }

    /// Tests turn `launchesApplications` off and pass no `background` queue, so nothing is
    /// started, nothing sounds or asks for a file (`ConfigurationEffects.silent`), and
    /// everything happens at once; they also say where list files go.
    /// `settingsKeys` lists the keys the settings store holds, for export and reset; by
    /// default they are read from the macOS preferences of the program.
    public init(
        launchesApplications: Bool = true,
        background: DispatchQueue? = .global(qos: .userInitiated),
        listFolder: URL? = nil,
        settingsKeys: (() -> [String])? = nil
    ) {
        self.launchesApplications = launchesApplications
        self.background = background
        // Lists of this process go to a folder of its own, so another running instance is left alone.
        self.listFolder = listFolder ?? Self.listsParent.appendingPathComponent(String(getpid()))
        sweepsStaleFolders = listFolder == nil
        self.settingsKeys = settingsKeys
    }

    /// The keys of the values the program itself stored in the macOS preferences.
    ///
    /// Only the real settings store is listed this way; any other store has no list of its keys.
    internal static func storedKeys(of settings: any SettingsStore) -> [String] {
        storedKeys(of: settings, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    }

    /// The same, with the preferences kept in `domain` (the program's own is named by its
    /// bundle identifier); nothing is listed before anything was stored there.
    internal static func storedKeys(of settings: any SettingsStore, domain: String) -> [String] {
        guard settings is UserDefaultsSettings else {
            return []
        }
        return storedKeys(in: UserDefaults.standard.persistentDomain(forName: domain) ?? [:])
    }

    /// The keys of a preferences domain whose values the program stored.
    internal static func storedKeys(in values: [String: Any]) -> [String] {
        // The program stores every value as JSON text. Whether it is one is told by how it
        // begins: reading a large value through would hold up the main thread.
        let beginnings = Set("{[\"-0123456789tfn".utf8)
        return
            values.compactMap { key, value in
                guard let data = value as? Data,
                    let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }),
                    beginnings.contains(first)
                else { return nil }
                return key
            }
            .sorted()
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let runner = CommandRunner(
            kernel: kernel,
            launchesApplications: launchesApplications,
            background: background,
            listFolder: listFolder
        )
        let keys = settingsKeys ?? { [unowned kernel] in Self.storedKeys(of: kernel.settings) }
        let center = ConfigurationCenter(
            kernel: kernel,
            runner: runner,
            effects: launchesApplications ? .system : .silent,
            enumeratedKeys: keys
        )
        self.center = center
        runner.removeListFiles()
        if sweepsStaleFolders {
            let parent = Self.listsParent
            runner.offMain({ CommandRunner.removeStaleListFolders(in: parent) }, then: { _ in })
        }

        registerWindows(center, in: kernel)
        registerSettingsCommands(center, in: kernel)

        // The user's own commands and Start menu.
        center.store.userCommands.forEach(center.register)
        center.ensureSlots(center.store.startMenu.count)
        center.applySymbols()
        for (index, section) in center.startMenuSections().enumerated() {
            kernel.menus.add(section, to: MenuSection(.start, order: 10 + index))
        }
        kernel.menus.add(
            [Self.changeStartMenu, Self.stopUserCommands],
            to: MenuSection(.start, order: 10_000)
        )
    }

    private func registerWindows(_ center: ConfigurationCenter, in kernel: Kernel) {
        let commands = kernel.commands
        func window(_ id: CommandID, _ title: String, _ shortcuts: [Shortcut] = [], _ open: @escaping () -> Void) {
            commands.register(Command(id, title, shortcuts, runsDuringJobs: true), open)
        }
        window(.configuration, "Options…", [.cmd(",")]) { center.showOptions(.first) }
        window(Self.redefineHotkeys, "Redefine Hotkeys…") { center.showOptions(.keyboard) }
        window(Self.buttonBarConfig, "Button Bar…") { center.showOptions(.buttonBar) }
        window(Self.changeStartMenu, "Change Start Menu…") { center.showOptions(.startMenu) }
        window(Self.commandBrowser, "Choose Command…") { center.browser().show() }
        window(Self.userCommands, "User Commands…") {
            center.browser().show(category: CommandRow.userCategory)
        }
        window(Self.newUserCommand, "New User Command…") { _ = center.editUserCommand(nil) }
        window(Self.keyboardHelp, "Keyboard Shortcuts") {
            center.showText(center.keyboardHelp(), title: "Keyboard Shortcuts")
        }
        window(Self.helpIndex, "What Is Where") {
            center.showText(center.whatIsWhere(), title: "What Is Where")
        }
        window(Self.about, "About \(kernel.productName)") { center.effects.showAbout() }

        kernel.menus.add([.configuration], to: .configurationOptions)
        kernel.menus.add(
            [
                Self.redefineHotkeys, Self.buttonBarConfig,
                Self.commandBrowser,
                Self.userCommands, Self.newUserCommand
            ],
            to: .configurationCustomize
        )
        kernel.menus.add(
            [Self.helpIndex, Self.keyboardHelp, Self.about],
            to: .helpTopics
        )
        kernel.toolbar.setSymbol("gearshape", for: .configuration)
        kernel.toolbar.setSymbol("keyboard", for: Self.keyboardHelp)
        kernel.toolbar.setSymbol("command", for: Self.commandBrowser)
    }

    /// Save, export, import and reset (spec 19 › Save Position, Save Settings, adapted: the Mac
    /// stores a setting the moment it changes, so there is little left to save by hand).
    private func registerSettingsCommands(_ center: ConfigurationCenter, in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let commands = kernel.commands
        commands.register(Command(Self.savePosition, "Save Position", runsDuringJobs: true)) {
            center.savePosition()
        }
        commands.register(Command(Self.saveSettings, "Save Settings", runsDuringJobs: true)) {
            center.saveSettingsNow()
        }
        // `.location`: the file to write or read; without, the user is asked for it.
        commands.register(
            Command(Self.exportSettings, "Export Settings…", runsDuringJobs: true),
            parameterized: { argument in
                // With a file given, the export holds the settings alone and says so afterwards.
                if let url = argument.location {
                    guard url.isFileURL else {
                        return
                    }
                    return center.exportSettings(to: url)
                }
                guard let options = center.askExportOptions(),
                    let url = center.effects.chooseSettingsFile(true, kernel.productName),
                    url.isFileURL
                else { return }
                center.exportSettings(to: url, options: options, tellsWhatIsIncluded: false)
            }
        )
        commands.register(
            Command(Self.importSettings, "Import Settings…"),
            parameterized: { argument in
                guard let url = argument.location ?? center.effects.chooseSettingsFile(false, kernel.productName),
                    url.isFileURL
                else { return }
                center.importSettings(from: url)
            }
        )
        commands.register(Command(Self.resetSettings, "Reset All Settings…")) { center.resetSettings() }
        // A chain of commands that waits (`cm_wait`, a program it started) can be ended.
        commands.register(
            Command(Self.stopUserCommands, "Stop Waiting User Commands", runsDuringJobs: true),
            enabled: { center.runner.isWaiting }
        ) { center.runner.stopWaiting() }
        kernel.menus.add([Self.savePosition, Self.saveSettings], to: .configurationSave)
        kernel.menus.add(
            [
                Self.exportSettings, Self.importSettings,
                Self.resetSettings
            ],
            to: MenuSection(.configuration, order: 40)
        )
    }

    public func stop() {
        center?.closeWindows()
        center?.runner.removeListFilesNow()
    }
}
