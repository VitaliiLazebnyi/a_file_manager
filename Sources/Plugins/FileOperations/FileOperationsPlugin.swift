import AFMContracts
public import AFMKernel
import AppKit
import Foundation

/// Command names only this plugin uses. The `cm_` ones are the spec's (17 › Command
/// catalogue); the `afm_` ones exist only here.
extension CommandID {
    /// Copy to the other panel, with the dialog (the spec's "Copy to other").
    internal static let copyOtherPanel: CommandID = "cm_CopyOtherpanel"
    /// F6 as a move, with the dialog.
    internal static let moveOnly: CommandID = "cm_MoveOnly"
    /// `.text`: the new name; without, the name under the cursor is edited in place, whatever is selected.
    internal static let renameSingleFile: CommandID = "cm_RenameSingleFile"
    internal static let makeDirectoryOther: CommandID = "cm_MkDirOther"
    internal static let copyWithOptions: CommandID = "afm_CopyWithOptions"
    internal static let moveWithOptions: CommandID = "afm_MoveWithOptions"
    /// Copy / move to the other panel under the same names, at once, without a dialog.
    internal static let copyNoAsk: CommandID = "afm_CopyNoAsk"
    internal static let moveNoAsk: CommandID = "afm_MoveNoAsk"
}

/// Copy, move, rename, new folder, new file and delete (spec 07 › File operations), the
/// Copy/Delete and Log file pages of the configuration, and the operation log.
public final class FileOperationsPlugin: Plugin {
    public let name = "File operations"
    private var operations: FileOperations?
    /// The text of the clipboard, for `[X]` in new names.
    private let clipboard: @Sendable () -> String?

    /// The plugin, reading the system's clipboard.
    public convenience init() {
        self.init { NSPasteboard.general.string(forType: .string) }
    }

    /// The plugin reading the clipboard through `clipboard`; tests bring a text of their own.
    internal init(clipboard: @escaping @Sendable () -> String?) {
        self.clipboard = clipboard
    }

    /// The operation log is written in bursts; this is where the last one goes out.
    ///
    /// The program is quitting and this is the main thread: a log on a volume that has stopped
    /// answering is waited for a moment and no longer.
    public func stop() {
        operations?.flushLog()
    }

