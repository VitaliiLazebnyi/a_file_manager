import AFMContracts
import AFMKernel
import Foundation

/// Start!, Undo and the result list.
extension MultiRenameSession {
    /// Renames the items in list order, as a job with progress.
    ///
    /// The names are computed afresh on the job's thread, so what happens is what the fields say,
    /// whatever the preview has caught up with; the job ends when it is cancelled, also in the
    /// middle of a regular expression. `completion`, if any, runs on the main thread.
    internal func start(completion: (@MainActor (RenameRunResult) -> Void)?) {
        guard !entries.isEmpty, !isBusy else {
            return
        }
        rememberFields()
        isBusy = true
        // A sort or "next step" still under way would change the list the run is about to use.
        listGeneration += 1
        titleRule = store.titleRule
        // A run looks at the folders afresh: nothing is taken from the previews' cache.
        let fresh = RenameCache()
        let job = MultiRenameJob(
            request: RenameRequest(
                entries: entries,
                settings: settings,
                context: makeContext(cache: fresh),
                given: givenNames
            ),
            fileSystems: kernel.fileSystems,
            interaction: kernel.interaction,
            logURL: logURL,
            cache: fresh
        )
        kernel.jobs.run(
            title: "Multi-Rename:",
            work: { monitor in job.run(monitor) },
            completion: { outcome in
                // The session lives until its job has ended, also when the window was closed meanwhile.
                self.isBusy = false
                self.finish(outcome)
                completion?(outcome.result)
            }
        )
    }

    /// Undoes the last run after asking, last renamed first. `completion`, if any, runs on the main
    /// thread with what could not be put back; it is not called when the user says no.
    internal func undo(completion: (@MainActor ([RenamedItem]) -> Void)?) {
        guard canUndo else {
            return
        }
        // Pressed again while this one is under way, it would find the same run and undo it twice.
        isBusy = true
        listGeneration += 1
        guard previewsInBackground else {
            performUndo(completion: completion)
            return
        }
        store.loadUndo { [weak self] in self?.performUndo(completion: completion) }
    }

    /// Shows the log of the last run in the viewer.
    internal func showResultList() {
        guard hasResultList else {
            return
        }
        if let viewer = kernel.services.find((any ViewerService).self) {
            viewer.view(logURL)
        } else if kernel.commands[.view] != nil {
            kernel.commands.perform(.view, .location(logURL))
        } else {
            _ = kernel.interaction.form(
                "Result list",
                detail: "",
                fields: [.lines("log", "", RenameLog.text(lastRun, fileSystems: kernel.fileSystems))],
                buttons: ["Close"]
            )
        }
    }

    /// A successful run shows no message: the renamed items leave the list and Undo and the
    /// result list become available.
    ///
    /// What failed stays in the list and is reported.
    private func finish(_ outcome: MultiRenameJob.Outcome) {
        let result = outcome.result
        if !result.renamed.isEmpty {
            lastRun = result.renamed
            store.appendUndo(result.renamed)
            // The list could not change meanwhile, so the flags of the run are the list's own.
            reorder(entries.indices.filter { !outcome.renamed[$0] })
            givenNames = []
            kernel.panels.refresh(outcome.folders, focus: result.renamed.last?.destination)
        }
        if !result.failures.isEmpty {
            let lines = result.failures.prefix(15)
                .map { failure in outcome.entries[failure.item].item.name + ": " + failure.message }
            kernel.interaction.inform(
                "\(result.failures.count) file(s) could not be renamed!",
                detail: lines.joined(separator: "\n") + (result.failures.count > 15 ? "\n…" : ""),
                style: .warning
            )
        } else if outcome.unusable > 0, !result.cancelled {
            kernel.interaction.inform(
                "\(outcome.unusable) file(s) were left out because the rename mask gives no valid name for them.",
                detail: "",
                style: .warning
            )
        }
        listChanged(keepingFolders: false)
    }

    private func performUndo(completion: (@MainActor ([RenamedItem]) -> Void)?) {
        let last = store.lastUndo
        guard !last.isEmpty else {
            isBusy = false
            return
        }
        let lines = last.prefix(20).map { "\($0.from.lastPathComponent) -> \($0.destination.lastPathComponent)" }
        let detail =
            "Undo the following rename action:\n" + lines.joined(separator: "\n")
            + (last.count > 20 ? "\n… (\(last.count) files)" : "")
        guard
            kernel.interaction.choose(kernel.productName, detail: detail, buttons: ["Yes", "No"], style: .information)
                == 0
        else {
            isBusy = false
            return
        }
        let job = MultiRenameUndoJob(run: last, fileSystems: kernel.fileSystems)
        let runs = store.undoCount
        kernel.jobs.run(
            title: "Undo rename:",
            work: { monitor in job.undo(monitor) },
            completion: { outcome in
                self.undone(outcome, runs: runs)
                completion?(outcome.attempted)
            }
        )
    }

    /// Takes in what an Undo did; `runs` is how many runs could be undone when it started.
    private func undone(_ outcome: MultiRenameUndoJob.Outcome, runs: Int) {
        isBusy = false
        // Only the run that was asked about is replaced.
        if store.undoCount == runs {
            store.replaceLastUndo(with: outcome.left)
        }
        lastRun = []
        kernel.panels.refresh(outcome.folders, focus: outcome.result.renamed.last?.destination)
        // A cancelled Undo needs no message: the user stopped it.
        if !outcome.left.isEmpty, !outcome.result.cancelled {
            kernel.interaction.inform(
                "\(outcome.attempted.count) file(s) could not be renamed back!",
                detail: outcome.result.failures.prefix(15).map(\.message).joined(separator: "\n"),
                style: .warning
            )
        }
        cache = RenameCache()
        listGeneration += 1
        onChange?()
        // The files are where they were: the marks of conflicts in the list are looked at again.
        refresh()
    }
}
