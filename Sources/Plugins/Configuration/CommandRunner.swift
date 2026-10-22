import AFMContracts
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
final class CommandRunner {
    private unowned let kernel: Kernel
    private let launchesApplications: Bool
    private let background: DispatchQueue?
    /// List files are written and removed in order, one after the other: a removal asked for
    /// earlier never takes a file written later.
    private let listQueue: DispatchQueue?
    /// Where list files are written: a folder of this process, emptied when the program starts
    /// and removed when it quits.
    ///
    /// Each file goes when its command has ended.
    let listFolder: URL
    /// How long a list file outlives the command that was given it: a program started with
    /// `open` has ended long before the application it opened has read the list.
    static let defaultListGrace: TimeInterval = 60
    /// The same for this runner (tests make it short).
    var listGrace = CommandRunner.defaultListGrace
    /// How the end of a started program comes back to the main thread.
    ///
    /// Tests keep it for later, to see what comes when the runner has gone meanwhile.
    var backToMain: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { MainLoop.perform($0) }
    /// How deep user commands may call each other, and how many steps one run may take with
    /// everything it calls: a loop the name check does not see still ends.
    static let depthLimit = 16
    static let stepLimit = 1_000
    /// With this many marked, the marked names are gathered and the placeholders replaced off
    /// the main thread.
    static let backgroundSelectionThreshold = 5_000
    /// A line of more pieces than this is checked where it is started, off the main thread.
    static let checkedHereLimit = 4_096
    var environment = ProcessInfo.processInfo.environment
    /// Finds the definition of a user command, so that a chain can wait for what it starts.
    var userCommand: ((String) -> UserCommand?)?
    /// Finds the entry of the Start menu a `cm_UserMenu<n>` runs, for the same purpose.
    var startMenuEntry: ((String) -> StartMenuEntry?)?
    /// The user commands whose steps are being performed right now, outermost first.
    ///
    /// A command started from inside them (through the command registry) continues this list.
    private var active: [String] = []
    /// The lines started without a command-line plugin, also when starting is switched off.
    private(set) var launched: [String] = []
    /// Raised by `stopWaiting`: what was waiting before belongs to an older number and ends.
    private var generation = 0
    /// How many timers and programs chains are waiting for.
    private var waiting = 0
    private let children = ChildTable()

    /// What one run counts with everything it calls.
    ///
    /// Main thread only. (A run whose steps are spent goes no further: nothing of it is waiting to
    /// go on then.).
    @MainActor
    private final class Budget {
        var steps = 0
    }

    /// What a run hands to everything it calls, also across a wait: the commands it is inside of.
    private struct Call {
        var names: [String]
        let budget: Budget
        let generation: Int
    }

    /// The steps of one command with what they share.
    private struct Chain {
        let isChain: Bool
        let parameters: [ExpandedPiece]
        /// The Command field, for the line a shell is given.
        let command: String
        let startPath: String
        let listURL: URL?
        let title: String
        let call: Call
    }

    /// Without `background` everything runs at once on the calling thread (tests).
    init(kernel: Kernel, launchesApplications: Bool, background: DispatchQueue?, listFolder: URL) {
        self.kernel = kernel
        self.launchesApplications = launchesApplications
        self.background = background
        listQueue = background == nil ? nil : DispatchQueue(label: "afm.configuration.lists", qos: .userInitiated)
        self.listFolder = listFolder
    }

