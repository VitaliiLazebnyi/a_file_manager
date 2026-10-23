import AFMKernel
import Foundation

/// The work of Start!: the names computed afresh, the questions about moves and conflicts, the
/// renames and the log, on the job's thread.
///
/// Everything it holds is a copy taken when the run starts; it touches the session not at all.
internal struct MultiRenameJob {
    /// What a run did, with everything the main thread needs worked out in the job.
    internal struct Outcome {
        /// The renames and failures.
        internal var result = RenameRunResult()
        /// The entries the result's item numbers refer to.
        internal var entries: [RenameEntry]
        /// How many items got no usable name and were left out.
        internal var unusable = 0
        /// The folders to read again.
        internal var folders: [URL] = []
        /// For each entry: whether it was renamed and so leaves the list.
        internal var renamed: [Bool] = []
    }

    /// The answers to "Name conflict".
    private enum ConflictChoice {
        case autoRename
        case cancel
        case skip
    }

    /// The list, the settings and the given names, as they were when the run started.
    internal let request: RenameRequest
    /// The file systems the items are on.
    internal let fileSystems: FileSystemRegistry
    /// Where the questions are asked.
    internal let interaction: any UserInteraction
    /// Where the result log is written.
    internal let logURL: URL
    /// A fresh cache: a run looks at the folders afresh.
    internal let cache: RenameCache

    /// Carries out the run; `monitor` reports the progress, asks the questions and says when it is cancelled.
    internal func run(_ monitor: any JobMonitor) -> Outcome {
        let entries = request.entries
        let preview = RenameComputation.preview(
            request,
            fileSystems: fileSystems,
            cache: cache,
            cancellation: monitor.cancellation
        ) { monitor.cancellation.isCancelled }
        var outcome = Outcome(entries: entries)
        outcome.unusable = preview.statuses.filter { $0 == .error || $0.isInvalid }.count
        guard !monitor.cancellation.isCancelled, request.given.isEmpty || confirmsMoves(preview, monitor) else {
            outcome.result.cancelled = true
            return outcome
        }
        let sources = entries.map(\.item.url)
        let resolved = resolvedTargets(preview, sources: sources, monitor)
        guard !resolved.cancelled else {
            outcome.result.cancelled = true
            return outcome
        }
        let steps = preview.planner.steps(
            sources: sources,
            targets: resolved.targets,
            isFolder: entries.map(\.item.isFolder),
            temporaryName: nil
        ) { monitor.cancellation.isCancelled }
        guard !monitor.cancellation.isCancelled else {
            outcome.result.cancelled = true
            return outcome
        }
        outcome.result = rename(steps, sources: sources, monitor)
        // What the main thread will need, so that it does not walk the list for it.
        let from = Set(outcome.result.renamed.map(\.from.locationKey))
        outcome.renamed =
            from.isEmpty
            ? []
            : Parallel.map(entries, serialBelow: RenameComputation.parallelThreshold) { entry in
                from.contains(entry.item.url.locationKey)
            }
        var folders = Set<String>()
        outcome.folders = outcome.result.renamed
            .flatMap { item in
                [item.from.deletingLastPathComponent(), item.destination.deletingLastPathComponent()]
            }
            .filter { folders.insert($0.locationKey).inserted }
        if !outcome.result.renamed.isEmpty {
            RenameLog.write(outcome.result.renamed, to: logURL, fileSystems: fileSystems)
        }
        return outcome
    }

    /// Whether the user wants the given names that move files into other folders, if any name does.
    ///
    /// Names that come from a file or were typed can lead anywhere: a name with a slash moves the file
    /// into that folder, a name that starts with one anywhere on the disk.
    private func confirmsMoves(_ preview: RenamePreview, _ monitor: any JobMonitor) -> Bool {
        let moving = preview.names.indices
            .compactMap { index in
                preview.statuses[index] == .ready ? preview.names[index] : nil
            }
            .filter { $0.utf8.contains(0x2F) }
        guard !moving.isEmpty else {
            return true
        }
        let examples = moving.prefix(8).joined(separator: "\n") + (moving.count > 8 ? "\n…" : "")
        let detail =
            examples
            + "\n\nA name with a / puts the file in that folder, and one that starts with a / anywhere on the "
            + "disk. Rename anyway?"
        let message = "\(moving.count) of the names given move the file into another folder."
        let asking = interaction
        return monitor.ask { @MainActor @Sendable in
            asking.choose(message, detail: detail, buttons: ["Rename", "Cancel"], style: .warning) == 0
        }
    }

    /// Where the items go once the conflicts are dealt with as the user says: renamed away, skipped, or
    /// the run cancelled.
    private func resolvedTargets(
        _ preview: RenamePreview,
        sources: [URL],
        _ monitor: any JobMonitor
    ) -> (targets: [URL?], cancelled: Bool) {
        let conflicts = preview.conflicts
        guard !conflicts.isEmpty else {
            return (preview.targets, false)
        }
        let names =
            conflicts.prefix(12).compactMap { preview.names[$0] }.joined(separator: "\n")
            + (conflicts.count > 12 ? "\n…" : "")
        let asking = interaction
        let choice = monitor.ask { @MainActor @Sendable in
            asking.pick(
                "Name conflict: \(conflicts.count) file(s) would get a name that is already in use.",
                detail: names + "\n\nAuto-rename them to \"name (2).ext\", \"name (3).ext\", …?",
                [("Auto-rename", .autoRename), ("Skip these files", .skip), ("Cancel", .cancel)],
                fallback: ConflictChoice.cancel
            )
        }
        switch choice {
        case .cancel:
            return (preview.targets, true)

        case .autoRename:
            let targets = preview.planner.autoRenamed(
                sources: sources,
                targets: preview.targets,
                isFolder: request.entries.map(\.item.isFolder),
                existing: preview.existing
            )
            return (targets, false)

        case .skip:
            // Leaving an item where it is can put it in the way of another one.
            let targets = preview.planner.skippingConflicts(
                sources: sources,
                targets: preview.targets,
                existing: preview.existing
            )
            return (targets, false)
        }
    }

    /// Carries out the steps, reporting the progress now and then.
    private func rename(_ steps: [RenameStep], sources: [URL], _ monitor: any JobMonitor) -> RenameRunResult {
        let total = Set(steps.map(\.item)).count
        let runner = RenameRunner(fileSystems: fileSystems, cancellation: monitor.cancellation)
        var lastReport = Date.distantPast
        let registry = fileSystems
        runner.onProgress = { step, done in
            // A list of a hundred thousand files must not flood the progress window.
            guard Date().timeIntervalSince(lastReport) > 0.05 else {
                return
            }
            lastReport = Date()
            monitor.report(
                JobProgress(
                    lines: [
                        "From: " + registry.displayPath(sources[step.item]),
                        "To: " + step.destination.lastPathComponent
                    ],
                    itemsDone: done,
                    itemsTotal: total
                )
            )
        }
        return runner.run(steps, sources: sources)
    }
}
