import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Snapshots and copies of a panel's tab (review 2, K010-K020): what they bring back and what
/// they say about the state of the list.
@MainActor
@Suite
internal struct SnapshotAndCopyTests {
    /// A snapshot restored after the filter was dropped, another folder opened and the order
    /// changed brings back the filter and the marks, in the order the panel has now.
    @Test
    internal func aSnapshotBringsBackTheFilterAndAnswersToThePresentOrder() {
        let items = ModelSample.items(1_000)
        let model = Fixture.panel(items, at: ModelSample.folder)
        let filter = PanelFilter(title: "7") { $0.name.contains("7") }
        model.setFilter(filter)
        model.setSelected(true, names: ["file7.md", "file17.md"])
        let shown = model.items.map(\.name)
        let snapshot = model.snapshot()
        #expect(snapshot.filter?.title == "7")
        #expect(snapshot.sort == ListOrder())
        // The shell drops the quick filter, opens another folder, the order is changed meanwhile,
        // and the reading fails.
        model.setFilter(nil)
        model.open(
            URL(fileURLWithPath: "/review2/elsewhere"),
            parent: ModelSample.folder,
            root: URL(fileURLWithPath: "/")
        )
        model.setSort(ListOrder(key: .size, descending: true))
        model.restore(snapshot)
        #expect(model.filter?.title == "7")
        #expect(model.items.count == shown.count)
        #expect(model.listedItems.count == 1_000)
        #expect(Set(model.items.map(\.name)) == Set(shown))
        #expect(model.selectedNames.sorted() == ["file17.md", "file7.md"])
        // The list is in the order the panel names.
        #expect(model.sort == ListOrder(key: .size, descending: true))
        #expect(model.listedItems.map(\.name) == Sorter.sort(items, by: model.sort).map(\.name))
        #expect(model.items.map(\.name) == Sorter.sort(items, by: model.sort).filter(filter.matches).map(\.name))
        // Turning the direction round turns it round.
        model.setSort(ListOrder(key: .size))
        #expect(model.listedItems.map(\.name) == Sorter.sort(items, by: ListOrder(key: .size)).map(\.name))
        #expect(model.totals == PanelFigures.counted(model))
    }

    /// A copy of a tab still loading is not complete, one of a finished tab is, and one of a
    /// remembered listing is still refreshing; marks in the copy are its own.
    @Test
    internal func aCopyOfATabThatIsStillLoadingSaysSo() {
        let model = PanelModel(directory: ModelSample.folder)
        model.show(Fixture.listing(ModelSample.items(20), at: ModelSample.folder), complete: false)
        let copy = model.duplicate()
        #expect(!copy.isComplete)
        #expect(copy.items.count == 20)
        #expect(copy.selectionCount == 0)
        copy.selectAll()
        #expect(copy.selectionCount == 20)
        model.finishLoading()
        #expect(model.duplicate().isComplete)
        let remembered = PanelModel(directory: ModelSample.folder)
        remembered.showRemembered(Fixture.listing(ModelSample.items(20), at: ModelSample.folder))
        #expect(remembered.duplicate().isRefreshing)
    }
}