    /// The log's last lines are written while the program is still there to wait for them:
    /// in the background, so that a log on a volume that has stopped answering holds up
    /// nothing but itself, and no longer than the user wants to wait (`cancellation`).
    /// `stop()` then finds nothing left to write.
    @preconcurrency
    public func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        guard let operations else {
            completion()
            return
        }
        operations.flushLog(cancellation: cancellation, completion: completion)
    }

    public func start(in owner: Kernel) {
        // The kernel keeps what is registered here; it must not be kept by it in turn.
        unowned let kernel = owner
        let operations = FileOperations(kernel, clipboard: clipboard)
        self.operations = operations
        kernel.fileSystems.addVolumeCloser { [weak operations] volume, _ in operations?.closeLog(on: volume) }
        // Some handlers run other commands; the registry keeps them, so they hold it unowned.
        unowned let commands = kernel.commands
        let source = { kernel.panels.source.model }
        let hasOperands = { source().hasOperands }
        /// Whether the folder a panel shows can be changed at all.
        let writable = { (model: PanelModel) in kernel.fileSystems.capabilities(for: model.directory).contains(.write) }
        let isWritable = { writable(source()) }
        let canMove = { hasOperands() && isWritable() }
        /// Whether something new can be made in the folder a panel shows: not where entries
        /// can only be removed (a list of files from anywhere, `.removeOnly`).
        let takesNew = { (model: PanelModel) -> Bool in
            let capabilities = kernel.fileSystems.capabilities(for: model.directory)
            return capabilities.contains(.write) && !capabilities.contains(.removeOnly)
        }

        // `.text` carries the dialog's options as switches: `/V1 O2 T="/tmp/" W="*.txt" G` (17 › Commands with parameters).
        commands.register(
            Command(.copy, "Copy…", [.f(5)], barLabel: "Copy"),
            enabled: hasOperands,
            parameterized: { argument in
                operations.transfer(.copy, switches: argument.text)
            }
        )
        commands.register(
            Command(.copyOtherPanel, "Copy to Other Panel…"),
            enabled: hasOperands,
            parameterized: { argument in
                operations.transfer(.copy, switches: argument.text)
            }
        )
        commands.register(Command(.copyWithOptions, "Copy with Options…"), enabled: hasOperands) {
            operations.transfer(.copy, dialog: .options)
        }
        commands.register(Command(.copyNoAsk, "Copy to Other Panel Now"), enabled: hasOperands) {
            operations.transfer(.copy, dialog: .none)
        }
        commands.register(Command(.copySamePanel, "Copy in Same Folder…", [.f(5, .shift)]), enabled: canMove) {
            operations.transfer(.copy, sameFolder: true)
        }
        commands.register(
            Command(.renameMove, "Rename/Move…", [.f(6)], barLabel: "Move"),
            enabled: canMove,
            parameterized: { argument in
                operations.transfer(.move, switches: argument.text)
            }
        )
        commands.register(
            Command(.moveOnly, "Move to Other Panel…"),
            enabled: canMove,
            parameterized: { argument in
                operations.transfer(.move, switches: argument.text)
            }
        )
        commands.register(Command(.moveWithOptions, "Rename/Move with Options…"), enabled: canMove) {
            operations.transfer(.move, dialog: .options)
        }
        commands.register(Command(.moveNoAsk, "Move to Other Panel Now"), enabled: canMove) {
            operations.transfer(.move, dialog: .none)
        }
        commands.register(
            Command(.renameOnly, "Rename", [.f(6, .shift)]),
            enabled: { source().cursorItem != nil && isWritable() },
            parameterized: { argument in
                if let newName = argument.text {
                    operations.renameCursorItem(to: newName)
                } else if source().selectionCount > 1 {
                    // Several items are renamed with a mask (07 › Shift+F6 with several items).
                    operations.renameSelection()
                } else {
                    // The shell owns the editor that sits on the row; it calls back with the new name.
                    commands.perform(.editNameInPlace)
                }
            }
        )
        commands.register(
            Command(.renameSingleFile, "Rename File Under Cursor"),
            enabled: { source().cursorItem != nil && isWritable() },
            parameterized: { argument in
                if let newName = argument.text {
                    operations.renameCursorItem(to: newName)
                } else {
                    commands.perform(.editNameInPlace)
                }
            }
        )
        // `.text`: the names, as typed into the dialog or as `N="…" G`; the folders are then made without asking.
        commands.register(
            Command(.makeDirectory, "New Folder…", [.f(7)], barLabel: "NewFolder"),
            enabled: { takesNew(source()) },
            parameterized: { argument in
                operations.makeDirectory(in: kernel.panels.source, names: argument.text)
            }
        )
        commands.register(
            Command(.makeDirectoryOther, "New Folder in Other Panel…", [.f(7, .shift)]),
            enabled: { takesNew(kernel.panels.target.model) },
            parameterized: { argument in
                operations.makeDirectory(in: kernel.panels.target, names: argument.text)
            }
        )
        // `.text("1")` or `.index(1)`: create the file but do not open the editor (10 › New text file).
        commands.register(
            Command(.newTextFile, "New Text File…", [.f(4, .shift)]),
            enabled: { takesNew(source()) },
            parameterized: { argument in
                operations.newTextFile(opensEditor: argument.text != "1" && argument.index != 1)
            }
        )
        commands.register(
            Command(
                .delete,
                "Move to Trash",
                [.f(8), Shortcut(.backspace, .command), Shortcut(.forwardDelete)],
                barLabel: "Delete"
            ),
            enabled: canMove
        ) { operations.delete(shifted: false) }
        commands.register(
            Command(
                .deleteDirectly,
                "Delete Permanently…",
                [.f(8, .shift), Shortcut(.backspace, [.command, .option]), Shortcut(.forwardDelete, .shift)]
            ),
            enabled: canMove
        ) { operations.delete(shifted: true) }

        kernel.menus.add([.copy, .copySamePanel, .renameMove, .renameOnly], to: .filesTransfer)
        kernel.menus.add(
            [.copyWithOptions, .moveWithOptions, .copyNoAsk, .moveNoAsk],
            to: MenuSection(.files, order: 25)
        )
        kernel.menus.add([.makeDirectory, .makeDirectoryOther, .newTextFile], to: .filesCreate)
        kernel.menus.add([.delete, .deleteDirectly], to: .filesDelete)
        kernel.menus.addToContextMenu([.copy, .renameMove, .renameOnly, .delete], in: .transfer, onItemOnly: true)
        kernel.menus.addToContextMenu([.makeDirectory, .newTextFile], in: .create)

        kernel.toolbar.add(
            .copy,
            symbol: "doc.on.doc",
            group: 20,
            hint: "Copy the selected files to the folder of the other panel."
        )
        kernel.toolbar.add(
            .renameMove,
            symbol: "arrow.right.doc.on.clipboard",
            group: 20,
            hint: "Move the selected files to the other panel's folder, or rename them."
        )
        kernel.toolbar.add(
            .makeDirectory,
            symbol: "folder.badge.plus",
            group: 20,
            hint: "Create a new folder in the current folder."
        )
        kernel.toolbar.add(
            .delete,
            symbol: "trash",
            group: 20,
            hint: "Move the selected files and folders to the Trash."
        )
        kernel.toolbar.setSymbol("doc.badge.gearshape", for: .copyWithOptions)
        kernel.toolbar.setSymbol("doc.badge.plus", for: .newTextFile)
        kernel.toolbar.setSymbol("trash.slash", for: .deleteDirectly)

        kernel.preferences.add(OperationSettings.copyDeletePage)
        kernel.preferences.add(OperationSettings.logPage)

        kernel.services.register((any FileTransferService).self, operations)
    }
}

/// The behaviour behind the commands.
///
/// It only talks to the kernel: panels, questions, jobs and file systems.
///
/// **Threading.** Commands start on the main thread and only prepare there: they read the
/// panel's state and the settings and ask the user. Everything that touches a file system runs
/// inside a job, on the job's thread; the job's completion returns to the main thread to
/// refresh the panels. The operation log writes on its own queue.
internal final class FileOperations: FileTransferService {
    /// How a copy or move learns where to go.
    internal enum Dialog {
        /// One line: the target. The common case, and as fast as it can be.
        case quick
        /// The target with every option of the job.
        case options
        /// No dialog: to the other panel under the same names.
        case none
    }

    /// What a command works on, taken on the main thread at no cost: how many items, and the
    /// first of them.
    ///
    /// The list itself is made where it is needed, on the job's thread; for a selection of several
    /// hundred thousand that is time the main thread does not have.
    internal struct Picked {
        internal let count: Int
        /// The first operand; the only one when `count` is 1.
        internal let first: FileItem?
        internal let snapshot: PanelModel.Operands

