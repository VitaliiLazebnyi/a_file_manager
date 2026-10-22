import AFMContracts
public import AFMKernel
import AppKit

/// The commands only this plugin provides (spec 17 › Command catalogue), under the spec's
/// names where it has one.
public enum SystemToolsCommands {
    /// Asks for a line and runs it like `CommandID.runCommandLine`.
    public static let runPrompt: CommandID = "afm_RunCommand"
    /// TC's "Open command prompt window": a terminal window in the source folder.
    public static let openTerminal: CommandID = "cm_ExecuteDOS"
    public static let systemInformation: CommandID = "cm_SysInfo"
    /// TC's "Volume Label": renames the volume the source panel shows.
    public static let renameVolume: CommandID = "cm_VolumeId"
    public static let ejectVolume: CommandID = "afm_EjectVolume"
    public static let printList: CommandID = "cm_PrintDir"
    public static let printListWithSubfolders: CommandID = "cm_PrintDirSub"
    public static let printFile: CommandID = "cm_PrintFile"
    /// TC's "Associate With": on the Mac, opening the file with an application of choice.
    public static let openWith: CommandID = "cm_Associate"
    public static let quit: CommandID = "cm_Exit"
    public static let minimize: CommandID = "cm_Minimize"
}

/// Command line execution, terminal, system information, volume name, printing file lists
/// and Open With (spec 02 › Command line, 12 › System Information, Volume label, Printing).
public final class SystemToolsPlugin: Plugin {
    /// Settings keys of the preferences page.
    nonisolated public static let terminalKey = "systemTools.terminal"
    nonisolated public static let showOutputKey = "systemTools.showOutput"
    nonisolated public static let recordHistoryKey = "systemTools.recordHistory"

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
        var desktop = launchesApplications ? ToolsDesktop.system : .quiet
        desktop.volumes = volumes ?? desktop.volumes
        self.init(desktop: desktop)
    }

    /// The tools, doing what they do outside the program through `desktop`.
    internal init(desktop: ToolsDesktop) {
        self.desktop = desktop
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let tools = SystemTools(kernel, desktop: desktop)
        self.tools = tools
        let commands = kernel.commands
        let model = { kernel.panels.source.model }
        let isLocal = { model().directory.isFileURL }
        // The list of operands can be a whole folder: it is made when the command runs. Whether
        // the command can run is asked ten times a second and answered without it.
        let hasLocalFile = { isLocal() && model().hasOperandFile }

        commands.register(
            Command(.runCommandLine, "Run Command Line"),
            parameterized: { argument in
                if let line = argument.text { tools.run(line) } else { tools.promptAndRun() }
            }
        )
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
        commands.register(
            Command(SystemToolsCommands.ejectVolume, "Eject Volume"),
            enabled: isLocal,
            parameterized: { tools.ejectVolume($0.location) }
        )
        commands.register(Command(SystemToolsCommands.printList, "Print File List…"), enabled: { model().isListed }) {
            tools.printList(withSubfolders: false)
        }
        commands.register(
            Command(SystemToolsCommands.printListWithSubfolders, "Print File List with Subfolders…"),
            enabled: { model().isListed }
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
            enabled: { isLocal() && model().cursorItem != nil }
        ) {
            // Enabled only with an item under the cursor.
            if let item = model().cursorItem {
                tools.openWith(item)
            }
        }
        commands.register(
            Command(SystemToolsCommands.quit, "Quit", [.f(4, .option)], runsDuringJobs: true),
            tools.quit
        )
        commands.register(Command(SystemToolsCommands.minimize, "Minimize", runsDuringJobs: true), tools.minimize)

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
}

/// The behaviour behind the commands.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panel's state and ask the user. Child processes, the file systems, the volumes and the
/// list of applications are used inside jobs, on the job's thread; completions return to the
/// main thread. `log` and the settings belong to the main thread.
@MainActor
internal final class SystemTools {
    private enum RunResult {
        case application(URL, files: [URL])
        case finished(ProcessOutcome)
    }

    // MARK: Printing

    private enum PrintOutput: Int, CaseIterable {
        case printer, textFile, viewer

