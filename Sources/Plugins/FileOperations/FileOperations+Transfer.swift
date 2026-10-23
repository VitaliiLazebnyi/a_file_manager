import AFMContracts
import AFMKernel
import Foundation

/// Copy and move: the dialogs, the job, and the transfer service other plugins use.
extension FileOperations {
    /// A copy or a move as the dialog left it, to be turned into a job on the job's thread.
    internal struct TransferPlan: Sendable {
        /// Copy or move.
        internal let kind: TransferKind
        /// The target field as typed: a folder, a name or a mask.
        internal let target: String
        /// Where relative targets count from.
        internal let sourceDirectory: URL
        /// What is copied or moved.
        internal let picked: Picked
        /// The options of the job.
        internal let options: TransferOptions

        /// The job, or why there is none; `targetDirectory` is set to the folder the items go to.
        ///
        /// Job thread: reading the target looks at the file system, and a missing target folder is created.
        internal func makeJob(
            _ cancellation: CancellationFlag,
            in fileSystems: FileSystemRegistry,
            noting targetDirectory: Guarded<URL?>
        ) -> Result<FileJob, JobRefusal> {
            let spec = TargetSpec.parse(
                target,
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
            job.options = options
            if job.targetsSourceFolder {
                return .failure(JobRefusal(message: "You cannot copy a file to itself!"))
            }
            do {
                // A target folder that does not exist is created silently.
                try fileSystems.provider(for: spec.directory)
                    .createDirectory(at: spec.directory, cancellation: cancellation)
            } catch {
                if cancellation.isCancelled {
                    return .failure(JobRefusal(message: ""))
                }
                let path = fileSystems.displayPath(spec.directory)
                return .failure(JobRefusal(message: "The given target path \(path) is invalid!"))
            }
            targetDirectory.withLock { $0 = spec.directory }
            return .success(job)
        }
    }

    /// A copy or a move as the command asked for it, before its operands are taken.
    private struct TransferRequest {
        /// Copy or move.
        let kind: TransferKind
        /// A copy within the source folder (Shift+F5): no folder of the other panel is proposed.
        let sameFolder: Bool
        /// The dialog the command opens.
        let dialog: Dialog
        /// The dialog's options as a command line gives them; `G` among them starts at once.
        let switches: [Character: String]
    }

    /// The question of a transfer dialog: its heading, the proposed target and the hint below it.
    private struct TargetQuestion {
        /// `Copy "name" to` or `Copy N file(s) to`.
        let heading: String
        /// The target the field starts with.
        let proposal: String
        /// The hint under the field; empty for none.
        let hint: String
    }

    /// The options of a job: the configuration's, changed by the command's switches.
    private static func options(_ configured: TransferOptions, with switches: [Character: String]) -> TransferOptions {
        var options = configured
        if let verify = switches["V"] { options.verifies = verify != "0" }
        if let mode = switches["O"].flatMap({ Int($0) }) {
            options.overwrite = OverwriteMode(rawValue: max(0, mode - 1)) ?? .ask
        }
        if let skip = switches["S"] { options.skipsErrors = skip != "0" }
        if let ignore = switches["H"] { options.ignoresProtection = ignore != "0" }
        if let filter = switches["W"] { options.filter = CopyFilter(filter) }
        return options
    }

    /// The fields of the Copy dialog with its options, filled in from `options`.
    private static func optionFields(_ heading: String, kind: TransferKind, target: String, options: TransferOptions)
        -> [FormField]
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
        return fields
    }

    /// Copy and move (spec 07 › Copy dialog, Target field, Rename and move). `switches` are
    /// the dialog's options as a command line would give them; `G` among them starts at once.
    internal func transfer(_ kind: TransferKind, sameFolder: Bool, dialog: Dialog, switches text: String?) {
        // What the command works on is fixed now; the panels may show something else by the
        // time the job ends.
        let request = TransferRequest(
            kind: kind,
            sameFolder: sameFolder,
            dialog: dialog,
            switches: CommandSwitches.parse(text ?? "")
        )
        withOperands { picked, first in
            transfer(request, picked, first: first)
        }
    }

    /// The transfer of `picked`: asks where to, then runs the job.
    private func transfer(_ request: TransferRequest, _ picked: Picked, first: FileItem) {
        let (kind, switches) = (request.kind, request.switches)
        let model = source.model
        // A branch view shows the files of a real folder under a location of its own. Targets
        // are read and written in terms of the real one, or a second spelling of one place
        // would come into the job.
        let sourceDirectory = base(of: model.directory, first: first)
        var options = Self.options(OperationSettings.options(from: kernel.settings), with: switches)
        var dialog = switches["G"].map { $0 != "0" } == true ? .immediate : request.dialog
        if dialog == .quick, !request.sameFolder,
            kernel.settings.flag(OperationSettings.alwaysOptions, default: false)
        {
            dialog = .options
        }
        let question = targetQuestion(kind, picked, sameFolder: request.sameFolder, switches: switches)
        guard let target = askForTarget(question, dialog: dialog, kind: kind, options: &options) else {
            return
        }
        // A target the user typed into the dialog is the user's own choice of a server, if it names one.
        if dialog != .immediate {
            kernel.userTyped(location: target, relativeTo: sourceDirectory, proposal: question.proposal)
        }
        model.saveSelection()
        let plan = TransferPlan(
            kind: kind,
            target: target,
            sourceDirectory: sourceDirectory,
            picked: picked,
            options: options
        )
        start(plan, from: model)
    }