        /// The one operand as a list, for the wording of a dialog.
        internal var single: FileItem? { count == 1 ? first : nil }

        @MainActor
        internal init(_ model: PanelModel) {
            let operands = model.operandsSnapshot()
            snapshot = operands
            if operands.markedCount > 0 {
                count = operands.markedCount
                // The first mark is found by looking, not by making the list of all of them.
                first = operands.shownItems.indices.first(where: operands.isMarked).map { operands.shownItems[$0] }
            } else {
                (count, first) = (operands.cursorItem == nil ? 0 : 1, operands.cursorItem)
            }
        }

        /// The operands.
        ///
        /// For any thread.
        internal func items() -> [FileItem] { snapshot.items() }

        /// The marked operands one after another, without the list of them being made, until
        /// `body` answers false: for a loop that asks about each and may be left early.
        internal func forEach(_ body: (FileItem) -> Bool) {
            for index in snapshot.shownItems.indices where snapshot.isMarked(at: index) {
                if !body(snapshot.shownItems[index]) {
                    return
                }
            }
        }
    }

    /// What the completion of a job takes the marks off with: the places of the processed
    /// items in what the panel showed, and their names in case the panel shows something
    /// else by then.
    ///
    /// Put together on the job's thread.
    internal struct Processed {
        internal var indices: [Int] = []
        internal var names: [String] = []
        internal var shownVersion = 0

        internal init(_ completed: [URL], of picked: Picked) {
            shownVersion = picked.snapshot.shownVersion
            guard !completed.isEmpty, picked.snapshot.markedCount > 0 else {
                return
            }
            let wanted = Set(completed.map(\.locationKey))
            let shown = picked.snapshot.shownItems
            for index in picked.snapshot.markedIndices() where wanted.contains(shown[index].url.locationKey) {
                indices.append(index)
                names.append(shown[index].name)
            }
        }

        @MainActor
        internal func deselect(in model: PanelModel) {
            guard !indices.isEmpty else {
                return
            }
            if !model.setSelected(false, indices: indices, shownVersion: shownVersion) { model.deselect(names) }
        }
    }

    private struct JobRefusal: Error {
        /// Empty: there is nothing to do and nothing to say.
        let message: String
    }

    // MARK: Jobs

    /// How long the end of the program waits for the log's last lines.
    internal static let logFlushTimeout: TimeInterval = 2

    /// Unowned: the kernel owns the plugin, and through it this.
    private unowned let kernel: Kernel
    /// The log as last configured; made again when the configuration page changed something.
    private var log: OperationLog? {
        didSet {
            logLock.lock()
            sharedLog = log
            logLock.unlock()
        }
    }
    /// `log` for the thread that ejects a volume, which may be the one the log is written to.
    private let logLock = NSLock()
    /// Guarded by `logLock`.
    nonisolated(unsafe) private var sharedLog: OperationLog?

    /// The text of the clipboard, for `[X]`; read on a job's thread, only when a name asks for it (another program
    /// may hand its text over slowly).
    private let clipboard: @Sendable () -> String?

    private var source: any PanelHandle { kernel.panels.source }
    private var target: any PanelHandle { kernel.panels.target }
    private var ui: any UserInteraction { kernel.interaction }
    private var fileSystems: FileSystemRegistry { kernel.fileSystems }

    internal init(_ kernel: Kernel, clipboard: @escaping @Sendable () -> String?) {
        self.kernel = kernel
        self.clipboard = clipboard
    }

    /// The panel's names of the items a job processed.
    ///
    /// In a branch or list view a name is a path, not the last component of the item's location, so
    /// the items are matched by URL.
    internal static func names(of processed: [URL], among items: [FileItem]) -> [String] {
        var wanted = Set(processed.map(\.locationKey))
        guard !wanted.isEmpty else {
            return []
        }
        var names: [String] = []
        for item in items where wanted.remove(item.url.locationKey) != nil { names.append(item.name) }
        return names
    }

    /// Job thread: a log written to `volume` writes what it has and closes its file, so the
    /// volume can be ejected.
    ///
    /// The next line opens it again.
    nonisolated internal func closeLog(on volume: URL) {
        logLock.lock()
        let log = sharedLog
        logLock.unlock()
        guard let log else {
            return
        }
        let file = log.configuration.file
        if file.isSameLocation(as: volume) || file.isInside(volume) { log.flush() }
    }

    internal func flushLog() {
        log?.flush(timeout: Self.logFlushTimeout)
    }

    /// Writes what the log still holds, off the calling thread; `completion` is called once,
    /// on some thread, when it is written or `cancellation` was set.
    internal func flushLog(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        guard let log else {
            completion()
            return
        }
        log.flush(cancellation: cancellation, completion: completion)
    }

    /// Where a job's records go: nil while the log is switched off.
    private func recorder() -> (@Sendable (OperationRecord) -> Void)? {
        let configuration = OperationSettings.logConfiguration(from: kernel.settings)
        guard configuration.isEnabled else {
            return nil
        }
        let current: OperationLog
        if let log, log.configuration == configuration {
            current = log
        } else {
            current = OperationLog(configuration)
            log = current
        }
        return { current.write($0) }
    }

    /// Which records the log is going to keep, so that a job makes no others.
    private func recordFilter() -> (@Sendable (OperationRecord.Verb, OperationRecord.Status) -> Bool)? {
        let configuration = OperationSettings.logConfiguration(from: kernel.settings)
        guard configuration.isEnabled else {
            return nil
        }
        return { configuration.wants($0, $1) }
    }

