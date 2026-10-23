import AFMKernel
import Foundation

/// Runs what a button, a Start-menu item or a user command says (spec 14 › The command
/// language; 18 › Expansion).
///
/// Used on the main thread; a list file is written on `background` before the command starts.
/// Programs and shell lines are started here, as processes of their own: they take no part in the
/// command line's job and leave no entry in its history.
///
/// A line for the shell never has a file name, a path or another value in its text: the
/// values are handed to the shell as data and the line refers to them (`ShellLine.script`).
@MainActor
internal final class CommandRunner {
    /// What is called on the main thread when a run has ended.
    internal typealias Completion = @MainActor @Sendable () -> Void

    /// What one run counts with everything it calls.
    ///
    /// Main thread only. (A run whose steps are spent goes no further: nothing of it is waiting to
    /// go on then.).
    @MainActor
    internal final class Budget {
        /// The steps taken so far.
        internal var steps = 0

        deinit {
            // Nothing to release.
        }
    }

    /// What a run hands to everything it calls, also across a wait: the commands it is inside of.
    internal struct Call {
        /// The user commands and menu entries the run is inside of, outermost first.
        internal var names: [String]
        /// The steps the run may still take, shared with everything it calls.
        internal let budget: Budget
        /// The value of `generation` when the run began: a later one means it was stopped.
        internal let generation: Int
    }

    /// What is to run: an action with what it is given, under the name it runs as.
    internal struct Request {
        /// The fields of the button, menu entry or user command.
        internal let action: CommandAction
        /// What was written after the name of a user command.
        internal let arguments: [ExpandedPiece]
        /// The name of the user command or menu entry; a call of itself is told by it.
        internal let name: String?
        /// What messages call it.
        internal let title: String
    }

    /// The steps of one command with what they share.
    internal struct Chain {
        /// There is more than one step: a command of it takes only what is written after its name.
        internal let isChain: Bool
        /// The expanded parameters.
        internal let parameters: [ExpandedPiece]
        /// The Command field, for the line a shell is given.
        internal let command: String
        /// The Start path field.
        internal let startPath: String
        /// The list file the parameters asked for, removed when the command has ended.
        internal let listURL: URL?
        /// What messages call it.
        internal let title: String
        /// What the steps hand to what they call.
        internal let call: Call
    }

    /// Why a line could not be started, as the user is told.
    private struct LaunchProblem: Error {
        /// What the user is told.
        let message: String
    }

    /// How long a list file outlives the command that was given it: a program started with
    /// `open` has ended long before the application it opened has read the list.
    internal static let defaultListGrace: TimeInterval = 60
    /// How deep user commands may call each other, and how many steps one run may take with
    /// everything it calls: a loop the name check does not see still ends.
    internal static let depthLimit = 16
    /// How many steps one run may take with everything it calls.
    internal static let stepLimit = 1_000
    /// With this many marked, the marked names are gathered and the placeholders replaced off
    /// the main thread.
    internal static let backgroundSelectionThreshold = 5_000
    /// A line of more pieces than this is checked where it is started, off the main thread.
    internal static let checkedHereLimit = 4_096

    /// The program the runner works for.
    internal unowned let kernel: Kernel
    /// Programs and shell lines are started; without, they are only noted in `launched` (tests).
    internal let launchesApplications: Bool
    /// Where expansions of many names run; nil runs everything at once on the calling thread.
    internal let background: DispatchQueue?
    /// List files are written and removed in order, one after the other: a removal asked for
    /// earlier never takes a file written later.
    private let listQueue: DispatchQueue?
    /// Where list files are written: a folder of this process, emptied when the program starts
    /// and removed when it quits.
    ///
    /// Each file goes when its command has ended.
    internal let listFolder: URL
    /// The same for this runner (tests make it short).
    internal var listGrace = CommandRunner.defaultListGrace
    /// How the end of a started program comes back to the main thread.
    ///
    /// Tests keep it for later, to see what comes when the runner has gone meanwhile.
    internal var backToMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { MainLoop.perform($0) }
    /// The variables `%NAME%` in a Command field and `%|NAME|` in its parameters refer to.
    internal var environment = ProcessInfo.processInfo.environment
    /// Finds the definition of a user command, so that a chain can wait for what it starts.
    internal var userCommand: ((String) -> UserCommand?)?
    /// Finds the entry of the Start menu a `cm_UserMenu<n>` runs, for the same purpose.
    internal var startMenuEntry: ((String) -> StartMenuEntry?)?
    /// The user commands whose steps are being performed right now, outermost first.
    ///
    /// A command started from inside them (through the command registry) continues this list.
    internal var active: [String] = []
    /// The lines started without a command-line plugin, also when starting is switched off.
    internal private(set) var launched: [String] = []
    /// Raised by `stopWaiting`: what was waiting before belongs to an older number and ends.
    internal private(set) var generation = 0
    /// How many timers and programs chains are waiting for.
    internal var waiting = 0
    /// The programs started and not yet ended.
    private let children = ChildTable()

