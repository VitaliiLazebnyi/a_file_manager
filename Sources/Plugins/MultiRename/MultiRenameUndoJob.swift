import AFMKernel
import Foundation

/// The work of Undo: the renames of the last run put back, last renamed first, on the job's thread.
internal struct MultiRenameUndoJob {
    /// What an Undo did.
    internal struct Outcome {
        /// The renames back, and what failed.
        internal var result = RenameRunResult()
        /// What was asked for and not put back.
        internal var attempted: [RenamedItem] = []
        /// Of these, what is still to be undone later.
        internal var left: [RenamedItem] = []
        /// The folders to read again.
        internal var folders: [URL] = []
    }

    /// The renames of the run to undo, in the order they were done.
    internal let run: [RenamedItem]
    /// The file systems the items are on.
    internal let fileSystems: FileSystemRegistry

    /// Puts the items back; `monitor` reports the progress and says when it is cancelled.
    internal func undo(_ monitor: any JobMonitor) -> Outcome {
        let back = Array(run.reversed())
        let (sources, targets) = (back.map(\.destination), back.map { Optional($0.from) })
        let survey = RenameSurvey(fileSystems: fileSystems, cancellation: monitor.cancellation)
        let planner = RenamePlanner(
            foldsCase: survey.foldsCase(sources.prefix(16).compactMap(fileSystems.item(at:)))
        )
        var outcome = Outcome()
        let steps = planner.steps(
            sources: sources,
            targets: targets,
            isFolder: [],
            temporaryName: nil
        ) { monitor.cancellation.isCancelled }
        guard !monitor.cancellation.isCancelled else {
            // Nothing was put back: the whole run is still to be undone.
            outcome.result.cancelled = true
            (outcome.attempted, outcome.left) = (run, run)
            return outcome
        }
        outcome.result = rename(steps, sources: sources, total: back.count, monitor)
        // What was not put back is kept for another try, unless the file it was to be
        // taken from is gone: that can never be undone and must not hold up earlier runs.
        let restored = Set(outcome.result.renamed.map(\.from.locationKey))
        outcome.attempted = run.filter { !restored.contains($0.destination.locationKey) }
        let registry = fileSystems
        let present = Parallel.map(outcome.attempted) { registry.item(at: $0.destination) != nil }
        let stillThere = Set(zip(outcome.attempted, present).filter(\.1).map(\.0.destination.locationKey))
        outcome.left = outcome.attempted.filter { stillThere.contains($0.destination.locationKey) }
        var folders = Set<String>()
        outcome.folders =
            run.flatMap { item in
                [item.from.deletingLastPathComponent(), item.destination.deletingLastPathComponent()]
            }
            .filter { folders.insert($0.locationKey).inserted }
        return outcome
    }

    /// Carries out the steps, reporting the progress now and then.
    private func rename(
        _ steps: [RenameStep],
        sources: [URL],
        total: Int,
        _ monitor: any JobMonitor
    ) -> RenameRunResult {
        let runner = RenameRunner(fileSystems: fileSystems, cancellation: monitor.cancellation)
        var lastReport = Date.distantPast
        let registry = fileSystems
        runner.onProgress = { step, done in
            guard Date().timeIntervalSince(lastReport) > 0.05 else {
                return
            }
            lastReport = Date()
            monitor.report(
                JobProgress(
                    lines: ["From: " + registry.displayPath(step.from), "To: " + step.destination.lastPathComponent],
                    itemsDone: done,
                    itemsTotal: total
                )
            )
        }
        return runner.run(steps, sources: sources)
    }
}
