import AFMContracts
import AFMKernel
import Foundation

/// Change Attributes (spec 07 › Change attributes).
extension PropertyActions {
    /// The folders whose listings an operation on `items` may have changed.
    ///
    /// Grows with the selection, so it is worked out on a job's thread.
    nonisolated private static func folders(of items: [FileItem], and directory: URL) -> [URL] {
        var seen = Set<String>()
        return ([directory] + items.map { $0.url.deletingLastPathComponent() })
            .filter { folder in seen.insert(folder.locationKey).inserted }
    }

    /// `.text`: parameters as `AttributeChange.parse` reads them; without, the dialog.
    internal func changeAttributes(_ argument: CommandArgument) {
        let model = source.model
        // What is marked is noted here at no cost; the list of it is made on the job's thread
        // (for a selection of several hundred thousand that is time the main thread does not have).
        // Offered only where there are operands.
        let (operands, directory) = (model.operandsSnapshot(), model.directory)
        var parsed: (change: AttributeChange, applyAtOnce: Bool)?
        if let text = argument.text {
            guard let read = AttributeChange.parse(parameters: text) else {
                interaction.inform("The attribute parameters cannot be read!", detail: text, style: .warning)
                return
            }
            parsed = (read.change, read.applyAtOnce)
        }
        // The current flags and owner of a single item are shown in the dialog; reading them
        // is a question to the disk, and turning the owner's number into a name may be one
        // to a directory server. Both are asked here; the dialog then finds the names known.
        let asksAtOnce = parsed?.applyAtOnce == true
        kernel.jobs.run(
            title: "Reading attributes:",
            work: { _ -> (items: [FileItem], details: LocalDetails?) in
                let items = operands.items()
                guard !asksAtOnce, items.count == 1, let details = LocalInfo.details(items[0].url) else {
                    return (items, nil)
                }
                _ = (LocalInfo.userName(details.ownerID), LocalInfo.groupName(details.groupID))
                return (items, details)
            },
            completion: { [self] read in
                let items = read.items
                if let parsed, parsed.applyAtOnce {
                    return apply(parsed.change, to: items, in: directory)
                }
                // The panel may show something else by now; a dialog about what it showed would mislead.
                guard model.directory.isSameLocation(as: directory) else {
                    return
                }
                var draft = AttributeDraft(items: items)
                if let parsed { draft.take(parsed.change) }
                ask(draft, items: items, directory: directory, details: read.details)
            }
        )
    }

    /// Shows the dialog until its answer can be applied, and applies it, or until it is cancelled.
    private func ask(_ start: AttributeDraft, items: [FileItem], directory: URL, details: LocalDetails?) {
        var draft = start
        let isLocal = items.allSatisfy(\.url.isFileURL)
        let title = "Change attributes: " + (items.count == 1 ? items[0].name : String(items.count))
        let targetFile = kernel.panels.target.model.cursorItem
        let buttons = ["OK"] + (targetFile != nil ? ["Load from Target File"] : [])
        // Asked until the answer can be applied or the dialog is cancelled.
        while let answer = interaction.form(
            title,
            detail: "",
            fields: draft.fields(isLocal: isLocal, details: details),
            buttons: buttons
        ) {
            draft.read(answer)
            if answer.button == 1, let targetFile {
                // Load from file under cursor › From target (spec 07 › Load from file under cursor).
                draft.load(from: targetFile)
                continue
            }
            switch draft.change(isLocal: isLocal) {
            case .failure(let problem):
                interaction.inform(problem.message, detail: "", style: .warning)

            case .success(let change):
                // Recurse with the permissions left as they were shown asks for nothing: the
                // field shows the folder's own mode, not a wish. Said, instead of ending silently.
                if change.isEmpty, draft.recurse, let shown = draft.untouchedPermissions {
                    let applies =
                        interaction.choose(
                            "Nothing was changed.",
                            detail: "Do you want to give the permissions \(shown) to everything inside as well?",
                            buttons: ["Apply \(shown)", "Back"],
                            style: .warning
                        ) == 0
                    if applies { draft.confirmPermissions() }
                    continue
                }
                apply(change, to: items, in: directory)
                return
            }
        }
    }

    /// Runs the change as a job and reports what failed; the folders it touched are listed again.
    private func apply(_ change: AttributeChange, to items: [FileItem], in directory: URL) {
        guard !change.isEmpty else {
            return
        }
        let model = source.model
        model.saveSelection()
        let registry = fileSystems
        let title = "Changing attributes:"
        kernel.jobs.run(
            title: title,
            work: { monitor -> (AttributeJob.Outcome, [URL]) in
                let meter = ProgressMeter(monitor, title: title, total: change.recurse ? 0 : items.count)
                let outcome = AttributeJob(
                    change: change,
                    fileSystems: registry,
                    cancellation: monitor.cancellation,
                    meter: meter
                )
                .run(items)
                return (outcome, Self.folders(of: items, and: directory))
            },
            completion: { [self] outcome, folders in
                if outcome.failed > 0 {
                    interaction.inform(
                        "\(outcome.failed) item(s) could not be changed!",
                        detail: Self.summary(of: outcome.failures, total: outcome.failed),
                        style: .warning
                    )
                }
                kernel.panels.refresh(folders)
            }
        )
    }
}
