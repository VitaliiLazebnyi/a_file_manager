import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Marks handed to and from other threads (review 2, cross-requests): by index of what is shown,
/// as a snapshot of the operands, and as a filtered list handed in.
@MainActor
@Suite
internal struct MarksOffTheMainThreadTests {
    private static let folder = URL(fileURLWithPath: "/review2/requests")

    /// Indexes of what is shown mark and unmark (out-of-range ones ignored); a snapshot of the
    /// operands answers on another thread; indexes worked out before a filter change are refused.
    @Test
    internal func theMarksCanLeaveTheMainThread() throws {
        let model = Fixture.panel((0..<40_000).map { file("f\($0).txt", size: Int64($0 % 9)) }, at: Self.folder)
        model.setFilter(PanelFilter(title: "even") { $0.size.isMultiple(of: 2) })
        let version = model.shownVersion
        let wanted = Array(stride(from: 0, to: model.items.count, by: 3))
        #expect(model.setSelection(indices: wanted + [-1, model.items.count + 5], shownVersion: version))
        #expect(model.selectionCount == wanted.count)
        #expect(model.setSelected(false, indices: [0, 3], shownVersion: version))
        #expect(model.selectionCount == wanted.count - 2)
        model.moveCursor(to: 5)
        let snapshot = model.operandsSnapshot()
        let names = try #require(OtherThread.result { snapshot.items().map(\.name) })
        let indices = try #require(OtherThread.result { snapshot.markedIndices() })
        let marks = try #require(OtherThread.result { [6, 0, 7, -1].map { snapshot.isMarked(at: $0) } })
        #expect(names == model.operands().map(\.name))
        #expect(indices == Array(wanted.dropFirst(2)))
        #expect(marks == [true, false, false, false])
        #expect(snapshot.markedCount == wanted.count - 2)
        #expect(snapshot.cursorItem?.name == model.cursorItem?.name)
        #expect(snapshot.shownVersion == version)
        // A filter moves what is shown, not the list: indexes worked out before are refused.
        let listVersion = model.listVersion
        model.setFilter(nil)
        #expect(model.listVersion == listVersion)
        #expect(model.shownVersion != version)
        #expect(!model.setSelection(indices: [1, 2], shownVersion: version))
        #expect(!model.setSelected(true, indices: [1], shownVersion: version))
        model.clearSelection()
        #expect(model.operandsSnapshot().items().map(\.name) == [try #require(model.cursorItem).name])
    }

    /// Of two entries of one name the filter lets the second through: the filtered list handed
    /// in is shown as it is, and its marks are not taken for the hidden twin (found by the fuzzer).
    @Test
    internal func aFilteredListOfTwinsHandedInIsShownAsItIs() throws {
        let (first, second) = (URL(fileURLWithPath: "/review2/a"), URL(fileURLWithPath: "/review2/b"))
        let items = [
            Fixture.file("twin", in: first, size: 0), Fixture.file("twin", in: second, size: 5), file("other", size: 3),
            Fixture.file("twin", in: first, size: 5)
        ]
        let model = Fixture.panel(items, at: Self.folder)
        let filter = PanelFilter(title: "big") { $0.size > 1 }
        let prefiltered = PanelModel.filtered(model.listedItems, by: filter)
        #expect(model.setFilter(filter, prefiltered: prefiltered, listVersion: model.listVersion))
        #expect(model.items.map(\.size) == model.listedItems.filter(filter.matches).map(\.size))
        #expect(model.items.count == 3)
        model.selectAll()
        #expect(model.selectionCount == 3)
        #expect(model.totals.selectedBytes == 13)
        #expect(model.operands().allSatisfy { $0.size > 1 })
        // Asked again and again (the model makes its index of names on the way): the same answer.
        for _ in 0..<4 {
            #expect(model.items.allSatisfy { model.isSelected($0) })
            #expect(!model.isSelected(items[0]))
        }
        model.setFilter(nil)
        #expect(model.selectionCount == 3)
        let hiddenRow = try #require(model.items.firstIndex { $0.size == 0 }) + 1
        #expect(!model.isSelected(row: hiddenRow))
    }

    private func file(_ name: String, size: Int64) -> FileItem { Fixture.file(name, in: Self.folder, size: size) }
}
