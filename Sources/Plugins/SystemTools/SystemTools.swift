import AFMKernel
import Foundation

/// The behaviour behind the commands.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panel's state and ask the user. Child processes, the file systems, the volumes and the
/// list of applications are used inside jobs, on the job's thread; completions return to the
/// main thread. `log` and the settings belong to the main thread.
@MainActor
internal final class SystemTools {
    /// Settings key of the header of printed file lists.
    internal static let printHeaderKey = "systemTools.printHeader"
    /// Settings key of the lines per page of printed file lists.
    internal static let printLinesKey = "systemTools.printLines"
    /// Settings key of where the last file list went: printer, text file or viewer.
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

    /// Stands for the volumes in `BlockingCalls`: the questions to them are counted together.
    nonisolated private static let volumes = CallOwner()

    /// Unowned: the kernel owns the plugin, and through it this.
    internal unowned let kernel: Kernel
    /// What the tools do outside the program.
    internal let desktop: ToolsDesktop
    /// What the tools did, newest last (`SystemToolsPlugin.log`).
    internal private(set) var log: [String] = []

    /// Made the first time a drive is ejected; it writes to the log through this object.
    private lazy var ejection = VolumeEjection(
        kernel: kernel,
        access: desktop.volumes,
        home: { FileManager.default.homeDirectoryForCurrentUser },
        note: { [weak self] line in self?.note(line) }
    )

    /// The kernel's way of asking and telling the user.
    internal var interaction: any UserInteraction { kernel.interaction }
    /// The source panel's folder tab.
    internal var model: PanelModel { kernel.panels.source.model }
    /// The program's settings.
    internal var settings: any SettingsStore { kernel.settings }
    /// The user's home folder: where a line runs when the panel shows no local folder.
    internal var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The tools of `kernel`, acting outside the program through `desktop`.
    internal init(_ kernel: Kernel, desktop: ToolsDesktop) {
        self.kernel = kernel
        self.desktop = desktop
    }

    /// Whether `typed` may run while tests keep the tools from acting: a harmless program, in
    /// the foreground, with nothing the shell would read as a second command.
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

    /// Asks something of a volume from a job.
    ///
    /// A volume that has stopped answering (a share whose server is gone) may never return: the
    /// question then goes on alone on a thread of the kernel's, and the job ends, with nil, as soon
    /// as it is cancelled, so the commands of the program are not held up by it.
    nonisolated internal static func ask<Answer: Sendable>(
        _ question: String,
        of url: URL,
        _ monitor: any JobMonitor,
        _ work: @escaping @Sendable () -> Answer
    ) -> Answer? {
        BlockingCalls.answer(from: volumes, to: question + " " + url.path, cancellation: monitor.cancellation) { _ in
            work()
        }
    }

    /// Adds `line` to the log, on one line; the oldest half goes when the log is full.
    internal func note(_ line: String) {
        log.append(DisplayText.oneLine(line, limit: 400))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit / 2) }
    }

    /// Ejects the drive of `location`, or of the folder the source panel shows when there is none
    /// (`VolumeEjection`).
    internal func ejectVolume(_ location: URL?) {
        ejection.eject(driveOf: location ?? model.directory)
    }

    // MARK: The program

    /// Files › Quit: always closes; the shell asks about running jobs as for the Mac's Quit.
    internal func quit() {
        note("quit")
        desktop.quit()
    }

    /// Minimizes the main window.
    internal func minimize() {
        note("minimize")
        desktop.minimize()
    }

    deinit {
        // Nothing to release.
    }
}
