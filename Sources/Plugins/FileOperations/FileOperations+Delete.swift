import AFMContracts
import AFMKernel
import Foundation

/// Delete: to the Trash or for good (spec 07 › Delete).
extension FileOperations {
    /// F8 moves to the Trash where the file system has one; elsewhere, and with Shift, it
    /// deletes directly.
    ///
    /// The configuration can turn the two around (spec 07 › Recycle bin or direct deletion).
    internal func delete(shifted: Bool) {
        withOperands { picked, _ in delete(picked, shifted: shifted) }
    }

    /// Asks, then deletes `picked`; the panel is re-read when the job ends.
    private func delete(_ picked: Picked, shifted: Bool) {
        let model = source.model
        let directory = model.directory
        // What the folder says for all it shows: a view of several folders answers with what
        // every one of them can do, so the items are not asked about one by one.
        let hasTrash = fileSystems.capabilities(for: directory).contains(.trash)
        let toTrash = hasTrash && kernel.settings.flag(OperationSettings.useTrash, default: true) != shifted
        // What goes to the Trash can be taken out again, and Return says yes. What is
        // deleted for good cannot: there Return says no, and yes has to be chosen.
        let answer = interaction.choose(
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
        let options = OperationSettings.options(from: kernel.settings)
        run(
            title: "Deleting:",
            makeJob: { [fileSystems] cancellation in
                let job = FileJob(
                    kind: .delete(toTrash: toTrash),
                    sources: picked.items().map(\.url),
                    target: nil,
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
}