    /// Runs `makeJob` and the job it returns on the job thread, with the progress window; the
    /// job's questions are asked through the kernel. `makeJob` may refuse with a message.
    /// `summary` turns the job's result into what the completion needs while still on the job
    /// thread (the names to deselect, the folders to re-read: work that grows with the
    /// selection), so that the completion on the main thread only applies it.
    private func run<Summary: Sendable>(
        title: String,
        makeJob: @escaping @Sendable (CancellationFlag) -> Result<FileJob, JobRefusal>,
        summary: @escaping @Sendable (JobResult) -> Summary,
        completion: @escaping @MainActor (JobResult, Summary) -> Void
    ) {
        let ui = kernel.interaction
        let fileSystems = kernel.fileSystems
        let record = recorder()
        let wantsRecord = recordFilter()
        let log = self.log
        kernel.jobs.run(
            title: title,
            work: { monitor -> (JobResult, Summary) in
                var result: JobResult
                switch makeJob(monitor.cancellation) {
                case .failure(let refusal):
                    result = JobResult(refusal: refusal.message)

                case .success(let job):
                    let bridge = JobBridge(monitor: monitor, ui: ui, fileSystems: fileSystems)
                    job.delegate = bridge
                    job.onRecord = record
                    job.wantsRecord = wantsRecord
                    // A window is redrawn a few dozen times a second at most; more reports are wasted.
                    job.progressInterval = 0.04
                    // The job holds its delegate weakly; the bridge must live as long as the job runs.
                    result = withExtendedLifetime(bridge) { job.run() }
                }
                return (result, summary(result))
            },
            completion: { [ui] result, summary in
                log?.flushSoon()
                if let refusal = result.refusal, !refusal.isEmpty { ui.inform(refusal, detail: "", style: .warning) }
                completion(result, summary)
            }
        )
    }

    /// Where relative targets of an operation in `directory` count from: the real folder
    /// behind a branch view; for a list of files from anywhere, which has no folder of its
    /// own, the folder of the first item.
    private func base(of directory: URL, first: FileItem) -> URL {
        let real = RealLocation.resolve(directory, in: fileSystems)
        if RealLocation.takesNames(real, in: fileSystems) {
            return real
        }
        return first.url.deletingLastPathComponent()
    }

    /// With "keep going on errors" nobody was asked while the job ran; the user hears of the
    /// failures now.
    private func reportFailures(of result: JobResult, options: TransferOptions) {
        guard options.skipsErrors, result.failureCount > 0 else {
            return
        }
        let more = result.failureCount > result.failures.count ? "\n…" : ""
        ui.inform(
            "\(result.failureCount) item(s) could not be processed.",
            detail: result.failures.joined(separator: "\n") + more,
            style: .warning
        )
    }

    /// Copy and move (spec 07 › Copy dialog, Target field, Rename and move). `switches` are
    /// the dialog's options as a command line would give them; `G` among them starts at once.
    internal func transfer(
        _ kind: TransferKind,
        sameFolder: Bool = false,
        dialog: Dialog = .quick,
        switches text: String? = nil
    ) {
        // What the command works on is fixed now; the panels may show something else by the
        // time the job ends.
        withOperands { picked, first in
            transfer(kind, picked, first: first, sameFolder: sameFolder, dialog: dialog, switches: text)
        }
    }

    /// The operands of a command and the first of them.
    ///
    /// The commands are offered only where there are operands.
    private func withOperands(_ body: (Picked, FileItem) -> Void) {
        let picked = Picked(source.model)
        if let first = picked.first {
            body(picked, first)
        }
    }

