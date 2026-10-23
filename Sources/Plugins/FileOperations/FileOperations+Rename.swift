import AFMContracts
import AFMKernel
import Foundation

/// Rename: the item under the cursor in place, and several items with a mask or one by one.
extension FileOperations {
    /// How the items of Shift+F6 get their new names.
    private enum Renaming {
        /// One mask for all, applied on the job's thread: one name per item of the selection.
        case mask(String)
        /// A name for each item, as the user typed them.
        case typed([(URL, String)])

        /// The items that get another name, and their new names.
        ///
        /// Job thread: a mask makes the list of the operands.
        func names(of picked: Picked) -> [(URL, String)] {
            switch self {
            case .mask(let mask):
                return picked.items()
                    .map { item in (item.url, TargetMask.apply(mask, to: item.url.lastPathComponent)) }
                    .filter { url, name in url.lastPathComponent != name && FileJob.isSafeName(name) }

            case .typed(let names):
                return names
            }
        }
    }

    /// The job that gives the items their new names, or none when nothing gets another name.
    nonisolated private static func renameJob(
        _ names: [(URL, String)],
        in folder: URL,
        _ options: TransferOptions,
        _ fileSystems: FileSystemRegistry,
        _ cancellation: CancellationFlag
    ) -> Result<FileJob, JobRefusal> {
        // Nothing gets another name: nothing to do and nothing to say.
        guard !names.isEmpty else {
            return .failure(JobRefusal(message: ""))
        }
        let job = FileJob(
            kind: .move,
            sources: names.map(\.0),
            target: TargetSpec(directory: folder),
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
    }
    /// Finishes an in-place rename; the cursor follows the renamed item.
    internal func renameCursorItem(to newName: String) {
        let model = source.model
        guard let item = model.cursorItem, !newName.isEmpty, newName != item.name else {
            return
        }
        let directory = model.directory
        let destination = item.url.deletingLastPathComponent().appending(name: newName)
        let record = recorder()
        change(
            "Renaming:",
            { [fileSystems] cancellation in
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

    /// Asks for the mask or the names of `picked`, then renames them in one job.
    private func renameSelection(_ picked: Picked, first firstItem: FileItem) {
        let model = source.model
        let directory = model.directory
        guard
            let answer = interaction.form(
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
        let renaming: Renaming
        if answer.flag("each") {
            let typed = askForEachName(of: picked)
            guard !typed.isEmpty else {
                return
            }
            renaming = .typed(typed)
        } else {
            let mask = answer.text("mask").trimmingCharacters(in: .whitespaces)
            guard !mask.isEmpty, !mask.contains("/") else {
                return
            }
            renaming = .mask(mask)
        }
        model.saveSelection()
        let options = OperationSettings.options(from: kernel.settings)
        let folder = firstItem.url.deletingLastPathComponent()
        // One job for all of them: every item is renamed where it lies (in a branch view that
        // is not one folder), an answer "for all" holds for all, and two items that would get
        // one name are noticed.
        run(
            title: "Rename/Move:",
            makeJob: { [fileSystems] cancellation in
                Self.renameJob(renaming.names(of: picked), in: folder, options, fileSystems, cancellation)
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

    /// A new name for each marked item of `picked`, asked one by one; none when the user gave up.
    ///
    /// One question per item, so the items are taken one by one: the list of a long selection is
    /// not made for a round of questions that is given up after a few. Names that are the old one,
    /// or are no safe name, are left out.
    private func askForEachName(of picked: Picked) -> [(URL, String)] {
        var names: [(URL, String)] = []
        var wasGivenUp = false
        picked.visitMarked { item in
            // A branch view names its items by their paths; the name to change is the last part.
            let old = item.url.lastPathComponent
            guard
                let name = interaction.prompt("Rename \"\(DisplayName.escaped(item.name))\" to", value: old)?
                    .trimmingCharacters(in: .whitespaces)
            else {
                wasGivenUp = true
                return false
            }
            if name != old, FileJob.isSafeName(name) { names.append((item.url, name)) }
            return true
        }
        return wasGivenUp ? [] : names
    }
}
