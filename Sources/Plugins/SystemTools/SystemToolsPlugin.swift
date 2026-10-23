import AFMContracts
public import AFMKernel
import Foundation

/// Command line execution, terminal, system information, volume name, printing file lists
/// and Open With (spec 02 › Command line, 12 › System Information, Volume label, Printing).
public final class SystemToolsPlugin: Plugin {
    /// Settings key of the terminal application (name, path or bundle identifier).
    nonisolated public static let terminalKey = "systemTools.terminal"
    /// Settings key of when the output of a command is shown: when there is any, always, never.
    nonisolated public static let showOutputKey = "systemTools.showOutput"
    /// Settings key of whether the lines that were run are remembered.
    nonisolated public static let recordHistoryKey = "systemTools.recordHistory"

    /// The plugin's name in the kernel: `SystemTools`.
    public let name = "SystemTools"

    private let desktop: ToolsDesktop
    private var tools: SystemTools?

    /// What the plugin started or, where tests keep it from acting, would have started:
    /// `ran: echo hi`, `skipped: make`, `terminal: /path`, `print: 2 pages`, `quit`, …
    /// Main thread only.
    public var log: [String] { tools?.log ?? [] }

    /// Tests turn `launchesApplications` off, so they do not start other applications.
    ///
    /// Then only harmless lines such as `echo` are really run (by `/bin/sh`, without the user's
    /// profile); nothing is printed, opened, renamed, ejected or quit (`ToolsDesktop.quiet`).
    /// `volumes` stands in for the volumes of the Mac when a test ejects one.
    public convenience init(launchesApplications: Bool = true, volumes: any VolumeAccess? = nil) {
        var chosen = launchesApplications ? ToolsDesktop.system : .quiet
        chosen.volumes = volumes ?? chosen.volumes
        self.init(desktop: chosen)
    }

    /// The tools, doing what they do outside the program through `desktop`.
    internal init(desktop: ToolsDesktop) {
        self.desktop = desktop
    }

    private static func registerCommands(in owner: Kernel, _ tools: SystemTools) {
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let isLocal = { model().directory.isFileURL }

        commands.register(Command(.runCommandLine, "Run Command Line")) { argument in
            if let line = argument.text { tools.run(line) } else { tools.promptAndRun() }
        }
        commands.register(Command(SystemToolsCommands.runPrompt, "Run Command…"), tools.promptAndRun)
        commands.register(
            Command(SystemToolsCommands.openTerminal, "Open Terminal Here", runsDuringJobs: true),
            enabled: isLocal
        ) {
            tools.openTerminal(in: model().directory)
        }
        commands.register(
            Command(SystemToolsCommands.systemInformation, "System Information…"),
            tools.showSystemInformation
        )
        commands.register(
            Command(SystemToolsCommands.renameVolume, "Rename Volume…"),
            enabled: isLocal,
            tools.renameVolume
        )
        // With a location (the eject buttons of the drives), the drive of that location.
        commands.register(Command(SystemToolsCommands.ejectVolume, "Eject Volume"), enabled: isLocal) { argument in
            tools.ejectVolume(argument.location)
        }
        commands.register(
            Command(SystemToolsCommands.quit, "Quit", [.f(4, .option)], runsDuringJobs: true),
            tools.quit
        )
        commands.register(Command(SystemToolsCommands.minimize, "Minimize", runsDuringJobs: true), tools.minimize)
    }

    private static func registerFileCommands(in owner: Kernel, _ tools: SystemTools) {
        unowned let kernel = owner
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let isLocal = { model().directory.isFileURL }
        // The list of operands can be a whole folder: it is made when the command runs. Whether
        // the command can run is asked ten times a second and answered without it.
        let hasLocalFile = { isLocal() && model().hasOperandFile }
        let isListed = { model().isListed }
        let hasLocalItem = { isLocal() && model().cursorItem != nil }

        commands.register(Command(SystemToolsCommands.printList, "Print File List…"), enabled: isListed) {
            tools.printList(withSubfolders: false)
        }
        commands.register(
            Command(SystemToolsCommands.printListWithSubfolders, "Print File List with Subfolders…"),
            enabled: isListed
        ) {
            tools.printList(withSubfolders: true)
        }
        commands.register(
            Command(SystemToolsCommands.printFile, "Print File Contents", [.f(9, .control)]),
            enabled: hasLocalFile
        ) {
            // Enabled only for a local folder.
            tools.printFiles(model().operandsSnapshot())
        }
        commands.register(
            Command(SystemToolsCommands.openWith, "Open With…", runsDuringJobs: false),
            enabled: hasLocalItem
        ) {
            // Enabled only with an item under the cursor.
            if let item = model().cursorItem {
                tools.openWith(item)
            }
        }
    }