    private func transfer(
        _ kind: TransferKind,
        _ picked: Picked,
        first: FileItem,
        sameFolder: Bool,
        dialog: Dialog,
        switches text: String?
    ) {
        let model = source.model
        let panelDirectory = model.directory
        // A branch view shows the files of a real folder under a location of its own. Targets
        // are read and written in terms of the real one, or a second spelling of one place
        // would come into the job.
        let sourceDirectory = base(of: panelDirectory, first: first)
        let targetPanelDirectory = RealLocation.resolve(target.model.directory, in: fileSystems)
        let verb = kind == .copy ? "Copy" : "Rename/Move"
        let switches = CommandSwitches.parse(text ?? "")
        var options = OperationSettings.options(from: kernel.settings)
        if let verify = switches["V"] { options.verifies = verify != "0" }
        if let mode = switches["O"].flatMap({ Int($0) }) {
            options.overwrite = OverwriteMode(rawValue: max(0, mode - 1)) ?? .ask
        }
        if let skip = switches["S"] { options.skipsErrors = skip != "0" }
        if let ignore = switches["H"] { options.ignoresProtection = ignore != "0" }
        if let filter = switches["W"] { options.filter = CopyFilter(filter) }
        // A list of files from anywhere is no folder: nothing can be put "into" it, and its
        // name with a file name after it would read as a folder to create. The proposal is
        // then the name alone, as for a copy within the source folder.
        let hasTargetFolder = !sameFolder && RealLocation.takesNames(targetPanelDirectory, in: fileSystems)
        let targetPath = hasTargetFolder ? fileSystems.displayPath(targetPanelDirectory) : nil
        var targetText =
            switches["T"]
            ?? OperationText.targetProposal(count: picked.count, single: picked.single, targetPath: targetPath)

        var dialog = switches["G"].map { $0 != "0" } == true ? .none : dialog
        if dialog == .quick, !sameFolder, kernel.settings.flag(OperationSettings.alwaysOptions, default: false) {
            dialog = .options
        }
        let heading = OperationText.heading(verb, count: picked.count, single: picked.single)
        let proposedTarget = targetText
        switch dialog {
        case .none:
            break

        case .quick:
            let hint =
                !hasTargetFolder
                ? ""
                : "A name or a mask such as *.bak renames. More choices: Files › \(kind == .copy ? "Copy" : "Rename/Move") with Options…"
            guard let text = ui.prompt(heading, value: targetText, detail: hint) else {
                return
            }
            targetText = text

        case .options:
            guard let answer = askForOptions(heading, kind: kind, target: targetText, options: &options) else {
                return
            }
            targetText = answer
        }
        // A target the user typed into the dialog is the user's own choice of a server, if it names one.
        if dialog != .none {
            kernel.userTyped(location: targetText, relativeTo: sourceDirectory, proposal: proposedTarget)
        }

        model.saveSelection()
        // Found on the job's thread, read by the completion.
        let targetDirectory = Guarded<URL?>(nil)
        let fileSystems = self.fileSystems
        let jobOptions = options
        run(
            title: kind == .copy ? "Copy:" : "Rename/Move:",
            makeJob: { [targetText] cancellation in
                let spec = TargetSpec.parse(
                    targetText,
                    sourceDirectory: sourceDirectory,
                    operandCount: picked.count,
                    fileSystems: fileSystems,
                    cancellation: cancellation
                )
                if cancellation.isCancelled {
                    return .failure(JobRefusal(message: ""))
                }
                let job = FileJob(
                    kind: .transfer(kind),
                    sources: picked.items().map(\.url),
                    target: spec,
                    fileSystems: fileSystems,
                    cancellation: cancellation
                )
                job.options = jobOptions
                if job.targetsSourceFolder {
                    return .failure(JobRefusal(message: "You cannot copy a file to itself!"))
                }
                do {
                    // A target folder that does not exist is created silently.
                    try fileSystems.provider(for: spec.directory)
                        .createDirectory(
                            at: spec.directory,
                            cancellation: cancellation
                        )
                } catch {
                    if cancellation.isCancelled {
                        return .failure(JobRefusal(message: ""))
                    }
                    return .failure(
                        JobRefusal(
                            message: "The given target path \(fileSystems.displayPath(spec.directory)) is invalid!"
                        )
                    )
                }
                targetDirectory.withLock { $0 = spec.directory }
                return .success(job)
            },
            summary: { result in
                Processed(result.completed, of: picked)
            },
            completion: { [self] result, processed in
                processed.deselect(in: model)
                reportFailures(of: result, options: jobOptions)
                // After a copy or rename in the same folder the cursor goes to the new item.
                var folders = [panelDirectory]
                if !sourceDirectory.isSameLocation(as: panelDirectory) { folders.append(sourceDirectory) }
                kernel.panels.refresh(
                    folders + (targetDirectory.withLock { $0 }.map { [$0] } ?? []),
                    focus: result.lastTarget
                )
            }
        )
    }

    /// The Copy dialog with its options (spec 07 › Copy dialog, Advanced options).
    ///
    /// The second button also stores the choices as the defaults of the configuration. Returns the
    /// target.
    private func askForOptions(_ heading: String, kind: TransferKind, target: String, options: inout TransferOptions)
        -> String?
    {
        var fields: [FormField] = [
            .text("target", heading, target),
            .text("filter", "Only files of this type:", ""),
            .note("Masks separated by spaces, exclusions after |, folders end in /:   *.txt *.md | *.bak build/"),
            .choice(
                "overwrite",
                "Overwrite options:",
                OverwriteMode.allCases.map(\.title),
                selected: options.overwrite.rawValue
            ),
            .checkbox("attributes", "Keep dates and permissions", options.preservesAttributes),
            .checkbox("folderDates", "Copy date/time of folders", options.preservesFolderDates)
        ]
        if kind == .copy {
            fields.append(
                .choice("links", "Symbolic links:", OperationSettings.linkTitles, selected: options.links.rawValue)
            )
        }
        fields += [
            .checkbox("verify", "Verify (compare checksums after copying)", options.verifies),
            .checkbox("skipErrors", "Keep going on errors (skip what fails, report at the end)", options.skipsErrors),
            .checkbox(
                "ignoreProtection",
                "Overwrite/delete read-only and hidden files without asking",
                options.ignoresProtection
            )
        ]
        guard
            let answer = ui.form(
                kind == .copy ? "Copy" : "Rename/Move",
                detail: "",
                fields: fields,
                buttons: ["OK", "OK, Keep as Defaults"]
            )
        else {
            return nil
        }
        options.filter = CopyFilter(answer.text("filter"))
        options.overwrite = OverwriteMode(rawValue: answer.index("overwrite")) ?? .ask
        options.preservesAttributes = answer.flag("attributes")
        options.preservesFolderDates = answer.flag("folderDates")
        if kind == .copy { options.links = LinkHandling(rawValue: answer.index("links")) ?? .copyLinks }
        options.verifies = answer.flag("verify")
        options.skipsErrors = answer.flag("skipErrors")
        options.ignoresProtection = answer.flag("ignoreProtection")
        if answer.button == 1 {
            let settings = kernel.settings
            settings.set(options.overwrite.rawValue, forKey: OperationSettings.overwrite)
            settings.set(options.preservesAttributes, forKey: OperationSettings.attributes)
            settings.set(options.preservesFolderDates, forKey: OperationSettings.folderDates)
            settings.set(options.links.rawValue, forKey: OperationSettings.links)
            settings.set(options.verifies, forKey: OperationSettings.verify)
            settings.set(options.skipsErrors, forKey: OperationSettings.skipErrors)
        }
        return answer.text("target")
    }