        var title: String {
            switch self {
            case .printer:
                return "Printer…"

            case .textFile:
                return "Text file…"

            case .viewer:
                return "Show as text"
            }
        }
    }

    /// Where a printed file list goes.
    private enum Destination {
        case printer
        case file(URL)
        case viewer
    }

    internal static let printHeaderKey = "systemTools.printHeader"
    internal static let printLinesKey = "systemTools.printLines"
    internal static let printOutputKey = "systemTools.printOutput"
    /// In a list of this length or longer, the marked items are picked out off the main thread.
    internal static let backgroundSelectionThreshold = 5_000
    /// How many files one run of the printer program is given.
    nonisolated internal static let filesPerPrint = 256

    /// What tests may really run: programs that only write text.
    nonisolated internal static let harmlessCommands: Set<String> = ["echo", "printf", "true", "false", "pwd"]
    /// Characters with which a harmless first word could still start something else.
    nonisolated private static let shellOperators = CharacterSet(charactersIn: ";|&$`<>(){}\n\\")
    /// The log keeps its newest lines; a program that runs for weeks must not grow with every command.
    private static let logLimit = 512

    // MARK: Volumes

    /// Stands for the volumes in `BlockingCalls`: the questions to them are counted together.
    nonisolated private static let volumes = CallOwner()

    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    /// What the tools do outside the program.
    private let desktop: ToolsDesktop
    internal private(set) var log: [String] = []

    private var ejection: VolumeEjection!

    private var ui: any UserInteraction { kernel.interaction }
    private var model: PanelModel { kernel.panels.source.model }
    private var settings: any SettingsStore { kernel.settings }
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Command line

    private var history: [String] { CommandHistory.load(from: settings.scoped(to: "systemTools")) }

    internal init(_ kernel: Kernel, desktop: ToolsDesktop) {
        self.kernel = kernel
        self.desktop = desktop
        ejection = VolumeEjection(
            kernel: kernel,
            access: desktop.volumes,
            home: { FileManager.default.homeDirectoryForCurrentUser },
            note: { [weak self] in self?.note($0) }
        )
    }

    nonisolated internal static func isHarmless(_ typed: TypedCommand) -> Bool {
        harmlessCommands.contains(typed.firstWord) && !typed.isDetached
            && typed.command.rangeOfCharacter(from: shellOperators) == nil
    }

    /// The arguments of a line as locations, for handing them to an application.
    nonisolated internal static func files(in arguments: String, relativeTo directory: URL) -> [URL] {
        var urls: [URL] = []
        var rest = arguments
        while !rest.isEmpty {
            let (word, remaining) = TypedCommand.split(rest)
            if !word.isEmpty {
                urls.append(TypedCommand.location(of: word, relativeTo: directory))
            }
            rest = remaining
        }
        return urls
    }

    // MARK: Terminal

