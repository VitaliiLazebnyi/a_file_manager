import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Calculated folder sizes in a panel's list (review 2, K030, K033): on the right entry in both
/// lists whatever the filter, set in one pass, and kept through refreshes and sorts.
@MainActor
@Suite
internal struct CalculatedSizeTests {
    /// Folders whose names read the same, one hidden by the filter (the fuzzer's reproducer):
    /// each size lands on its own folder in the listed and the shown list, and the totals agree.
    @Test
    internal func sizesGoToTheSameEntryInBothListsWhateverTheFilter() throws {
        let (composed, decomposed) = ("d\u{E9}", "de\u{301}")
        let items =
            [folder(composed), folder(decomposed), folder("plain"), Fixture.file("x.txt", in: ModelSample.folder)]
            + (0..<200).map { folder("f\($0)") }
        let model = Fixture.panel(items, at: ModelSample.folder)
        model.setFilter(PanelFilter(title: "not decomposed") { !ExactName.areSame($0.name, decomposed) })
        model.setComputedSizes([
            (name: decomposed, size: 11), (name: composed, size: 22), (name: "plain", size: 33), (name: "f7", size: 7)
        ])
        #expect(
            sizes(model.listedItems) == [
                Array(decomposed.utf8): 11, Array(composed.utf8): 22, Array("plain".utf8): 33, Array("f7".utf8): 7
            ]
        )
        #expect(sizes(model.items) == [Array(composed.utf8): 22, Array("plain".utf8): 33, Array("f7".utf8): 7])
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.totals.totalBytes == 22 + 33 + 7 + 1)
        // What is shown is still the listed entries the filter lets through, sizes and all.
        let filter = try #require(model.filter)
        let shown = model.listedItems.filter { filter.matches($0) }
        #expect(shown.map(\.computedSize) == model.items.map(\.computedSize))
        model.setFilter(nil)
        #expect(sizes(model.items) == sizes(model.listedItems))
        #expect(model.totals.totalBytes == 11 + 22 + 33 + 7 + 1)
    }

    /// Ten thousand sizes in a list of sixty thousand with a filter are set in one walk of the
    /// list (one walk per name would be six hundred million comparisons).
    @Test
    internal func manySizesWithAFilterOnTakeOnePassNotOnePerName() throws {
        let items = (0..<60_000)
            .map { index in
                index.isMultiple(of: 2)
                    ? folder("dir\(index)") : Fixture.file("file\(index).txt", in: ModelSample.folder)
            }
        let model = Fixture.panel(items, at: ModelSample.folder)
        model.setFilter(PanelFilter(title: "even") { $0.isFolder })
        let sizes = (0..<10_000).map { (name: "dir\($0 * 2)", size: Int64($0)) }
        model.setComputedSizes(sizes)
        #expect(model.totals.totalBytes == Int64((0..<10_000).reduce(0, +)))
        #expect(model.item(atRow: try #require(model.row(ofName: "dir19998")))?.computedSize == 9_999)
        #expect(model.listedItems.filter { $0.computedSize != nil }.count == 10_000)
    }

    /// Sizes survive a fresh reading and a presorted list that carries none.
    @Test
    internal func sizesSurviveARefreshASortAndAStreamedList() {
        let items = ModelSample.items(300)
        let model = Fixture.panel(items, at: ModelSample.folder)
        model.setComputedSizes([(name: "dir0", size: 5), (name: "dir290", size: 9)])
        model.update(
            with: Fixture.listing(
                Array(items.dropFirst(3)) + [folder("dir0"), Fixture.file("fresh.txt", in: ModelSample.folder)],
                at: ModelSample.folder
            )
        )
        #expect(model.listedItems.first { $0.name == "dir0" }?.computedSize == 5)
        #expect(model.listedItems.first { $0.name == "dir290" }?.computedSize == 9)
        let plain = model.listedItems.map { item in
            FileItem(
                url: item.url,
                name: item.name,
                kind: .init(isDirectory: item.isDirectory),
                stat: .init(size: item.size)
            )
        }
        model.setSort(ListOrder(key: .date), presorted: Sorter.sort(plain, by: ListOrder(key: .date)))
        #expect(model.listedItems.filter { $0.computedSize != nil }.map(\.name).sorted() == ["dir0", "dir290"])
        #expect(model.totals == PanelFigures.counted(model))
    }

    private func folder(_ name: String) -> FileItem { Fixture.folder(name, in: ModelSample.folder) }

    /// The calculated sizes of `items`, by the bytes of their names.
    private func sizes(_ items: [FileItem]) -> [[UInt8]: Int64] {
        Dictionary(
            uniqueKeysWithValues: items.compactMap { item in item.computedSize.map { (Array(item.name.utf8), $0) } }
        )
    }
}