    /// F8 moves to the Trash where the file system has one; elsewhere, and with Shift, it
    /// deletes directly.
    ///
    /// The configuration can turn the two around (spec 07 › Recycle bin or direct deletion).
    internal func delete(shifted: Bool) {
        withOperands { picked, _ in delete(picked, shifted: shifted) }
    }

    private func delete(_ picked: Picked, shifted: Bool) {
        let model = source.model
        let directory = model.directory
        // What the folder says for all it shows: a view of several folders answers with what
        // every one of them can do, so the items are not asked about one by one.
        let hasTrash = fileSystems.capabilities(for: directory).contains(.trash)
        let toTrash = hasTrash && kernel.settings.flag(OperationSettings.useTrash, default: true) != shifted
        // What goes to the Trash can be taken out again, and Return says yes. What is
        // deleted for good cannot: there Return says no, and yes has to be chosen.
        let answer = ui.choose(
            toTrash ? kernel.productName : "Permanently delete",
            detail: OperationText.deleteQuestion(count: picked.count, single: picked.single, toTrash: toTrash),
            buttons: ["Yes", "No"],
            style: toTrash ? .information : .critical,
            defaultButton: toTrash ? 0 : 1
        )
        guard answer == 0 else {
            return
        }
        model.saveSelection()
        let fileSystems = self.fileSystems
        let options = OperationSettings.options(from: kernel.settings)
        run(
            title: "Deleting:",
            makeJob: { cancellation in
                let job = FileJob(
                    kind: .delete(toTrash: toTrash),
                    sources: picked.items().map(\.url),
                    fileSystems: fileSystems,
                    cancellation: cancellation
                )
                job.options = options
                return .success(job)
            },
            summary: { result in
                Processed(result.completed, of: picked)
            },
            completion: { [self] result, processed in
                processed.deselect(in: model)
                reportFailures(of: result, options: options)
                kernel.panels.refresh([directory])
            }
        )
    }

    // FileTransferService
    internal func transfer(
        _ kind: TransferKind,
        _ sources: [URL],
        into directory: URL,
        renamingSelfCopies: Bool,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        let fileSystems = self.fileSystems
        var options = OperationSettings.options(from: kernel.settings)
        // Whoever uses the service gets the questions, not the dialog's presets.
        options.overwrite = .ask
        options.skipsErrors = false
        let jobOptions = options
        run(
            title: kind == .move ? "Rename/Move:" : "Copy:",
            makeJob: { cancellation in
                // The folder as it really is: a branch view names a real folder in its own way.
                let real = RealLocation.resolve(directory, in: fileSystems)
                guard RealLocation.takesNames(real, in: fileSystems) else {
                    return .failure(
                        JobRefusal(
                            message:
                                "\(fileSystems.displayPath(real)) is a list of files, not a folder. Nothing can be put into it."
                        )
                    )
                }
                // Moving a file into the folder it is in already changes nothing, and is not tried.
                var moved = sources
                if kind == .move {
                    let key = real.locationKey
                    moved = sources.filter { $0.deletingLastPathComponent().locationKey != key }
                }
                guard !moved.isEmpty else {
                    return .failure(JobRefusal(message: ""))
                }
                let job = FileJob(
                    kind: .transfer(kind),
                    sources: moved,
                    target: TargetSpec(directory: real),
                    fileSystems: fileSystems,
                    cancellation: cancellation
                )
                job.options = jobOptions
                job.renamesSelfCopies = renamingSelfCopies
                return .success(job)
            },
            summary: { _ -> [URL] in
                var seen = Set<String>()
                return ([directory] + sources.map { $0.deletingLastPathComponent() })
                    .filter {
                        seen.insert($0.locationKey).inserted
                    }
            },
            completion: { [kernel] result, folders in
                kernel.panels.refresh(folders, focus: result.lastTarget)
                completion(result.lastTarget)
            }
        )
    }

    // MARK: Rename

    /// Runs a quick change of the file system off the main thread and comes back with its
    /// error, if any.
    private func change(
        _ title: String,
        _ work: @escaping @Sendable (CancellationFlag) throws -> Void,
        then completion: @escaping @MainActor (any Error?) -> Void
    ) {
        kernel.jobs.run(
            title: title,
            work: { monitor -> any Error? in
                do {
                    try work(monitor.cancellation)
                    return nil
                } catch {
                    return error
                }
            },
            completion: completion
        )
    }

    /// Finishes an in-place rename; the cursor follows the renamed item.
    internal func renameCursorItem(to newName: String) {
        let model = source.model
        guard let item = model.cursorItem, !newName.isEmpty, newName != item.name else {
            return
        }
        let directory = model.directory
        let destination = item.url.deletingLastPathComponent().appending(name: newName)
        let fileSystems = self.fileSystems
        let record = recorder()
        change(
            "Renaming:",
            { cancellation in
                let display = (fileSystems.displayPath(item.url), fileSystems.displayPath(destination))
                do {
                    guard !newName.contains("/") else { throw FileJobError.targetIsFile(newName) }
                    let provider = try fileSystems.provider(for: item.url)
                    do {
                        try provider.move(item.url, to: destination, replacing: false, cancellation: cancellation)
                    } catch FileSystemError.alreadyExists where FileIdentity.sameEntry(item.url, destination) {
                        // The name is taken by the file itself (a volume that cannot rename exclusively
                        // and looks at letter case only): a rename onto the same file, no conflict. A
                        // different file under the other case is never replaced.
                        try provider.move(item.url, to: destination, replacing: true, cancellation: cancellation)
                    }
                    record?(OperationRecord(.rename, source: display.0, target: display.1))
                } catch {
                    record?(
                        OperationRecord(
                            .rename,
                            source: display.0,
                            target: display.1,
                            status: .failed(error.localizedDescription)
                        )
                    )
                    throw error
                }
            },
            then: { [kernel] error in
                // Stopped by the user: nothing to tell.
                if let error, (error as? CocoaError)?.code != .userCancelled {
                    kernel.interaction.report(error, title: "\(DisplayName.escaped(item.name)) cannot be renamed!")
                }
                kernel.panels.refresh([directory], focus: error == nil ? destination : item.url)
            }
        )
    }

