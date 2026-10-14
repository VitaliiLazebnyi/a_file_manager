import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import UniformTypeIdentifiers

/// The configuration dialog, hotkeys, button bar and user commands (spec 13, 14), the settings
/// as a whole (spec 19 › What is saved when) and the Help menu.
///
/// It is loaded last, so the commands of every other plugin exist when it starts; the user's
/// commands and Start-menu entries are registered then, like any plugin's commands.
/// The program's language is English: Total Commander's language files (spec 16) are Windows
/// resources and are not taken over.
public final class ConfigurationPlugin: Plugin {
    public let name = "Configuration"
    private let launchesApplications: Bool
    private let background: DispatchQueue?
    private let listFolder: URL
    private let sweepsStaleFolders: Bool
    private static let listsParent = FileManager.default.temporaryDirectory.appendingPathComponent("AFileManager-lists")
    private let settingsKeys: (() -> [String])?
    private(set) var center: ConfigurationCenter?

    // Commands only this plugin has (spec 17 › Configuration, Help, User).
    static let redefineHotkeys: CommandID = "cm_Confirmation"
    static let buttonBarConfig: CommandID = "cm_ButtonConfig"
    static let changeStartMenu: CommandID = "cm_ChangeStartMenu"
    static let commandBrowser: CommandID = "cm_CommandBrowser"
    static let userCommands: CommandID = "afm_UserCommands"
    static let newUserCommand: CommandID = "afm_NewUserCommand"
    static let savePosition: CommandID = "cm_ConfigSavePos"
    static let saveSettings: CommandID = "cm_ConfigSaveSettings"
    static let exportSettings: CommandID = "afm_ExportSettings"
    static let importSettings: CommandID = "afm_ImportSettings"
    static let resetSettings: CommandID = "afm_ResetSettings"
    static let stopUserCommands: CommandID = "afm_StopUserCommands"
    static let keyboardHelp: CommandID = "cm_Keyboard"
    static let helpIndex: CommandID = "cm_HelpIndex"
    static let about: CommandID = "cm_About"

    /// Tests turn `launchesApplications` off and pass no `background` queue, so nothing is
    /// started and everything happens at once; they also say where list files go.
    /// `settingsKeys` lists the keys the settings store holds, for export and reset; by
    /// default they are read from the macOS preferences of the program.
    public init(
        launchesApplications: Bool = true, background: DispatchQueue? = .global(qos: .userInitiated),
        listFolder: URL? = nil,
        settingsKeys: (() -> [String])? = nil
    ) {
        self.launchesApplications = launchesApplications
        self.background = background
        // Lists of this process go to a folder of its own, so another running instance is left alone.
        self.listFolder = listFolder ?? ConfigurationPlugin.listsParent.appendingPathComponent(String(getpid()))
        sweepsStaleFolders = listFolder == nil
        self.settingsKeys = settingsKeys
    }

    /// The lines of user commands that were started without a command-line plugin.
    public var launched: [String] { center?.runner.launched ?? [] }

    /// The keys of the values the program itself stored in the macOS preferences. Only the
    /// real settings store is listed this way; any other store has no list of its keys.
    private static func storedKeys(of settings: SettingsStore) -> [String] {
        guard settings is UserDefaultsSettings else { return [] }
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        // The program stores every value as JSON text. Whether it is one is told by how it
        // begins: reading a large value through would hold up the main thread.
        let beginnings = Set("{[\"-0123456789tfn".utf8)
        return values.compactMap { key, value in
            guard let data = value as? Data,
                let first = data.first(where: { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }),
                beginnings.contains(first)
            else { return nil }
            return key
        }.sorted()
    }

    public func start(in kernel: Kernel) {
        let runner = CommandRunner(
            kernel: kernel, launchesApplications: launchesApplications, background: background, listFolder: listFolder
        )
        let keys = settingsKeys ?? { [unowned kernel] in ConfigurationPlugin.storedKeys(of: kernel.settings) }
        let center = ConfigurationCenter(kernel: kernel, runner: runner, enumeratedKeys: keys)
        self.center = center
        runner.removeListFiles()
        if sweepsStaleFolders {
            let parent = ConfigurationPlugin.listsParent
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
            [ConfigurationPlugin.changeStartMenu, ConfigurationPlugin.stopUserCommands],
            to: MenuSection(.start, order: 10_000))
    }