    /// What the dialog of a transfer asks, and the target it proposes: the `T` switch, or the
    /// other panel's folder.
    private func targetQuestion(
        _ kind: TransferKind,
        _ picked: Picked,
        sameFolder: Bool,
        switches: [Character: String]
    ) -> TargetQuestion {
        let targetPanelDirectory = RealLocation.resolve(target.model.directory, in: fileSystems)
        // A list of files from anywhere is no folder: nothing can be put "into" it, and its
        // name with a file name after it would read as a folder to create. The proposal is
        // then the name alone, as for a copy within the source folder.
        let hasTargetFolder = !sameFolder && RealLocation.takesNames(targetPanelDirectory, in: fileSystems)
        let targetPath = hasTargetFolder ? fileSystems.displayPath(targetPanelDirectory) : nil
        let verb = kind == .copy ? "Copy" : "Rename/Move"
        return TargetQuestion(
            heading: OperationText.heading(verb, count: picked.count, single: picked.single),
            proposal: switches["T"]
                ?? OperationText.targetProposal(count: picked.count, single: picked.single, targetPath: targetPath),
            hint: hasTargetFolder
                ? "A name or a mask such as *.bak renames. More choices: Files › \(verb) with Options…" : ""
        )
    }

    /// The target as the dialog comes back with it; the proposal without a dialog, nil when the
    /// user cancelled.
    private func askForTarget(
        _ question: TargetQuestion,
        dialog: Dialog,
        kind: TransferKind,
        options: inout TransferOptions
    ) -> String? {
        switch dialog {
        case .immediate:
            return question.proposal

        case .quick:
            return interaction.prompt(question.heading, value: question.proposal, detail: question.hint)

        case .options:
            return askForOptions(question.heading, kind: kind, target: question.proposal, options: &options)
        }
    }

    /// Runs the job of `plan`; the panels are re-read when it ends.
    private func start(_ plan: TransferPlan, from model: PanelModel) {
        let panelDirectory = model.directory
        // Found on the job's thread, read by the completion.
        let targetDirectory = Guarded<URL?>(nil)
        run(
            title: plan.kind == .copy ? "Copy:" : "Rename/Move:",
            makeJob: { [fileSystems] cancellation in
                plan.makeJob(cancellation, in: fileSystems, noting: targetDirectory)
            },
            summary: { result in
                Processed(result.completed, of: plan.picked)
            },
            completion: { [self] result, processed in
                processed.deselect(in: model)
                reportFailures(of: result, options: plan.options)
                // After a copy or rename in the same folder the cursor goes to the new item.
                var folders = [panelDirectory]
                if !plan.sourceDirectory.isSameLocation(as: panelDirectory) { folders.append(plan.sourceDirectory) }
                if let directory = targetDirectory.withLock({ $0 }) { folders.append(directory) }
                kernel.panels.refresh(folders, focus: result.lastTarget)
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
        guard
            let answer = interaction.form(
                kind == .copy ? "Copy" : "Rename/Move",
                detail: "",
                fields: Self.optionFields(heading, kind: kind, target: target, options: options),
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
            storeAsDefaults(options)
        }
        return answer.text("target")
    }

    /// Stores the choices of the Copy dialog as the configuration's defaults ("OK, Keep as Defaults").
    private func storeAsDefaults(_ options: TransferOptions) {
        let settings = kernel.settings
        settings.set(options.overwrite.rawValue, forKey: OperationSettings.overwrite)
        settings.set(options.preservesAttributes, forKey: OperationSettings.attributes)
        settings.set(options.preservesFolderDates, forKey: OperationSettings.folderDates)
        settings.set(options.links.rawValue, forKey: OperationSettings.links)
        settings.set(options.verifies, forKey: OperationSettings.verify)
        settings.set(options.skipsErrors, forKey: OperationSettings.skipErrors)
    }

    /// The transfer service (`FileTransferService`): `sources` into `directory` under their own
    /// names, with the questions of the job and no dialog.
    internal func transfer(
        _ kind: TransferKind,
        _ sources: [URL],
        into directory: URL,
        renamingSelfCopies: Bool,
        completion: @escaping @MainActor (URL?) -> Void
    ) {
        var options = OperationSettings.options(from: kernel.settings)
        // Whoever uses the service gets the questions, not the dialog's presets.
        options.overwrite = .ask
        options.skipsErrors = false
        let jobOptions = options
        run(
            title: kind == .move ? "Rename/Move:" : "Copy:",
            makeJob: { [fileSystems] cancellation in
                // The folder as it really is: a branch view names a real folder in its own way.
                let real = RealLocation.resolve(directory, in: fileSystems)
                guard RealLocation.takesNames(real, in: fileSystems) else {
                    let path = fileSystems.displayPath(real)
                    return .failure(
                        JobRefusal(message: "\(path) is a list of files, not a folder. Nothing can be put into it.")
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
                    .filter { folder in seen.insert(folder.locationKey).inserted }
            },
            completion: { [kernel] result, folders in
                kernel.panels.refresh(folders, focus: result.lastTarget)
                completion(result.lastTarget)
            }
        )
    }
}