    /// Runs `work` away from the main thread and `completion` on it.
    func offMain<Result: Sendable>(
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
    private func onListQueue<Result: Sendable>(
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

    /// Removes the list files earlier commands left behind, off the main thread.
    func removeListFiles() {
        let folder = listFolder
        onListQueue({ try? FileManager.default.removeItem(at: folder) }, then: { _ in })
    }

    /// For the moment the program quits (nothing dispatched is run then): removes the lists
    /// no started program can still be reading.
    ///
    /// A younger one stays; its folder is cleared away at the next start, when this process is
    /// gone.
    func removeListFilesNow() {
        let fm = FileManager.default
        let files =
            (try? fm.contentsOfDirectory(at: listFolder, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        var kept = 0
        for file in files {
            // A list without a date (gone meanwhile) is removed like an old one.
            if let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                Date().timeIntervalSince(written) < listGrace
            {
                kept += 1
            } else {
                try? fm.removeItem(at: file)
            }
        }
        if kept == 0 { try? fm.removeItem(at: listFolder) }
    }

    /// Removes the folders of earlier runs of the program that are no longer running.
    ///
    /// Folders are named by process number; another running instance keeps its own.
    nonisolated static func removeStaleListFolders(in parent: URL) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = Int32(url.lastPathComponent) else { continue }
            if pid != getpid(), kill(pid, 0) == -1, errno == ESRCH { try? fm.removeItem(at: url) }
        }
    }

    private func removeListFile(_ url: URL?, after delay: TimeInterval = 0) {
        guard let url, let listQueue else {
            return
        }
        listQueue.asyncAfter(deadline: .now() + delay) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Context

    /// A panel as the placeholders see it, and, when its marked names are many, how to gather
    /// them away from the main thread.
    private func snapshot(of panel: any PanelHandle, withSelection: Bool) -> (
        snapshot: PanelSnapshot, gather: (@Sendable () -> [String])?
    ) {
        let model = panel.model
        // A branch view or a file list shows real files under display paths and relative
        // names; its items are given by their real paths, and the panel has no path of its own.
        let showsFiles = !model.directory.isFileURL && model.items.first?.url.isFileURL == true
        @Sendable
        func name(of item: FileItem) -> String {
            showsFiles && item.url.isFileURL ? item.url.path : item.name
        }
        var path =
            showsFiles
            ? "" : model.directory.isFileURL ? model.directory.path : kernel.fileSystems.displayPath(model.directory)
        if !path.isEmpty, !path.hasSuffix("/") { path += "/" }
        var snapshot = PanelSnapshot(path: path, cursorName: model.cursorItem.map(name(of:)))
        let count = model.selectionCount
        // The marked names cost a pass over the marks: only a text that asks for them gets them.
        guard withSelection, count > 0 else {
            return (snapshot, nil)
        }
        // The marks and the list are taken as they are (nothing is copied); the marked items,
        // which are exactly those, are picked out here for a few and away from the main thread for many.
        let operands = model.operandsSnapshot()
        guard background != nil, count >= Self.backgroundSelectionThreshold else {
            snapshot.selection = operands.markedItems().map(name(of:))
            return (snapshot, nil)
        }
        return (snapshot, { operands.markedItems().map(name(of:)) })
    }

    /// Replaces the placeholders of `template`.
    ///
    /// With many marked names the work is done away from the main thread; `completion` is called on
    /// it either way.
    private func expand(
        _ template: [ExpandedPiece],
        arguments: [ExpandedPiece],
        then completion: @escaping @MainActor @Sendable (ExpandedParameters) -> Void
    ) {
        let panels = kernel.panels
        let needsSelection = ParameterExpander.usesSelection(template)
        let left = snapshot(of: panels.left, withSelection: needsSelection)
        let right = snapshot(of: panels.right, withSelection: needsSelection)
        var context = ExpansionContext(
            left: left.snapshot,
            right: right.snapshot,
            sourceIsRight: panels.source === panels.right,
            environment: environment,
            arguments: ShellLine.display(arguments),
            listFolder: listFolder
        )
        context.argumentPieces = arguments
        guard left.gather != nil || right.gather != nil else {
            completion(ParameterExpander(context: context).expand(template))
            return
        }
        let prepared = context
        offMain(
            {
                var context = prepared
                if let gather = left.gather { context.left.selection = gather() }
                if let gather = right.gather { context.right.selection = gather() }
                return ParameterExpander(context: context).expand(template)
            },
            then: completion
        )
    }

    private func location(_ text: String) -> URL {
        kernel.fileSystems.location(from: text, relativeTo: kernel.panels.source.model.directory)
    }

    /// A registered command by its name in any case (spec 14 › Rules: names are case-insensitive).
    private func resolve(_ name: String) -> CommandID? {
        let lowered = name.lowercased()
        return kernel.commands.all.first { $0.id.rawValue.lowercased() == lowered }?.id
    }

    // MARK: Running

    /// Whether a chain is waiting for a `cm_wait` or for a program to end.
    var isWaiting: Bool { waiting > 0 }

    /// Ends every chain that is waiting: its remaining steps are not run, and the programs it
    /// waits for are asked to end.
    func stopWaiting() {
        generation += 1
        waiting = 0
        children.terminateWaitedFor()
    }

    /// Runs an action. `arguments` is what was written after the name of a user command; with
    /// an empty Parameters field it takes that field's place, otherwise the `%A` codes refer to
    /// it, and without such a code it is added at the end (spec 14 › Rules, `em_` parameter rule).
    /// `completion` is called, on the main thread, when everything it started has ended; it is
    /// not called when the command was not run because the user gave up or it was refused
    /// for another reason than calling itself.
    func run(
        _ action: CommandAction,
        arguments: String = "",
        as name: String? = nil,
        title: String,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        // Started from inside a running user command, this one is a call of that one.
        run(
            action,
            arguments: arguments.isEmpty ? [] : [.text(arguments)],
            as: name,
            title: title,
            call: Call(names: active, budget: Budget(), generation: generation),
            completion: completion
        )
    }

    private func run(
        _ action: CommandAction,
        arguments: [ExpandedPiece],
        as name: String?,
        title: String,
        call: Call,
        completion: (@MainActor @Sendable () -> Void)?
    ) {
        let title = DisplayText.oneLine(title, limit: 80)
        if let name, call.names.contains(name) {
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
        let steps = CommandLanguage.steps(action.command, environment: environment, resolve: resolve)
        guard !steps.isEmpty else {
            return
        }
        let template: [ExpandedPiece] = action.parameters.isEmpty ? arguments : [.text(action.parameters)]
        expand(template, arguments: arguments) { [weak self] expanded in
            self?
                .start(
                    steps,
                    action,
                    arguments: arguments,
                    expanded: expanded,
                    as: name,
                    title: title,
                    call: call,
                    completion: completion
                )
        }
    }

    private func refuse(_ title: String, _ reason: String) {
        kernel.interaction.inform("“\(title)” was not run", detail: reason, style: .warning)
    }

    /// The line a shell is given for the external step of a command.
    private func externalLine(_ command: String, parameters: [ExpandedPiece]) -> [ExpandedPiece] {
        let line = CommandLanguage.environmentPieces(command.trimmingCharacters(in: .whitespaces), environment)
        return parameters.isEmpty ? line : line + [.text(" ")] + parameters
    }

    private func start(
        _ steps: [CommandStep],
        _ action: CommandAction,
        arguments: [ExpandedPiece],
        expanded: ExpandedParameters,
        as name: String?,
        title: String,
        call: Call,
        completion: (@MainActor @Sendable () -> Void)?
    ) {
        guard call.generation == generation else {
            return
        }
        var pieces = expanded.pieces
        // A name code with no name stands for the folder (`rm -rf %P%N`): nothing is run.
        if expanded.missingName {
            kernel.interaction.inform(
                "“\(title)” needs a file",
                detail:
                    "There is no file under the cursor, only the parent row or an empty list. The command was not run.",
                style: .warning
            )
            return
        }
        if let problem = expanded.problem {
            refuse(title, problem)
            return
        }
        if !action.parameters.isEmpty, !arguments.isEmpty, !expanded.usedArguments {
            pieces = ParameterExpander.trimmed(pieces + [.text(" ")] + arguments)
        }
        if expanded.asksFirst {
            // Names a shell could read as something else are shown as references to them.
            let shown = ShellLine.prompt(pieces)
            guard
                let edited = kernel.interaction.prompt(
                    "Parameters for “\(title)”:",
                    value: shown.text,
                    detail: shown.legend
                )
            else { return }
            pieces = ShellLine.pieces(fromPrompt: edited, values: shown.values)
        }
        let isExternal = steps.contains {
            guard case .external = $0 else {
                return false
            }
            return true
        }
        // The line is checked before anything of the command runs. (A line with thousands of
        // names is checked where it is started; a refusal is reported from there.)
        if isExternal, pieces.count <= Self.checkedHereLimit,
            case .failure(let refusal) = ShellLine.script(externalLine(action.command, parameters: pieces))
        {
            refuse(
                title,
                refusal.explanation
                    + " A file name is handed to the shell as data, and that is not possible at this place of the line."
            )
            return
        }
        let listURL = expanded.listFile?.url
        let chain = Chain(
            isChain: steps.count > 1,
            parameters: pieces,
            command: action.command,
            startPath: action.startPath,
            listURL: listURL,
            title: title,
            call: Call(
                names: call.names + (name.map { [$0] } ?? []),
                budget: call.budget,
                generation: call.generation
            )
        )
        // Weak: the list is written off the main thread, and the plugin may be gone when that is done.
        let grace = listGrace
        let begin = { [weak self] in
            self?.perform(ArraySlice(steps), chain, then: completion)
            // Commands of the program have read the list by now; a started process removes it itself.
            if !isExternal { self?.removeListFile(listURL, after: grace) }
        }
        guard let list = expanded.listFile else {
            begin()
            return
        }
        onListQueue(
            {
                Result {
                    try FileManager.default.createDirectory(
                        at: list.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    // The names of the user's files are for the started program alone.
                    try list.contents.write(to: list.url)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.url.path)
                }
            },
            then: { [weak self] result in
                if case .failure(let error) = result {
                    self?.kernel.interaction
                        .report(error, title: "The list of files for “\(title)” could not be written")
                    return
                }
                begin()
            }
        )
    }

    /// Runs the steps in the written order.
    ///
    /// A `cm_wait` hands the rest to a timer, so the main thread never sleeps; so does a program
    /// that later steps have to wait for. The chain carries the names of the commands it is inside
    /// of through every such wait.
    private func perform(
        _ steps: ArraySlice<CommandStep>,
        _ chain: Chain,
        then done: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard chain.call.generation == generation else {
            return
        }
        let outer = active
        active = chain.call.names
        defer { active = outer }
        var rest = steps
        while let step = rest.popFirst() {
            chain.call.budget.steps += 1
            guard chain.call.budget.steps <= Self.stepLimit else {
                kernel.interaction.inform(
                    "“\(chain.title)” was stopped",
                    detail: "It ran \(Self.stepLimit) steps with the commands it calls, "
                        + "which looks like a loop. The remaining steps were not run.",
                    style: .warning
                )
                return
            }
            switch step {
            case .wait(let milliseconds):
                let later = rest
                waiting += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
                    // The steps after the wait may ask a question: not from inside a block of the main queue.
                    MainLoop.perform {
                        guard let self, chain.call.generation == self.generation else {
                            return
                        }
                        self.waiting -= 1
                        self.perform(later, chain, then: done)
                    }
                }
                return

            case .perform(let id, let written):
                // A chained command takes only what is written after its name.
                let pieces: [ExpandedPiece] =
                    chain.isChain || !written.isEmpty ? (written.isEmpty ? [] : [.text(written)]) : chain.parameters
                if let found = chained(id.rawValue) {
                    // A user command or Start-menu entry is run here: what it starts is waited
                    // for, and the values it is given stay values.
                    let later = rest
                    run(found.action, arguments: pieces, as: found.name, title: found.title, call: chain.call) {
                        [weak self] in
                        self?.perform(later, chain, then: done)
                    }
                    return
                }
                let text = ShellLine.display(pieces)
                if id.rawValue.hasPrefix(UserCommand.prefix) {
                    kernel.commands.perform(id, text.isEmpty ? .nothing : .text(text))
                } else {
                    kernel.commands.perform(id, CommandLanguage.argument(from: text, location: location))
                }

            case .changeDirectory(let path):
                let folder = path.isEmpty ? ShellWords.unquoted(ShellLine.display(chain.parameters)) : path
                guard !folder.isEmpty else { continue }
                kernel.commands.perform(.changeDirectory, .text(folder))
                // With `cd`, the start path is shown in the other panel (spec 14 › Start path).
                if !chain.startPath.isEmpty { kernel.panels.target.show(location(chain.startPath)) }

            case .external:
                let later = rest
                // The next step of a chain (`em_build, cm_RereadSource`) runs when the program has ended.
                let waits = (!later.isEmpty || done != nil) && launchesApplications
                launch(externalLine(chain.command, parameters: chain.parameters), chain, waits: waits) {
                    [weak self] started in
                    guard started else {
                        return
                    }
                    self?.perform(later, chain, then: done)
                }
                if waits {
                    return
                }

            case .unknown(let command):
                kernel.interaction.inform(
                    "Unknown command",
                    detail: "No command is called \(DisplayText.oneLine(command, limit: 80)).",
                    style: .warning
                )
            }
        }
        done?()
    }

    /// What a command of a chain is made of when it is a user command or a Start-menu entry;
    /// nil for every other command.
    private func chained(_ id: String) -> (action: CommandAction, name: String, title: String)? {
        if id.hasPrefix(UserCommand.prefix), let found = userCommand?(id) {
            return (found.action, found.name, found.caption)
        }
        if let found = startMenuEntry?(id) {
            return (found.action, id, found.title)
        }
        return nil
    }

    /// Starts a program or shell line as a process of its own, run by a login shell (so it
    /// finds the same PATH as a terminal), away from the main thread.
    ///
    /// It is no job and not in the command-line history. `completion` is called on the main thread
    /// when the process has ended (with `waits` only), telling whether it could be started; a start
    /// that fails is reported. No thread waits for the process: its end is reported by the system.
    private func launch(
        _ line: [ExpandedPiece],
        _ chain: Chain,
        waits: Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let folder = chain.startPath.isEmpty ? nil : NSString(string: chain.startPath).expandingTildeInPath
        guard launchesApplications else {
            let text = ShellLine.display(line)
            launched.append(folder.map { "cd " + ShellWords.quoted($0) + " && " + text } ?? text)
            return
        }
        let source = kernel.panels.source.model.directory
        let directory = folder ?? (source.isFileURL ? source.path : NSHomeDirectory())
        let (grace, listURL, generation, children, toMain) = (
            listGrace, chain.listURL, chain.call.generation, self.children, self.backToMain
        )
        let program = DisplayText.oneLine(ShellWords.unquoted(ShellWords.firstWord(of: line).word), limit: 80)
        if waits { waiting += 1 }
        let finished: @Sendable (String?) -> Void = { [weak self] failure in
            toMain { [weak self] in
                guard let self else {
                    return
                }
                self.removeListFile(listURL, after: grace)
                if let failure {
                    self.kernel.interaction.inform("“\(program)” cannot be started!", detail: failure, style: .warning)
                }
                // A chain the user stopped meanwhile does not go on.
                guard waits, generation == self.generation else {
                    return
                }
                self.waiting -= 1
                completion(failure == nil)
            }
        }
        // On a thread of the kernel's own: the start folder may lie on a share that does not answer.
        BlockingCalls.run {
            var isFolder: ObjCBool = false
            if let folder,
                !(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue)
            {
                return finished("The start folder \(DisplayText.oneLine(folder)) does not exist.")
            }
            let script: ShellScript
            switch ShellLine.script(Self.applicationLine(for: line) ?? line) {
            case .failure(let refusal):
                return finished(refusal.explanation)

            case .success(let made):
                script = made
            }
            let shell = LoginShell.posix
            switch ChildProcess.spawn(
                executable: shell.executable,
                arguments: shell.options + script.arguments,
                environment: LoginShell.environment(foreignPath: LoginShell.foreignPath),
                directory: directory
            )
            {
            case .failure(let failure):
                finished(failure.message)

            case .success(let pid):
                children.watch(pid, waitedFor: waits) { ending in
                    // The shell's own way of saying that it found no such program, or could not run it.
                    switch ending.status {
                    case 127:
                        finished("The shell found no program of that name (exit status 127).")

                    case 126:
                        finished("The shell could not run the program (exit status 126).")

                    default:
                        finished(nil)
                    }
                }
            }
        }
    }

    /// A line whose program is an application (`Safari.app`, or the bare name of an installed
    /// application) is opened with `open`.
    ///
    /// Nil for any other line. For a bare name the shell decides: a program of that name on the
    /// user's PATH, which only the login shell knows, comes first. Asks the disk: background only.
    nonisolated static func applicationLine(for line: [ExpandedPiece]) -> [ExpandedPiece]? {
        // The first word as a whole, also when it is quoted and has a space in it.
        let (word, rest) = ShellWords.firstWord(of: line)
        let first = ShellWords.unquoted(word)
        guard !first.isEmpty, first.unicodeScalars.first != "-" else {
            return nil
        }
        let fm = FileManager.default
        if first.lowercased().hasSuffix(".app") {
            let path = NSString(string: first).expandingTildeInPath
            let exists =
                first.contains("/")
                ? fm.fileExists(atPath: path)
                : applicationFolders.contains { fm.fileExists(atPath: $0.appendingPathComponent(first).path) }
            return exists ? [.text("/usr/bin/open -a "), .value(path)] + rest : nil
        }
        let isAlone = rest.allSatisfy { piece in
            if case .text(let text) = piece {
                return text.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
            }
            return false
        }
        guard isAlone, !first.contains("/") else {
            return nil
        }
        guard
            applicationFolders.contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(first + ".app").path) }
            )
        else { return nil }
        return [.text("if command -v "), .value(first), .text(" >/dev/null 2>&1\nthen ")] + line
            + [.text("\nelse /usr/bin/open -a "), .value(first), .text("\nfi")]
    }

    /// The same for a line as text, as text; nil for a line that is no application.
    nonisolated static func applicationLine(for line: String) -> String? {
        applicationLine(for: [.text(line)]).map(ShellLine.display)
    }

    nonisolated private static let applicationFolders: [URL] = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]
    .map { URL(fileURLWithPath: $0) }
}

/// Hands a block to the main thread through the run loop (all modes that count), not through
/// the main dispatch queue: a block that asks the user something runs a modal dialog, and a
/// dialog started from inside a block of the main queue keeps every later block of the queue
/// (directory pieces, progress) waiting until it is closed.
enum MainLoop {
    static func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        // The main run loop runs the block on the main thread.
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(block) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
