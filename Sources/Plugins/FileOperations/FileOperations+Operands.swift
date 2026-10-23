import AFMContracts
import AFMKernel
import Foundation

/// What a command works on and what a job processed, and how a job is refused.
extension FileOperations {
    /// How a copy or move learns where to go.
    internal enum Dialog {
        /// No dialog: to the other panel under the same names.
        case immediate
        /// The target with every option of the job.
        case options
        /// One line: the target. The common case, and as fast as it can be.
        case quick
    }

    /// What a command works on, taken on the main thread at no cost: how many items, and the
    /// first of them.
    ///
    /// The list itself is made where it is needed, on the job's thread; for a selection of several
    /// hundred thousand that is time the main thread does not have.
    internal struct Picked {
        /// How many items: the marked ones, or the one under the cursor.
        internal let count: Int
        /// The first operand; the only one when `count` is 1.
        internal let first: FileItem?
        /// What the panel showed and had marked when the command started.
        internal let snapshot: PanelModel.Operands

        /// The one operand as a list, for the wording of a dialog.
        internal var single: FileItem? { count == 1 ? first : nil }

        /// The operands of `model` as it is now.
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
        internal func visitMarked(_ body: (FileItem) -> Bool) {
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
        /// The places of the processed items among what the panel showed.
        internal var indices: [Int] = []
        /// Their names, for a panel that shows something else by the time the job ends.
        internal var names: [String] = []
        /// The version of what the panel showed, which `indices` refer to.
        internal var shownVersion = 0

        /// The marked items of `picked` that are among `completed`.
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

        /// Takes the marks off the processed items: by their places while the panel shows the
        /// same, otherwise by their names.
        @MainActor
        internal func deselect(in model: PanelModel) {
            guard !indices.isEmpty else {
                return
            }
            if !model.setSelected(false, indices: indices, shownVersion: shownVersion) { model.deselect(names) }
        }
    }

    /// Why a job is not started: what the user is told.
    internal struct JobRefusal: Error {
        /// Empty: there is nothing to do and nothing to say.
        internal let message: String
    }
}