    private static func addMenus(in kernel: Kernel) {
        kernel.menus.add([SystemToolsCommands.openWith], to: .filesOpen)
        kernel.menus.add(
            [
                SystemToolsCommands.printList, SystemToolsCommands.printListWithSubfolders,
                SystemToolsCommands.printFile
            ],
            to: .filesPrint
        )
        // Files › Quit closes the program as in TC; the Mac's own Quit is in the application menu.
        kernel.menus.add([SystemToolsCommands.quit], to: MenuSection(.files, order: 100))
        kernel.menus.add(
            [
                SystemToolsCommands.systemInformation, SystemToolsCommands.renameVolume,
                SystemToolsCommands.ejectVolume,
                SystemToolsCommands.openTerminal
            ],
            to: .commandsTools
        )
        kernel.menus.add([SystemToolsCommands.runPrompt], to: .commandsRun)
        kernel.menus.addToContextMenu([SystemToolsCommands.openWith], in: .tools, onItemOnly: true)
        kernel.menus.addToContextMenu([SystemToolsCommands.openTerminal], in: .tools)
    }

    private static func addToolbarButtons(in kernel: Kernel) {
        kernel.toolbar.add(
            SystemToolsCommands.openTerminal,
            symbol: "terminal",
            group: 80,
            hint: "Open a Terminal window in the current folder."
        )
        kernel.toolbar.add(
            SystemToolsCommands.systemInformation,
            symbol: "desktopcomputer",
            group: 80,
            hint: "Show information about this Mac: hardware, macOS and the disks."
        )
        kernel.toolbar.setSymbol("play.rectangle", for: SystemToolsCommands.runPrompt)
        kernel.toolbar.setSymbol("printer", for: SystemToolsCommands.printList)
        kernel.toolbar.setSymbol(
            "eject",
            for: SystemToolsCommands.ejectVolume,
            hint: "Safely eject the drive the current folder is on (a USB stick, a card, a disk image)."
        )
        kernel.toolbar.setSymbol("arrow.up.forward.app", for: SystemToolsCommands.openWith)
    }

    private static func addPreferences(in owner: Kernel) {
        unowned let kernel = owner
        kernel.preferences.add(
            PreferencePage(
                title: "System Tools",
                preferences: [
                    Preference(
                        Self.terminalKey,
                        "Terminal application (name, path or bundle identifier)",
                        .text(default: "Terminal")
                    ),
                    Preference(
                        Self.showOutputKey,
                        "Show the output of a command",
                        .choice(["When there is any", "Always", "Never"], default: 0)
                    ),
                    Preference(
                        SystemTools.printHeaderKey,
                        "Header of printed file lists (%d folder, %p page, %t pages, %D date, %T time)",
                        .text(default: DirectoryListFormatter.defaultHeader)
                    ),
                    Preference(
                        Self.recordHistoryKey,
                        "Remember the command lines that were run (never one that begins with a blank)",
                        .flag(default: true)
                    )
                ]
            ) {
                // Switched off, what was remembered goes too.
                if !kernel.settings.flag(Self.recordHistoryKey, default: true) {
                    kernel.settings.scoped(to: "systemTools").set(nil as Data?, forKey: CommandHistory.key)
                }
            }
        )
    }

    /// Registers the commands, their menus, toolbar buttons and the preferences page.
    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let started = SystemTools(kernel, desktop: desktop)
        tools = started
        Self.registerCommands(in: kernel, started)
        Self.registerFileCommands(in: kernel, started)
        Self.addMenus(in: kernel)
        Self.addToolbarButtons(in: kernel)
        Self.addPreferences(in: kernel)
    }

    deinit {
        // Nothing to release.
    }
}
