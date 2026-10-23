import AFMContracts
import AFMKernel
import AppKit

/// Compare Directories and Mark Newer, Hide Same Files: marks by what differs between the two panels.
extension Selections {
    /// What the work of Mark Newer, Hide Same Files leaves for the main thread: the lists as the
    /// filters leave them, and the names to mark.
    private struct ComparisonOutcome {
        /// The lists of the left and the right panel without what is the same on both sides.
        var filters: [PanelModel.Prepared]
        /// The names to mark in the left and the right list, by their exact bytes.
        var marked: [Set<NameBytes>]
    }

    /// Who asks the volumes; stands for the plugin in `BlockingCalls`.
    private final class VolumeQuestions: Sendable {
        deinit {
            // Nothing to release.
        }
    }

    /// The owner of the questions to the volumes: a stalled volume holds at most as many
    /// threads as one owner may have.
    nonisolated private static let volumeQuestions = VolumeQuestions()

    /// Whether both folders are on local volumes that treat `A.txt` and `a.txt` as one name.
    ///
    /// Asks the volumes on a thread of the kernel's, which is given up when `cancellation` is set
    /// (a stalled mount holds that thread, not this one); not for the main thread.
    nonisolated private static func foldsCase(_ folders: URL..., cancellation: CancellationFlag) -> Bool {
        folders.allSatisfy { folder in
            guard folder.isFileURL else {
                return false
            }
            let key = "case " + folder.path
            let answer = BlockingCalls.answer(from: volumeQuestions, to: key, cancellation: cancellation) { _ in
                (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                    .volumeSupportsCaseSensitiveNames == false
            }
            // Given up (a newer command): taken as a volume that tells the cases apart.
            return answer == true
        }
    }

    /// Compares the two lists for Mark Newer, Hide Same Files and cuts what is the same out of
    /// both; off the main thread.
    nonisolated private static func comparison(
        of frozen: [Frozen],
        titles: [String],
        options: DirectoryComparison.Options,
        cancellation: CancellationFlag
    ) -> ComparisonOutcome {
        let (leftList, rightList) = (frozen[0].basis.listedItems, frozen[1].basis.listedItems)
        let marks = DirectoryComparison.compareIndices(left: leftList, right: rightList, options: options) {
            cancellation.isCancelled
        }
        // Exact bytes, so that of two names that differ in normalisation only the same one is left out.
        var same = Set<NameBytes>()
        for index in marks.sameLeft { same.insert(NameBytes(leftList[index].name)) }
        for index in marks.sameRight { same.insert(NameBytes(rightList[index].name)) }
        let filters = zip(frozen, titles)
            .map { frozen, title in
                PanelModel.prepare(
                    frozen.basis,
                    filter: PanelFilter(title: title) { [same] in !same.contains(NameBytes($0.name)) }
                )
            }
        return ComparisonOutcome(
            filters: filters,
            marked: [
                Set(marks.left.map { NameBytes(leftList[$0].name) }),
                Set(marks.right.map { NameBytes(rightList[$0].name) })
            ]
        )
    }

    /// Compare Directories (spec 09 › Compare directories and Mark newer): in both panels the
    /// selection becomes the files that differ from the other side.
    ///
    /// Whether the volumes tell upper from lower case is asked of them, which can take long: it is
    /// done with the comparison, off the main thread, and given up when a newer command starts.
    internal func compare(mode: DirectoryComparison.Mode, withSubdirectories: Bool) {
        let (left, right) = (kernel.panels.left.model, kernel.panels.right.model)
        let (leftFolder, rightFolder) = (left.directory, right.directory)
        let ignoresOneHour = store.ignoresOneHour
        compute(
            heavy: true,
            models: [left, right],
            { frozen, flag in
                let options = DirectoryComparison.Options(
                    mode: mode,
                    withSubdirectories: withSubdirectories,
                    ignoringOneHour: ignoresOneHour,
                    foldingCase: Self.foldsCase(leftFolder, rightFolder, cancellation: flag)
                )
                return DirectoryComparison.compareIndices(
                    left: frozen[0].items,
                    right: frozen[1].items,
                    options: options
                ) { flag.isCancelled }
            },
            apply: { frozen, marks in
                // Both are tried: a panel that has changed is worked out again with the other.
                let first = Self.take(marks.left, .replace, in: frozen[0])
                let second = Self.take(marks.right, .replace, in: frozen[1])
                return first && second
            }
        )
    }

    /// Mark Newer, Hide Same Files: marks like Compare Directories and leaves what is the
    /// same on both sides out of both lists, until the command is chosen again or the panel
    /// shows another directory.
    ///
    /// Nothing is deleted.
    internal func markNewerHideSame() {
        let models = [kernel.panels.left.model, kernel.panels.right.model]
        if models.contains(where: { shows(.comparison, in: $0) }) {
            for model in models { end(.comparison, in: model) }
            return
        }
        let folders = models.map(\.directory)
        let ignoresOneHour = store.ignoresOneHour
        let titles = folders.map { folder -> String in
            let path = kernel.fileSystems.displayPath(folder)
            return "Comparison: " + path + (path.hasSuffix("/") ? "" : "/") + "*.*"
        }
        compute(
            heavy: true,
            models: models,
            { frozen, flag in
                let options = DirectoryComparison.Options(
                    mode: .newer,
                    ignoringOneHour: ignoresOneHour,
                    foldingCase: Self.foldsCase(folders[0], folders[1], cancellation: flag)
                )
                return Self.comparison(of: frozen, titles: titles, options: options, cancellation: flag)
            },
            apply: { [self] _, outcome in
                show(outcome, in: models, titles: titles)
            }
        )
    }

    /// Shows the cut-down lists and marks the names; false when a list has changed since the
    /// comparison, which is then worked out again.
    private func show(_ outcome: ComparisonOutcome, in models: [PanelModel], titles: [String]) -> Bool {
        var fresh = true
        for (model, prepared) in zip(models, outcome.filters) where model.apply(prepared) == .stale {
            fresh = false
        }
        guard fresh else {
            return false
        }
        for ((model, title), marked) in zip(zip(models, titles), outcome.marked) {
            restrictions = restrictions.filter { $0.value.model != nil }
            restrictions[ObjectIdentifier(model)] = Restriction(
                model: model,
                view: .comparison,
                directory: model.directory,
                title: title
            )
            markMatching(model, .replace, timedOut: nil) { marked.contains(NameBytes($0.name)) }
        }
        return true
    }
}
