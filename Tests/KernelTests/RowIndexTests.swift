import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Rows worked out as indexes of what a panel shows (review 2, second pass): they become a
/// selection in one step, and are refused once what is shown has changed.
@MainActor
@Suite
internal struct RowIndexTests {
    /// Every third shown row, worked out on another thread with indexes out of range among them,
    /// marks exactly those rows; rows are added and taken away like any other, and go stale with
    /// another order; with and without a filter.
    @Test(arguments: [false, true])
    internal func rowsWorkedOutAsIndexesBecomeASelectionInOneStep(filtered: Bool) throws {
        let folder = URL(fileURLWithPath: "/review2/second")
        let items = (0..<200).map { Fixture.file("f\($0).txt", in: folder, size: Int64($0)) }
        let model = Fixture.panel(items, at: folder)
        if filtered {
            model.setFilter(PanelFilter(title: "even") { $0.size.isMultiple(of: 2) })
        }
        let basis = model.basis
        // Every third shown row, as a command that pairs or counts rows finds them.
        let indices = Array(stride(from: 0, to: basis.items.count, by: 3))
        let rows = try #require(OtherThread.result { PanelModel.rows(of: basis, indices: indices + [-1, 1_000_000]) })
        #expect(rows.count == indices.count)
        #expect(model.setSelection(rows))
        #expect(model.selectedNames == indices.map { model.items[$0].name })
        // Added to and taken from what is marked, like any other set of rows.
        let more = PanelModel.rows(of: model.basis, indices: [1, 2])
        #expect(model.setSelection(more, .add))
        #expect(model.selectionCount == indices.count + 2)
        #expect(model.setSelection(more, .remove))
        #expect(model.selectionCount == indices.count)
        // Stale once what is shown has changed.
        model.setSort(ListOrder(key: .size, descending: true))
        #expect(!model.setSelection(rows))
    }
}