    /// Shift+F6 with several items: a wildcard mask for all, or a new name for each in turn
    /// (spec 07 › Shift+F6 with several items).
    ///
    /// Name conflicts get the Overwrite dialog.
    internal func renameSelection() {
        withOperands { picked, first in renameSelection(picked, first: first) }
    }

    private func renameSelection(_ picked: Picked, first firstItem: FileItem) {
        let model = source.model
        let directory = model.directory
        guard
            let answer = ui.form(
                "Rename",
                detail: "",
                fields: [
                    .text("mask", "Rename \(picked.count) file(s) to", "*.*"),
                    .note("A mask as in the Copy dialog: *.bak, new_*.*, ?x*.*"),
                    .checkbox("each", "Rename each file separately", false)
                ],
                buttons: ["OK"]
            )
        else { return }
        // With a mask the names are worked out on the job's thread: one per item of the selection.
        var names: [(URL, String)] = []
        var mask = ""
        if answer.flag("each") {
            // One question per item, so the items are taken one by one: the list of a long
            // selection is not made for a round of questions that is given up after a few.
            var wasGivenUp = false
            picked.forEach { item in
                // A branch view names its items by their paths; the name to change is the last part.
                let old = item.url.lastPathComponent
                guard
                    let name = ui.prompt("Rename \"\(DisplayName.escaped(item.name))\" to", value: old)?
                        .trimmingCharacters(in: .whitespaces)
                else {
                    wasGivenUp = true
                    return false
                }
                if name != old, FileJob.isSafeName(name) { names.append((item.url, name)) }
                return true
            }
            guard !wasGivenUp, !names.isEmpty else {
                return
            }
        } else {
            mask = answer.text("mask").trimmingCharacters(in: .whitespaces)
            guard !mask.isEmpty, !mask.contains("/") else {
                return
            }
        }
        let typed = names
        model.saveSelection()
        let fileSystems = self.fileSystems
        let options = OperationSettings.options(from: kernel.settings)
        // One job for all of them: every item is renamed where it lies (in a branch view that
        // is not one folder), an answer "for all" holds for all, and two items that would get
        // one name are noticed.
        run(
            title: "Rename/Move:",
            makeJob: { [mask] cancellation in
                let names =
                    !mask.isEmpty
                    ? picked.items().map { ($0.url, TargetMask.apply(mask, to: $0.url.lastPathComponent)) }
                        .filter { $0.0.lastPathComponent != $0.1 && FileJob.isSafeName($0.1) }
                    : typed
                // Nothing gets another name: nothing to do and nothing to say.
                guard !names.isEmpty else {
                    return .failure(JobRefusal(message: ""))
                }
                let job = FileJob(
                    kind: .move,
                    sources: names.map(\.0),
                    target: TargetSpec(directory: firstItem.url.deletingLastPathComponent()),
                    fileSystems: fileSystems,
                    cancellation: cancellation
                )
                // Every item once; were one named twice, its first name would hold.
                var newNames: [String: String] = [:]
                for (url, name) in names.reversed() {
                    newNames[url.locationKey] = name
                }
                job.newNames = newNames
                job.options = options
                return .success(job)
            },
            summary: { result in
                Processed(result.completed, of: picked)
            },
            completion: { [kernel] _, processed in
                processed.deselect(in: model)
                kernel.panels.refresh([directory])
            }
        )
    }

    // MARK: New folder, new file

    /// What the placeholders of a new name refer to (spec 18 › Rename and new-folder
    /// placeholders): the item under the cursor, the folder, the moment the dialog opened.
    private func nameContext(for panel: any PanelHandle, typed _: String, openedAt: Date) -> NameTemplate.Context {
        let model = panel.model
        var context = NameTemplate.Context()
        if let item = source.model.cursorItem {
            context.cursorName = item.name
            context.cursorIsFolder = item.isFolder
            context.cursorSize = item.size
        }
        context.parentName = model.directory.lastPathComponent
        context.grandparentName = model.directory.deletingLastPathComponent().lastPathComponent
        context.now = openedAt
        return context
    }

