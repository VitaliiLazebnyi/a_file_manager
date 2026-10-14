import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The version of a panel's list (review 2, K010-K020): it moves for another list only, never
/// for sizes, filters or marks, so that work prepared elsewhere can tell whether it is still current.
@MainActor
@Suite
internal struct ListVersionTests {
    /// A refresh that finds the directory as it was, calculated sizes, filters and marks leave
    /// the version alone; another order and another reading each move it by one.
    @Test
    internal func onlyAChangedListMovesTheVersion() throws {
        let items = ModelSample.items(300)
        let model = Fixture.panel(items, at: ModelSample.folder)
        let version = model.listVersion
        var announced = 0
        model.onChange = { _ in announced += 1 }
        // A refresh that found the directory as it was.
        #expect(!model.update(with: listing(items.reversed())))
        #expect(model.listVersion == version)
        #expect(announced == 0)
        // Calculated sizes, filters, marks.
        model.setComputedSizes([(name: "dir0", size: 500), (name: "dir10", size: 7)])
        model.setFilter(PanelFilter.mask("*.txt"))
        _ = model.setFilter(
            PanelFilter.mask("*.md"),
            prefiltered: PanelModel.filtered(model.listedItems, by: .mask("*.md")),
            listVersion: version
        )
        model.setFilter(nil)
        model.selectAll()
        #expect(model.listVersion == version)
        // The same refresh again, now that folders have sizes: still nothing new.
        #expect(!model.update(with: listing(items)))
        #expect(model.listVersion == version)
        let dirRow = try #require(model.row(ofName: "dir0"))
        #expect(model.item(atRow: dirRow)?.computedSize == 500)
        // Another order and another reading are other lists.
        model.setSort(ListOrder(key: .size))
        #expect(model.listVersion == version + 1)
        #expect(model.update(with: listing(Array(items.dropLast()))))
        #expect(model.listVersion == version + 2)
    }

    /// A prepared refresh that found nothing new is applied as unchanged, quietly and with the
    /// marks kept; one of another directory shows that directory, as `update` does.
    @Test
    internal func aRefreshThatFoundNothingNewIsAppliedAsUnchanged() {
        let items = ModelSample.items(300)
        let model = Fixture.panel(items, at: ModelSample.folder)
        model.setSelected(true, names: ["file1.md"])
        var announced = 0
        model.onChange = { _ in announced += 1 }
        let version = model.listVersion
        #expect(model.apply(PanelModel.prepare(model.basis, update: listing(items))) == .unchanged)
        #expect(announced == 0)
        #expect(model.listVersion == version)
        #expect(model.selectionCount == 1)
        // Another directory is shown, as `update` does it.
        let other = URL(fileURLWithPath: "/review2/other")
        let elsewhere = Fixture.listing([Fixture.file("x.txt", in: other)], at: other)
        #expect(model.apply(PanelModel.prepare(model.basis, update: elsewhere)) == .changed)
        #expect(model.directory.path == other.path)
        #expect(model.items.map(\.name) == ["x.txt"])
        #expect(model.selectionCount == 0)
    }

    private func listing(_ items: [FileItem]) -> Listing { Fixture.listing(items, at: ModelSample.folder) }
}