    /// Whether a chain is waiting for a `cm_wait` or for a program to end.
    internal var isWaiting: Bool { waiting > 0 }

    /// Without `background` everything runs at once on the calling thread (tests).
    internal init(kernel: Kernel, launchesApplications: Bool, background: DispatchQueue?, listFolder: URL) {
        self.kernel = kernel
        self.launchesApplications = launchesApplications
        self.background = background
        listQueue = background == nil ? nil : DispatchQueue(label: "afm.configuration.lists", qos: .userInitiated)
        self.listFolder = listFolder
    }

    /// The script for a line, once its start folder is known to be there.
    ///
    /// Asks the disk: not for the main thread.
    nonisolated private static func script(
        for line: [ExpandedPiece],
        startFolder folder: String?
    ) -> Result<ShellScript, LaunchProblem> {
        var isFolder: ObjCBool = false
        if let folder, !(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue) {
            let shown = DisplayText.oneLine(folder, limit: 200)
            return .failure(LaunchProblem(message: "The start folder \(shown) does not exist."))
        }
        return ShellLine.script(startLine(for: line)).mapError { LaunchProblem(message: $0.explanation) }
    }

    /// Starts the script with the login shell in `directory` and has `finished` told how it ended.
    nonisolated private static func spawn(
        _ script: ShellScript,
        in directory: String,
        children: ChildTable,
        waits: Bool,
        finished: @escaping @Sendable (String?) -> Void
    ) {
        let shell = LoginShell.posix
        let started = ChildProcess.spawn(
            executable: shell.executable,
            arguments: shell.options + script.arguments,
            environment: LoginShell.environment(foreignPath: LoginShell.foreignPath),
            directory: directory,
            calls: .system
        )
        switch started {
        case .failure(let failure):
            finished(failure.message)

        case .success(let pid):
            children.watch(pid, waitedFor: waits) { ending in
                finished(failure(endingWith: ending.status))
            }
        }
    }

    /// The shell's own way of saying that it found no such program, or could not run it; nil
    /// for every other ending.
    nonisolated private static func failure(endingWith status: Int32?) -> String? {
        switch status {
        case 127:
            return "The shell found no program of that name (exit status 127)."

        case 126:
            return "The shell could not run the program (exit status 126)."

        default:
            return nil
        }
    }