    /// F7 and Shift+F7 (spec 07 › New folder). `names` given: no dialog; it is the text of the
    /// dialog or the command's switches (`N="a|b"`).
    internal func makeDirectory(in panel: any PanelHandle, names given: String?) {
        let directory = panel.model.directory
        let openedAt = Date()
        let typed: String
        if let given {
            let switches = CommandSwitches.parse(given)
            typed = given.contains("=") ? (switches["N"] ?? "") : given
        } else {
            // Pre-filled with the name under the cursor, so similar names are easy to type.
            guard
                let text = ui.prompt(
                    "New folder (directory)",
                    value: source.model.cursorItem?.name ?? "",
                    detail: "a/b/c nests, | separates several. With a leading < placeholders work: "
                        + "<[Y]-[M]-[D] notes, <Copy of [N], <1-10>Part [C], <new[C] (first free name)."
                )
            else { return }
            typed = text
        }
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let context = nameContext(for: panel, typed: typed, openedAt: openedAt)
        let (fileSystems, clipboard) = (self.fileSystems, self.clipboard)
        let record = recorder()
        kernel.jobs.run(
            title: "New folder:",
            work: { monitor -> (created: URL?, failures: [(String, any Error)]) in
                let cancellation = monitor.cancellation
                var context = context
                /// Whether something is at a location, asked so that the question ends with the job.
                @Sendable
                func exists(_ url: URL) -> Bool {
                    (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation) != nil
                }
                var created: URL?
                var failures: [(String, any Error)] = []
                context.clipboard = typed.contains("[X") ? clipboard() : nil
                context.exists = { exists(fileSystems.location(from: $0, relativeTo: directory)) }
                let names: [String]
                do {
                    names = try NameTemplate.names(from: typed, context: context)
                } catch {
                    return (nil, [(typed, error)])
                }
                for name in names where !cancellation.isCancelled {
                    let url = fileSystems.location(from: name, relativeTo: directory)
                    do {
                        if exists(url) { throw FileSystemError.alreadyExists(fileSystems.displayPath(url)) }
                        // A folder that appeared since the look above is not taken for the new one.
                        try fileSystems.provider(for: url)
                            .createDirectory(
                                at: url,
                                exclusive: true,
                                cancellation: cancellation
                            )
                        created = url
                        record?(OperationRecord(.makeFolder, source: fileSystems.displayPath(url)))
                    } catch {
                        if cancellation.isCancelled { break }
                        failures.append((name, error))
                        record?(
                            OperationRecord(
                                .makeFolder,
                                source: fileSystems.displayPath(url),
                                status: .failed(error.localizedDescription)
                            )
                        )
                    }
                }
                return (created, failures)
            },
            completion: { [kernel] result in
                for (name, error) in result.failures {
                    kernel.interaction.report(
                        error,
                        title: "The folder \(DisplayName.escaped(name)) cannot be created!"
                    )
                }
                // The cursor goes to the last new folder, or to the top of a nested one.
                var focus: URL?
                if let created = result.created, created.isInside(directory) {
                    let top = created.pathComponents.dropFirst(directory.pathComponents.count).first
                    focus = top.map(directory.appendingPathComponent)
                }
                kernel.panels.refresh([directory], focus: focus)
            }
        )
    }

    /// Shift+F4 (spec 10 › New text file): the names follow the rules of new folders; several
    /// names create several files and do not start the editor.
    internal func newTextFile(opensEditor: Bool = true) {
        let model = source.model
        let directory = model.directory
        let openedAt = Date()
        guard
            let typed = ui.prompt(
                "New text file:",
                value: model.cursorFile?.name ?? "",
                detail: "| or quotes separate several files; a leading < turns on placeholders and ranges."
            )?
            .trimmingCharacters(in: .whitespaces), !typed.isEmpty
        else { return }
        let context = nameContext(for: source, typed: typed, openedAt: openedAt)
        let (fileSystems, clipboard) = (self.fileSystems, self.clipboard)
        let record = recorder()
        kernel.jobs.run(
            title: "New file:",
            work: { monitor -> (urls: [URL], failure: (String, any Error)?) in
                let cancellation = monitor.cancellation
                var context = context
                @Sendable
                func exists(_ url: URL) -> Bool {
                    (try? fileSystems.provider(for: url))?.item(at: url, cancellation: cancellation) != nil
                }
                context.clipboard = typed.contains("[X") ? clipboard() : nil
                context.exists = { exists(fileSystems.location(from: $0, relativeTo: directory)) }
                var urls: [URL] = []
                do {
                    for name in try NameTemplate.names(from: typed, context: context, quotedLists: true) {
                        let url = fileSystems.location(from: name, relativeTo: directory)
                        do {
                            // An existing file is simply opened.
                            if !exists(url) {
                                if cancellation.isCancelled {
                                    return (urls, nil)
                                }
                                let provider = try fileSystems.provider(for: url)
                                try provider.createDirectory(
                                    at: url.deletingLastPathComponent(),
                                    cancellation: cancellation
                                )
                                try provider.write(url, cancellation: cancellation).close(attributes: FileAttributes())
                                record?(OperationRecord(.newFile, source: fileSystems.displayPath(url)))
                            }
                            urls.append(url)
                        } catch {
                            if cancellation.isCancelled {
                                return (urls, nil)
                            }
                            record?(
                                OperationRecord(
                                    .newFile,
                                    source: fileSystems.displayPath(url),
                                    status: .failed(error.localizedDescription)
                                )
                            )
                            return (urls, (name, error))
                        }
                    }
                } catch {
                    return (urls, (typed, error))
                }
                return (urls, nil)
            },
            completion: { [kernel] result in
                if let (name, error) = result.failure {
                    kernel.interaction.report(error, title: "The file \(DisplayName.escaped(name)) cannot be created!")
                }
                guard let last = result.urls.last else {
                    return
                }
                kernel.panels.refresh([directory], focus: last)
                // One new file opens in the editor, when a plugin provides one.
                if result.urls.count == 1, result.failure == nil, opensEditor, kernel.commands[.edit] != nil {
                    kernel.commands.perform(.edit, .location(last))
                }
            }
        )
    }
}
