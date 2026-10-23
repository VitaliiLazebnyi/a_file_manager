import AFMContracts
import AFMKernel
import Foundation

/// Running typed lines (spec 02 › Command line).
extension SystemTools {
    /// What came of a line: an application to open, or a child process that ended.
    private enum RunResult {
        case application(URL, files: [URL])
        case finished(ProcessOutcome)
    }

    /// The part of running a line that happens on the job's thread.
    private struct LineRun: Sendable {
        let typed: TypedCommand
        let runner: ProcessRunner
        let directory: URL
        /// What the job window shows of the line.
        let shownCommand: String
        let searchPath: @Sendable () -> String
        let environment: @Sendable () -> [String: String]

        /// Opens an application when the line names one, else runs the line in the shell.
        ///
        /// What is a program is decided with the PATH of the login shell, not with the short one
        /// this process was started with.
        func perform(_ monitor: any JobMonitor) -> RunResult {
            if let application = typed.application(
                relativeTo: directory,
                searching: TypedCommand.applicationFolders,
                path: searchPath()
            ) {
                return .application(application, files: SystemTools.files(in: typed.arguments, relativeTo: directory))
            }
            var child = runner
            child.environment = environment()
            return .finished(
                child.run(cancellation: monitor.cancellation) { bytes in
                    monitor.report(
                        JobProgress(
                            lines: [shownCommand, "\(Format.bytes(Int64(bytes))) bytes of output"],
                            itemsDone: 0,
                            itemsTotal: 0
                        )
                    )
                }
            )
        }
    }

    /// The lines run before, newest first.
    private var history: [String] { CommandHistory.load(from: settings.scoped(to: "systemTools")) }

    /// Asks for a line, the last one offered, and runs it.
    internal func promptAndRun() {
        let directory = model.directory.isFileURL ? model.directory : home
        guard
            let line = interaction.prompt(
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
        remember(typed, typedAs: line)
        guard desktop.mayRun(typed) else {
            note("skipped: \(DisplayText.oneLine(typed.command, limit: 200))")
            return
        }
        let directory = model.directory.isFileURL ? model.directory : home
        let shown = kernel.panels.all.map(\.model.directory)
        // The shell is always a POSIX shell, started as a login shell, so the command finds the same PATH as in a
        // terminal (`LoginShell`); tests use the plain system shell and leave the user's profile alone.
        let shell = desktop.shell
        let lineRun = LineRun(
            typed: typed,
            runner: ProcessRunner(
                executable: shell.executable,
                arguments: shell.options + [typed.isDetached ? typed.command + " &" : typed.command],
                directory: directory,
                collectsOutput: !typed.isDetached
            ),
            directory: directory,
            shownCommand: DisplayText.oneLine(typed.command, limit: 200),
            searchPath: desktop.searchPath,
            environment: desktop.environment
        )
        kernel.jobs.run(
            title: "Running: \(lineRun.shownCommand)",
            work: { monitor in lineRun.perform(monitor) },
            completion: { [self] result in
                switch result {
                case .application(let application, let files):
                    note("application: \(DisplayText.oneLine(application.path, limit: 200))")
                    if files.isEmpty {
                        desktop.start(application)
                    } else {
                        desktop.open(files, application)
                    }

                case .finished(let outcome):
                    note((typed.isDetached ? "started: " : "ran: ") + lineRun.shownCommand)
                    // The command may have changed the folders the panels show.
                    kernel.panels.refresh(shown)
                    show(outcome, of: typed)
                }
            }
        )
    }

    /// Puts the line first in the history.
    ///
    /// A line may hold a password (`curl -u name:secret`): one that begins with a blank is not
    /// remembered, as in a shell, and remembering can be switched off altogether.
    private func remember(_ typed: TypedCommand, typedAs line: String) {
        guard settings.flag(SystemToolsPlugin.recordHistoryKey, default: true), !CommandHistory.isPrivate(line) else {
            return
        }
        let store = settings.scoped(to: "systemTools")
        store.set(
            CommandHistory.adding(typed.isDetached ? typed.command + " &" : typed.command, to: history),
            forKey: CommandHistory.key
        )
    }

    /// Shows what the command wrote: in the viewer when a plugin offers one, else in a dialog.
    private func show(_ outcome: ProcessOutcome, of typed: TypedCommand) {
        if let failure = outcome.failure {
            interaction.inform(
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
        var title = DisplayText.oneLine(typed.command, limit: 200)
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

    /// Shows `text` in the viewer when a plugin offers one, else in a dialog.
    internal func show(text: String, title: String) {
        if let viewer = kernel.services.find((any ViewerService).self) {
            viewer.view(text: text, title: title)
        } else {
            _ = interaction.form(title, detail: "", fields: [.lines("output", "", text)], buttons: ["OK"])
        }
    }
}
