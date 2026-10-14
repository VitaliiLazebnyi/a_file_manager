import Foundation
import FuzzCore

@testable import AFMKernel

/// One input of a panel target: a model and the operations the input chooses, checked after each.
@MainActor
internal final class PanelSession {
    /// The rest of the input.
    internal var choices: Choices
    /// The model under test.
    internal let model: PanelModel
    /// How many changes the model has announced.
    internal var changes = 0
    /// What the model was last given, when its list must still be that.
    internal var last: ExpectedListing?
    /// Snapshots taken so far, each with what the model had been given then.
    internal var snapshots: [(PanelModel.Snapshot, ExpectedListing?)] = []
    /// Whether the list must be in the model's order (not after a restore).
    internal var ordered = true

    /// A session for `bytes`; the first choice is the model's order.
    internal init(bytes: [UInt8]) {
        var input = Choices(bytes)
        model = PanelModel(directory: kDirectory, sort: nextOrder(&input))
        choices = input
        model.onChange = { [weak self] _ in
            self?.changes += 1
        }
    }

    /// Runs one operation the input chooses and checks the model after it.
    internal func step() {
        let operation = choices.int(26)
        guard let what = perform(operation) else {
            return
        }
        if operation == 23 || !ordered {
            // After a restore only what does not depend on today's order and filter holds.
            return
        }
        if case 20...21 = operation {
            last = nil
        }
        PanelCheck.check(model, last: [7, 8].contains(operation) ? nil : last, what: what, ordered: ordered)
    }

    /// A listing of `items` in the panel's folder or (`other`) in a sub-folder.
    internal func listing(_ items: [FileItem], other: Bool) -> Listing {
        let folder = other ? kDirectory.appendingPathComponent("sub") : kDirectory
        return Listing(
            directory: folder,
            items: items,
            parent: choices.bool() ? folder.deletingLastPathComponent() : nil,
            root: URL(fileURLWithPath: "/")
        )
    }

    /// A name: mostly one in the list, sometimes a tricky one.
    internal func pickName() -> String {
        let items = model.listedItems
        if !items.isEmpty, choices.int(4) != 0 {
            return items[choices.int(items.count)].name
        }
        return kTrickyNames[choices.int(kTrickyNames.count)]
    }

    /// A row, two past either end included.
    internal func pickRow() -> Int {
        choices.int(model.rowCount + 4) - 2
    }

    /// Runs operation `operation`; returns what to call it in a report, or nil when it could not run.
    private func perform(_ operation: Int) -> String? {
        switch operation {
        case 0...8:
            return performListing(operation)

        case 9...15:
            performSelection(operation)
            return "op \(operation)"

        case 16...21:
            performMarking(operation)
            return "op \(operation)"

        default:
            return performOther(operation) ? "op \(operation)" : nil
        }
    }

    /// Operations 0 to 8: listings, order and filter.
    private func performListing(_ operation: Int) -> String? {
        let what = "op \(operation)"
        switch operation {
        case 0:
            show()

        case 1:
            showRemembered()

        case 2:
            return extend() ? what : nil

        case 3, 4:
            return update(presorted: operation == 4) ? what : nil

        case 5:
            model.setSort(nextOrder(&choices))
            ordered = true

        case 6:
            let order = nextOrder(&choices)
            model.setSort(order, presorted: choices.int(6) == 0 ? [] : Sorter.sort(model.listedItems, by: order))
            ordered = true

        case 7:
            return what + " filter \(setMaskFilter())"

        default:
            setSizeFilter()
        }
        return what
    }

    /// Operations 9 to 15: marks by row and by name, all, none, inverted.
    private func performSelection(_ operation: Int) {
        switch operation {
        case 9:
            model.toggleSelection(row: pickRow())

        case 10:
            let first = pickRow()
            let second = pickRow()
            model.setSelected(choices.bool(), rows: min(first, second)...max(first, second))

        case 11:
            model.setSelected(choices.bool(), names: (0..<choices.int(5)).map { _ in pickName() })

        case 12:
            model.setSelection(names: (0..<choices.int(6)).map { _ in pickName() })

        case 13:
            model.selectAll()

        case 14:
            model.clearSelection()

        default:
            model.invertSelection()
        }
    }

    /// Operations 16 to 21: marks by mask, saved marks, and computed sizes.
    private func performMarking(_ operation: Int) {
        switch operation {
        case 16:
            model.select(mask: ["*.txt", "*", "a*", "*é*", "*."][choices.int(5)], select: choices.bool())

        case 17:
            model.saveSelection()

        case 18:
            model.restoreSelection()

        case 19:
            model.deselect((0..<choices.int(4)).map { _ in pickName() })

        case 20:
            model.setComputedSize(kSizes[choices.int(kSizes.count)], forName: pickName())

        default:
            let sizes = (0..<choices.int(4)).map { _ in (name: pickName(), size: kSizes[choices.int(kSizes.count)]) }
            model.setComputedSizes(sizes)
        }
    }

    /// Operations 22 to 25: snapshots, the cursor, hidden files; false when there was nothing to restore.
    private func performOther(_ operation: Int) -> Bool {
        switch operation {
        case 22:
            snapshots.append((model.snapshot(), last))

        case 23:
            guard !snapshots.isEmpty else {
                return false
            }
            let (snapshot, then) = snapshots[choices.int(snapshots.count)]
            model.restore(snapshot)
            last = then
            // A snapshot holds the lists as they were; the order and filter of today are not applied to them.
            ordered = false

        case 24:
            model.moveCursor(to: pickRow() * (choices.int(8) == 0 ? 1_000_000 : 1))

        default:
            model.setShowHidden(choices.bool())
        }
        return true
    }

    deinit {
        // Nothing to release.
    }
}