    /// Finds an application by path, name or bundle identifier (`identified`).
    ///
    /// Asks the disk: background only.
    nonisolated internal static func application(named name: String, identified: (String) -> URL?) -> URL? {
        let fm = FileManager.default
        if name.contains("/") {
            let path = NSString(string: name).expandingTildeInPath
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let bundleName = name.lowercased().hasSuffix(".app") ? name : name + ".app"
        if let found = TypedCommand.applicationFolders.map({ $0.appendingPathComponent(bundleName) })
            .first(where: {
                fm.fileExists(atPath: $0.path)
            })
        {
            return found
        }
        return identified(name)
    }

    // MARK: System information

    /// A screen as the dialog shows it: its pixels, and its points and scale when they differ.
    nonisolated internal static func display(_ size: NSSize, scale: CGFloat) -> String {
        let pixels = "\(Int(size.width * scale))x\(Int(size.height * scale))"
        return scale == 1 ? pixels : "\(pixels) (\(Int(size.width))x\(Int(size.height)) @\(Int(scale))x)"
    }

    /// Asks something of a volume from a job.
    ///
    /// A volume that has stopped answering (a share whose server is gone) may never return: the
    /// question then goes on alone on a thread of the kernel's, and the job ends, with nil, as soon
    /// as it is cancelled, so the commands of the program are not held up by it.
    nonisolated private static func ask<Answer: Sendable>(
        _ question: String,
        of url: URL,
        _ monitor: any JobMonitor,
        _ work: @escaping @Sendable () -> Answer
    ) -> Answer? {
        BlockingCalls.answer(from: volumes, to: question + " " + url.path, cancellation: monitor.cancellation) { _ in
            work()
        }
    }

    private func note(_ line: String) {
        log.append(DisplayText.oneLine(line, limit: 400))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit / 2) }
    }

    internal func promptAndRun() {
        let directory = model.directory.isFileURL ? model.directory : home
        guard
            let line = ui.prompt(
                "Run command:",
                value: history.first ?? "",
                detail:
                    "The line is run by your shell in \(directory.path). End it with & to leave the program running."
            )
        else { return }
        run(line)
    }

    /// Runs a typed line in the source panel's folder (spec 02 › Executing a line): an
    /// application is opened, anything else goes to the shell as a child process whose output
    /// is collected and shown.
    ///
    /// The job can be cancelled, which ends the child.
    internal func run(_ line: String) {
        guard let typed = TypedCommand(line) else {
            return
        }
        // A line may hold a password (`curl -u name:secret`): one that begins with a blank is
        // not remembered, as in a shell, and remembering can be switched off altogether.
        if settings.flag(SystemToolsPlugin.recordHistoryKey, default: true), !CommandHistory.isPrivate(line) {
            let store = settings.scoped(to: "systemTools")
            store.set(
                CommandHistory.adding(typed.isDetached ? typed.command + " &" : typed.command, to: history),
                forKey: CommandHistory.key
            )
        }
        guard desktop.mayRun(typed) else {
            note("skipped: \(DisplayText.oneLine(typed.command))")
            return
        }
        let directory = model.directory.isFileURL ? model.directory : home
        let shown = kernel.panels.all.map(\.model.directory)
        // The shell is always a POSIX shell, started as a login shell, so the command finds the same PATH as in a
        // terminal (`LoginShell`); tests use the plain system shell and leave the user's profile alone.
        let (shell, searchPath, environment) = (desktop.shell, desktop.searchPath, desktop.environment)
        let runner = ProcessRunner(
            executable: shell.executable,
            arguments: shell.options + [typed.isDetached ? typed.command + " &" : typed.command],
            directory: directory,
            collectsOutput: !typed.isDetached
        )
        let shownCommand = DisplayText.oneLine(typed.command)
        kernel.jobs.run(
            title: "Running: \(shownCommand)",
            work: { [runner] monitor -> RunResult in
                var runner = runner
                // What is a program is decided with the PATH of the login shell, not with the
                // short one this process was started with.
                if let application = typed.application(relativeTo: directory, path: searchPath()) {
                    return .application(application, files: Self.files(in: typed.arguments, relativeTo: directory))
                }
                runner.environment = environment()
                return .finished(
                    runner.run(cancellation: monitor.cancellation) { bytes in
                        monitor.report(
                            JobProgress(
                                lines: [shownCommand, "\(Format.bytes(Int64(bytes))) bytes of output"],
                                itemsDone: 0,
                                itemsTotal: 0
                            )
                        )
                    }
                )
            },
            completion: { [self] result in
                switch result {
                case .application(let application, let files):
                    note("application: \(DisplayText.oneLine(application.path))")
                    if files.isEmpty {
                        desktop.start(application)
                    } else {
                        desktop.open(files, application)
                    }

                case .finished(let outcome):
                    note((typed.isDetached ? "started: " : "ran: ") + shownCommand)
                    // The command may have changed the folders the panels show.
                    kernel.panels.refresh(shown)
                    show(outcome, of: typed)
                }
            }
        )
    }

    /// Shows what the command wrote: in the viewer when a plugin offers one, else in a dialog.
    private func show(_ outcome: ProcessOutcome, of typed: TypedCommand) {
        if let failure = outcome.failure {
            ui.inform(
                "\(DisplayText.oneLine(typed.firstWord, limit: 80)) cannot be started!",
                detail: failure,
                style: .warning
            )
            return
        }
        guard !typed.isDetached else {
            return
        }
        let mode = settings.index(SystemToolsPlugin.showOutputKey, default: 0)
        var text = outcome.output
        if outcome.isTruncated {
            text += "\n[The output was cut off after \(ProcessRunner.outputLimit / 1_024 / 1_024) MB.]"
        }
        var title = DisplayText.oneLine(typed.command)
        if outcome.wasCancelled {
            title += " (cancelled)"
        } else if outcome.status != 0 {
            title += " (exit status \(outcome.status))"
        }
        guard mode != 2, mode == 1 || !text.isEmpty || (outcome.status != 0 && !outcome.wasCancelled) else {
            return
        }
        if text.isEmpty {
            text =
                outcome.status == 0
                ? "The command wrote nothing."
                : "The command ended with exit status \(outcome.status) and wrote nothing."
        }
        show(text: text, title: title)
    }

    private func show(text: String, title: String) {
        if let viewer = kernel.services.find((any ViewerService).self) {
            viewer.view(text: text, title: title)
        } else {
            _ = ui.form(title, detail: "", fields: [.lines("output", "", text)], buttons: ["OK"])
        }
    }

    /// Opens a terminal window in the source panel's folder (spec 12 › Miscellaneous commands,
    /// "Open command prompt window"), with the terminal chosen in the preferences.
    internal func openTerminal(in directory: URL) {
        let name = settings.text(SystemToolsPlugin.terminalKey, default: "Terminal")
        let identified = desktop.applicationWithIdentifier
        // (Looking an application up asks the disk: on a thread of the kernel's own.)
        BlockingCalls.run { [weak self] in
            let application = Self.application(
                named: name.trimmingCharacters(in: .whitespaces),
                identified: identified
            )
            // Weak: the plugin may have gone by the time the disk has answered.
            DispatchQueue.main.async { [weak self] in self?.open(directory, inTerminal: application, named: name) }
        }
    }

    /// Opens `directory` in the terminal `application` that was looked up, or says that the one
    /// called `name` was not found.
    private func open(_ directory: URL, inTerminal application: URL?, named name: String) {
        guard let application else {
            ui.inform(
                "The terminal application \(DisplayText.oneLine(name, limit: 120)) was not found.",
                detail: "Choose another one in the configuration.",
                style: .warning
            )
            return
        }
        note("terminal: \(DisplayText.oneLine(directory.path))")
        // A terminal that is handed a folder opens a window there.
        desktop.open([directory], application)
    }

    internal func showSystemInformation() {
        let displays = NSScreen.screens.map { Self.display($0.frame.size, scale: $0.backingScaleFactor) }
        kernel.jobs.run(
            title: "System Information:",
            work: { monitor in
                SystemInformation.gather(displays: displays, cancellation: monitor.cancellation, asking: .system)
            },
            completion: { [self] gathered in
                // Nil: cancelled while a volume did not answer.
                guard let information = gathered else {
                    return
                }
                let answer = ui.form(
                    "System Information",
                    detail: "",
                    fields: [.lines("information", "", information.text)],
                    buttons: ["OK", "Copy"]
                )
                if answer?.button == 1 {
                    desktop.copy(information.text)
                }
            }
        )
    }

    /// "Set volume label" (spec 12 › Volume label): renames the volume of the source panel
    /// through the system's own interface, which asks for rights itself where it needs them.
    internal func renameVolume() {
        let directory = model.directory
        let (volumes, rename) = (desktop.volumes, desktop.renameVolume)
        kernel.jobs.run(
            title: "Volume:",
            work: { monitor in
                Self.ask("volume", of: directory, monitor) { volumes.facts(of: directory) }
            },
            completion: { [self] answer in
                // Nil: the question was cancelled.
                guard let facts = answer else {
                    return
                }
                guard let volume = facts.url else {
                    return ui.inform("The volume of \(DisplayText.oneLine(directory.path)) cannot be determined.")
                }
                guard
                    let name = ui.prompt(
                        "Set volume label - \(DisplayText.oneLine(volume.path))",
                        value: facts.name,
                        detail: "Volume label"
                    )?
                    .trimmingCharacters(in: .whitespaces), name != facts.name
                else { return }
                if let problem = VolumeName.problem(with: name) {
                    return ui.inform(
                        "The volume cannot be named \(DisplayText.oneLine(name, limit: 80))!",
                        detail: problem,
                        style: .warning
                    )
                }
                kernel.jobs.run(
                    title: "Renaming volume:",
                    work: { monitor -> any Error?? in
                        Self.ask("rename to \(name)", of: volume, monitor) { () -> any Error? in
                            do {
                                try rename(volume, name)
                                return nil
                            } catch {
                                return error
                            }
                        }
                    },
                    completion: { [self] answer in
                        guard let error = answer else {
                            return
                        }
                        if let error {
                            return ui.report(
                                error,
                                title: "The volume \(DisplayText.oneLine(facts.name, limit: 80)) cannot be renamed!"
                            )
                        }
                        note("rename-volume: \(volume.path) -> \(name)")
                        // A renamed volume is mounted under its new name; the panels follow or climb.
                        kernel.panels.all.forEach { $0.reload() }
                    }
                )
            }
        )
    }

    /// Ejects the drive of `location`, or of the folder the source panel shows (`VolumeEjection`).
    internal func ejectVolume(_ location: URL? = nil) {
        ejection.eject(driveOf: location ?? model.directory)
    }

    /// Files › Print › File list (spec 12 › Printing): the selected items, or the whole list
    /// when the cursor is on `[..]` and nothing is selected; Brief prints names only.
    ///
    /// With subfolders, the depth and the files to include are asked first.
    internal func printList(withSubfolders: Bool) {
        let panel = kernel.panels.source
        let model = panel.model
        let directory = model.directory
        // The marked items of a long list are picked out in the job, not here: taking the
        // snapshot costs nothing, whatever the length of the list.
        let operands = model.operandsSnapshot()
        let marked = operands.markedCount
        let count = marked > 0 ? marked : (operands.cursorItem != nil ? 1 : operands.shownItems.count)
        let gather: @Sendable (any JobMonitor) -> [FileItem] = { _ in
            marked > 0 || operands.cursorItem != nil ? operands.items() : operands.shownItems
        }
        var depth = 0
        var mask = "*.*"
        if withSubfolders {
            guard
                let depthText = ui.prompt(
                    "Print file list with subfolders",
                    value: "-1",
                    detail: "Depth of subfolders to include (-1 = unlimited):"
                )
            else { return }
            guard let number = Int(depthText.trimmingCharacters(in: .whitespaces)) else {
                ui.inform("\(depthText) is not a number.")
                return
            }
            guard
                let maskText = ui.prompt(
                    "Print file list with subfolders",
                    value: "*.*",
                    detail: "Files to include, e.g. *.doc *.txt, or *.* | *.bak to leave some out:"
                )
            else { return }
            (depth, mask) = (number, maskText)
        }
        let lines = settings.index(Self.printLinesKey, default: 60)
        let savedOutput = settings.index(Self.printOutputKey, default: 0)
        guard
            let answer = ui.form(
                "Print directory",
                detail: "\(count) item(s) of \(DisplayText.oneLine(kernel.fileSystems.displayPath(directory)))",
                fields: [
                    .text(
                        "header",
                        "Header text:",
                        settings.text(Self.printHeaderKey, default: DirectoryListFormatter.defaultHeader)
                    ),
                    .note("%d folder, %p page, %t pages, %D date, %T time, %% percent sign; empty for no header"),
                    .text("lines", "Lines per page:", String(lines)),
                    .checkbox("details", "Print size, date and attributes", panel.viewMode != .brief),
                    .choice(
                        "output",
                        "Output:",
                        PrintOutput.allCases.map(\.title),
                        selected: PrintOutput(rawValue: savedOutput) == nil ? 0 : savedOutput
                    )
                ],
                buttons: ["Print"]
            )
        else { return }
        let output = PrintOutput(rawValue: answer.index("output")) ?? .printer
        var formatter = DirectoryListFormatter()
        formatter.header = answer.text("header")
        formatter.linesPerPage = min(
            max(Int(answer.text("lines").trimmingCharacters(in: .whitespaces)) ?? lines, 5),
            500
        )
        formatter.isDetailed = answer.flag("details")
        settings.set(formatter.header, forKey: Self.printHeaderKey)
        settings.set(formatter.linesPerPage, forKey: Self.printLinesKey)
        settings.set(output.rawValue, forKey: Self.printOutputKey)

        let destination: Destination
        switch output {
        case .printer:
            destination = .printer

        case .viewer:
            destination = .viewer

        case .textFile:
            guard
                let name = ui.prompt("Save file list as:", value: "filelist.txt")?.trimmingCharacters(in: .whitespaces),
                !name.isEmpty
            else { return }
            destination = .file(kernel.fileSystems.location(from: name, relativeTo: directory))
        }
        let (fileSystems, ui) = (kernel.fileSystems, self.ui)
        let base = fileSystems.displayPath(directory)
        let showHidden = model.showHidden
        kernel.jobs.run(
            title: "Reading file list:",
            work: {
                [depth, mask, formatter, destination] monitor -> (
                    pages: [[String]], longest: Int, text: String, error: (any Error)?, cancelled: Bool
                ) in
                let items = gather(monitor)
                let rows =
                    withSubfolders
                    ? ListCollector(
                        fileSystems: fileSystems,
                        showHidden: showHidden,
                        mask: ListMask(mask),
                        depth: depth,
                        cancellation: monitor.cancellation
                    )
                    .rows(of: items)
                    : Parallel.map(items, serialBelow: 4_096) { ListRow($0) }
                // Only the form the chosen output needs is made.
                let pages = output == .printer ? formatter.pages(directory: base, rows: rows) : []
                let text = output == .printer ? "" : formatter.text(directory: base, rows: rows)
                // Measured here: the view that prints would otherwise count every line on the main thread.
                let longest = pages.reduce(0) { longest, page in page.reduce(longest) { max($0, $1.count) } }
                if monitor.cancellation.isCancelled {
                    return (pages, longest, text, nil, true)
                }
                guard case .file(let file) = destination else {
                    return (pages, longest, text, nil, false)
                }
                do {
                    let provider = try fileSystems.provider(for: file)
                    let exists = provider.item(at: file) != nil
                    if exists {
                        let replace = monitor.ask { @MainActor @Sendable in
                            ui.choose(
                                "Overwrite:",
                                detail: fileSystems.displayPath(file),
                                buttons: ["Overwrite", "Cancel"],
                                style: .warning
                            ) == 0
                        }
                        guard replace else {
                            return (pages, longest, text, CocoaError(.userCancelled), false)
                        }
                    }
                    // Written beside the file and moved over it, so a failure leaves the old file whole.
                    let temporary = file.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(file.lastPathComponent).\(UUID().uuidString).tmp"
                        )
                    do {
                        let writer = try provider.write(temporary)
                        try writer.write(Data(text.utf8))
                        try writer.close(attributes: FileAttributes())
                        try provider.move(temporary, to: file, replacing: exists)
                    } catch {
                        try? provider.remove(temporary)
                        throw error
                    }
                    return (pages, longest, text, nil, false)
                } catch {
                    return (pages, longest, text, error, false)
                }
            },
            completion: { [self] result in
                // A cancelled read leaves a partial list, which is neither printed nor shown.
                guard !result.cancelled else {
                    return
                }
                switch destination {
                case .printer:
                    print(result.pages, longestLine: result.longest, linesPerPage: formatter.linesPerPage, title: base)

                case .file(let file):
                    if let error = result.error {
                        if (error as? CocoaError)?.code != .userCancelled {
                            ui.report(error, title: "The file list cannot be saved!")
                        }
                        return
                    }
                    note("list-file: \(fileSystems.displayPath(file))")
                    kernel.panels.refresh([file.deletingLastPathComponent()], focus: file)

                case .viewer:
                    show(text: result.text, title: "File list - \(base)")
                }
            }
        )
    }

    /// Hands the pages to the system's print dialog, which previews them and prints.
    private func print(_ pages: [[String]], longestLine: Int, linesPerPage: Int, title: String) {
        note("print: \(pages.count) pages")
        // The operation prints with a copy of the shared settings, which stay as they are.
        let shared = NSPrintInfo.shared
        let operation = NSPrintOperation(
            view: PagePrintView(pages: pages, longestLine: longestLine, linesPerPage: linesPerPage, printInfo: shared),
            printInfo: shared
        )
        operation.printInfo.isHorizontallyCentered = false
        operation.printInfo.isVerticallyCentered = false
        operation.jobTitle = DisplayText.oneLine(title)
        desktop.print(operation)
    }

    /// Files › Print › File contents (spec 12 › Printing): sends the files to the default
    /// printer through the system's print service, which knows text, PDF and pictures.
    internal func printFiles(_ operands: PanelModel.Operands) {
        // A few files are picked out here; the marked files of a long list in a job.
        guard operands.markedCount > Self.backgroundSelectionThreshold else {
            printFiles(operands.items().filter { !$0.isDirectory })
            return
        }
        kernel.jobs.run(
            title: "Reading file list:",
            work: { _ in operands.items().filter { !$0.isDirectory } },
            completion: { [self] files in printFiles(files) }
        )
    }

    /// `files` are never empty: the command is offered only with a file among the operands.
    internal func printFiles(_ files: [FileItem]) {
        let what = files.count == 1 ? DisplayText.oneLine(files[0].name) : "\(files.count) files"
        guard
            ui.choose(
                "Print",
                detail: "Print \(what) on the default printer?",
                buttons: ["Print", "Cancel"],
                style: .information
            ) == 0
        else { return }
        // The log says how many when they are many: a line per file would be megabytes.
        let logged =
            "print-file: "
            + (files.count <= 8
                ? files.map { DisplayText.oneLine($0.name) }.joined(separator: ", ") : "\(files.count) files")
        let (printer, paths) = (desktop.printer, files.map(\.url.path))
        kernel.jobs.run(
            title: "Printing:",
            work: { monitor in
                // A few hundred files at a time: the system starts no program with more than 4,096 arguments (it
                // raises an exception instead), and their length is limited too. The first failure stops.
                var outcome = ProcessOutcome()
                for start in stride(from: 0, to: paths.count, by: Self.filesPerPrint)
                where outcome.failure == nil && outcome.status == 0 {
                    let part = Array(paths[start..<min(start + Self.filesPerPrint, paths.count)])
                    outcome = ProcessRunner(executable: printer, arguments: part, directory: nil)
                        .run(cancellation: monitor.cancellation)
                }
                return outcome
            },
            completion: { [self] outcome in
                if outcome.failure != nil || outcome.status != 0 {
                    return ui.inform(
                        "\(what) cannot be printed!",
                        detail: outcome.failure ?? outcome.output,
                        style: .warning
                    )
                }
                note(logged)
            }
        )
    }

    // MARK: Open With

    /// "Associate With" as the Mac has it: the applications able to open the item under the
    /// cursor, the usual one first.
    ///
    /// Choosing a lasting association is left to Finder.
    internal func openWith(_ item: FileItem) {
        let shownName = DisplayText.oneLine(item.name)
        let applicationsToOpen = desktop.applicationsToOpen
        kernel.jobs.run(
            title: "Applications:",
            work: { monitor -> [(name: String, url: URL)]? in
                // Launch Services looks at the file to know its type: on a volume that does not answer, that waits.
                Self.ask("applications", of: item.url, monitor) {
                    let found = applicationsToOpen(item.url)
                    let usual = found.usual
                    var applications = found.all
                    if let usual {
                        applications.removeAll { $0 == usual }
                        applications.insert(usual, at: 0)
                    }
                    return applications.map { url in
                        let name = FileManager.default.displayName(atPath: url.path)
                        return (url == usual ? name + " (default)" : name, url)
                    }
                }
            },
            completion: { [self] found in
                guard let applications = found else {
                    return
                }
                guard !applications.isEmpty else {
                    return ui.inform("No application is known to open \(shownName).")
                }
                guard let row = ui.pickRow("Open \(shownName) with:", rows: applications.map(\.name), button: "Open")
                else { return }
                let application = applications[row].url
                note("open-with: \(application.lastPathComponent) \(shownName)")
                desktop.open([item.url], application)
            }
        )
    }

    // MARK: The program

    /// Files › Quit: always closes; the shell asks about running jobs as for the Mac's Quit.
    internal func quit() {
        note("quit")
        desktop.quit()
    }

    internal func minimize() {
        note("minimize")
        desktop.minimize()
    }
}