    private func registerWindows(_ center: ConfigurationCenter, in kernel: Kernel) {
        let commands = kernel.commands
        func window(_ id: CommandID, _ title: String, _ shortcuts: [Shortcut] = [], _ open: @escaping () -> Void) {
            commands.register(Command(id, title, shortcuts, runsDuringJobs: true), open)
        }
        window(.configuration, "Options…", [.cmd(",")]) { center.showOptions(.first) }
        window(ConfigurationPlugin.redefineHotkeys, "Redefine Hotkeys…") { center.showOptions(.keyboard) }
        window(ConfigurationPlugin.buttonBarConfig, "Button Bar…") { center.showOptions(.buttonBar) }
        window(ConfigurationPlugin.changeStartMenu, "Change Start Menu…") { center.showOptions(.startMenu) }
        window(ConfigurationPlugin.commandBrowser, "Choose Command…") { center.browser().show() }
        window(ConfigurationPlugin.userCommands, "User Commands…") {
            center.browser().show(category: CommandRow.userCategory)
        }
        window(ConfigurationPlugin.newUserCommand, "New User Command…") { _ = center.editUserCommand(nil) }
        window(ConfigurationPlugin.keyboardHelp, "Keyboard Shortcuts") {
            center.showText(center.keyboardHelp(), title: "Keyboard Shortcuts")
        }
        window(ConfigurationPlugin.helpIndex, "What Is Where") {
            center.showText(center.whatIsWhere(), title: "What Is Where")
        }
        window(ConfigurationPlugin.about, "About \(kernel.productName)") { NSApp?.orderFrontStandardAboutPanel(nil) }

        kernel.menus.add([.configuration], to: .configurationOptions)
        kernel.menus.add(
            [
                ConfigurationPlugin.redefineHotkeys, ConfigurationPlugin.buttonBarConfig,
                ConfigurationPlugin.commandBrowser,
                ConfigurationPlugin.userCommands, ConfigurationPlugin.newUserCommand
            ], to: .configurationCustomize)
        kernel.menus.add(
            [ConfigurationPlugin.helpIndex, ConfigurationPlugin.keyboardHelp, ConfigurationPlugin.about],
            to: .helpTopics)
        kernel.toolbar.setSymbol("gearshape", for: .configuration)
        kernel.toolbar.setSymbol("keyboard", for: ConfigurationPlugin.keyboardHelp)
        kernel.toolbar.setSymbol("command", for: ConfigurationPlugin.commandBrowser)
    }

    /// Save, export, import and reset (spec 19 › Save Position, Save Settings, adapted: the Mac
    /// stores a setting the moment it changes, so there is little left to save by hand).
    private func registerSettingsCommands(_ center: ConfigurationCenter, in kernel: Kernel) {
        let commands = kernel.commands
        commands.register(Command(ConfigurationPlugin.savePosition, "Save Position", runsDuringJobs: true)) {
            center.savePosition()
        }
        commands.register(Command(ConfigurationPlugin.saveSettings, "Save Settings", runsDuringJobs: true)) {
            center.saveSettingsNow()
        }
        // `.location`: the file to write or read; without, the user is asked for it.
        commands.register(
            Command(ConfigurationPlugin.exportSettings, "Export Settings…", runsDuringJobs: true),
            parameterized: { argument in
                // With a file given, the export holds the settings alone and says so afterwards.
                if let url = argument.location {
                    guard url.isFileURL else { return }
                    return center.exportSettings(to: url)
                }
                guard let options = center.askExportOptions(),
                    let url = ConfigurationPlugin.askForFile(saving: true, kernel.productName),
                    url.isFileURL
                else { return }
                center.exportSettings(to: url, options: options, tellsWhatIsIncluded: false)
            })
        commands.register(
            Command(ConfigurationPlugin.importSettings, "Import Settings…"),
            parameterized: { argument in
                guard let url = argument.location ?? ConfigurationPlugin.askForFile(saving: false, kernel.productName),
                    url.isFileURL
                else { return }
                center.importSettings(from: url)
            })
        commands.register(Command(ConfigurationPlugin.resetSettings, "Reset All Settings…")) { center.resetSettings() }
        // A chain of commands that waits (`cm_wait`, a program it started) can be ended.
        commands.register(
            Command(ConfigurationPlugin.stopUserCommands, "Stop Waiting User Commands", runsDuringJobs: true),
            enabled: { center.runner.isWaiting }
        ) { center.runner.stopWaiting() }
        kernel.menus.add([ConfigurationPlugin.savePosition, ConfigurationPlugin.saveSettings], to: .configurationSave)
        kernel.menus.add(
            [
                ConfigurationPlugin.exportSettings, ConfigurationPlugin.importSettings,
                ConfigurationPlugin.resetSettings
            ],
            to: MenuSection(.configuration, order: 40))
    }

    private static func askForFile(saving: Bool, _ productName: String) -> URL? {
        let panel: NSSavePanel = saving ? NSSavePanel() : NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if saving { panel.nameFieldStringValue = "\(productName) Settings.json" }
        return panel.runModal() == .OK ? panel.url : nil
    }

    public func stop() {
        center?.closeWindows()
        center?.runner.removeListFilesNow()
    }
}