    /// Runs `work` away from the main thread and `completion` on it.
    internal func offMain<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result,
        then completion: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        guard let background else {
            completion(work())
            return
        }
        background.async {
            let result = work()
            MainLoop.perform { completion(result) }
        }
    }

    /// The same for list files, which are handled in the order they were asked for.
    internal func onListQueue<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result,
        then completion: @escaping @MainActor @Sendable (Result) -> Void
    ) {
        guard let listQueue else {
            completion(work())
            return
        }
        listQueue.async {
            let result = work()
            MainLoop.perform { completion(result) }
        }
    }

    /// Removes a list file after `delay`, in order with the other list files; nothing without one.
    internal func removeListFile(_ url: URL?, after delay: TimeInterval) {
        guard let url, let listQueue else {
            return
        }
        listQueue.asyncAfter(deadline: .now() + delay) { try? FileManager.default.removeItem(at: url) }
    }

    /// Ends every chain that is waiting: its remaining steps are not run, and the programs it
    /// waits for are asked to end.
    internal func stopWaiting() {
        generation += 1
        waiting = 0
        children.terminateWaitedFor()
    }

    /// Runs an action as a button or a menu item does: with no arguments, under no name.
    internal func run(_ action: CommandAction, title: String) {
        run(action, arguments: "", as: nil, title: title, completion: nil)
    }

    /// Runs an action. `arguments` is what was written after the name of a user command; with
    /// an empty Parameters field it takes that field's place, otherwise the `%A` codes refer to
    /// it, and without such a code it is added at the end (spec 14 › Rules, `em_` parameter rule).
    /// `completion` is called, on the main thread, when everything it started has ended; it is
    /// not called when the command was not run because the user gave up or it was refused
    /// for another reason than calling itself.
    internal func run(
        _ action: CommandAction,
        arguments: String,
        as name: String?,
        title: String,
        completion: Completion?
    ) {
        // Started from inside a running user command, this one is a call of that one.
        run(
            Request(action: action, arguments: arguments.isEmpty ? [] : [.text(arguments)], name: name, title: title),
            call: Call(names: active, budget: Budget(), generation: generation),
            completion: completion
        )
    }

    /// Runs a request as a part of `call`: refused when it calls itself or is nested too deeply.
    internal func run(_ request: Request, call: Call, completion: Completion?) {
        let title = DisplayText.oneLine(request.title, limit: 80)
        if let name = request.name, call.names.contains(name) {
            kernel.interaction.inform(
                "“\(title)” calls itself",
                detail: "The command \(name) was not run again.",
                style: .warning
            )
            completion?()
            return
        }
        guard call.names.count < Self.depthLimit else {
            kernel.interaction.inform(
                "“\(title)” is nested too deeply",
                detail: "User commands call each other more than \(Self.depthLimit) levels deep. "
                    + "The command was not run.",
                style: .warning
            )
            completion?()
            return
        }
        let steps = CommandLanguage.steps(request.action.command, environment: environment, resolve: resolve)
        guard !steps.isEmpty else {
            return
        }
        let parameters = request.action.parameters
        let template: [ExpandedPiece] = parameters.isEmpty ? request.arguments : [.text(parameters)]
        let shown = Request(action: request.action, arguments: request.arguments, name: request.name, title: title)
        expand(template, arguments: request.arguments) { [weak self] expanded in
            self?.start(steps, shown, expanded: expanded, call: call, completion: completion)
        }
    }

    /// Starts a program or shell line as a process of its own, run by a login shell (so it
    /// finds the same PATH as a terminal), away from the main thread.
    ///
    /// It is no job and not in the command-line history. `completion` is called on the main thread
    /// when the process has ended (with `waits` only), telling whether it could be started; a start
    /// that fails is reported. No thread waits for the process: its end is reported by the system.
    internal func launch(
        _ line: [ExpandedPiece],
        _ chain: Chain,
        waits: Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let folder = chain.startPath.isEmpty ? nil : ShellWords.expandingTilde(in: chain.startPath)
        guard launchesApplications else {
            let text = ShellLine.display(line)
            launched.append(folder.map { "cd " + ShellWords.quoted($0) + " && " + text } ?? text)
            return
        }
        let source = kernel.panels.source.model.directory
        let directory = folder ?? (source.isFileURL ? source.path : NSHomeDirectory())
        let table = children
        if waits { waiting += 1 }
        let finished = finisher(for: line, chain, waits: waits, completion: completion)
        // On a thread of the kernel's own: the start folder may lie on a share that does not answer.
        BlockingCalls.run {
            switch Self.script(for: line, startFolder: folder) {
            case .failure(let problem):
                finished(problem.message)

            case .success(let script):
                Self.spawn(script, in: directory, children: table, waits: waits, finished: finished)
            }
        }
    }

    /// What reports the end of a started line on the main thread: a failure is told, the list file
    /// goes, and a waiting chain goes on, unless the user stopped it meanwhile.
    private func finisher(
        for line: [ExpandedPiece],
        _ chain: Chain,
        waits: Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (String?) -> Void {
        let grace = listGrace
        let listURL = chain.listURL
        let started = chain.call.generation
        let toMain = backToMain
        let program = DisplayText.oneLine(ShellWords.unquoted(ShellWords.firstWord(of: line).word), limit: 80)
        return { [weak self] failure in
            toMain { [weak self] in
                guard let self else {
                    return
                }
                removeListFile(listURL, after: grace)
                if let failure {
                    kernel.interaction.inform("“\(program)” cannot be started!", detail: failure, style: .warning)
                }
                // A chain the user stopped meanwhile does not go on.
                guard waits, started == generation else {
                    return
                }
                waiting -= 1
                completion(failure == nil)
            }
        }
    }

    deinit {
        // Nothing to release.
    }
}
