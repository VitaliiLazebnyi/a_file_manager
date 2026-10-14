import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Calculated sizes prepared off the main thread (review 2, second pass, K033): the copy of the
/// list is made where `prepare` runs, and what was prepared is refused once it is out of date.
@MainActor
@Suite
internal struct PreparedSizeTests {
    private static let folder = URL(fileURLWithPath: "/review2/second")

    /// Sizes prepared on another thread give exactly what the direct call gives (sizes in both
    /// lists, totals, marks, cursor), with or without a filter, without moving the versions.
    @Test(arguments: [false, true])
    internal func calculatedSizesCanBePreparedInTheBackground(filtered: Bool) throws {
        let items = (0..<300).map { $0.isMultiple(of: 3) ? folder("dir\($0)") : file("file\($0).txt", size: Int64($0)) }
        let (model, plain) = (panel(items), panel(items))
        for each in [model, plain] {
            if filtered {
                each.setFilter(PanelFilter(title: "some") { !$0.isFolder || $0.name.hasSuffix("0") })
            }
            each.setSelected(true, names: ["dir30", "file1.txt"])
            each.moveCursor(to: 7)
        }
        let sizes: [(name: String, size: Int64)] = [("dir0", 1_000), ("dir30", 500), ("dir3", 70), ("nobody", 9)]
        // The basis holds the list as well: the copy is made where `prepare` runs.
        let basis = model.basis
        let (version, shown) = (model.listVersion, model.shownVersion)
        let prepared = try #require(OtherThread.result { PanelModel.prepare(basis, computedSizes: sizes) })
        var announced: [PanelModel.Change] = []
        model.onChange = { announced.append($0) }
        #expect(model.apply(prepared) == .changed)
        plain.setComputedSizes(sizes)
        // Exactly what the direct call gives: sizes in both lists, totals, marks, cursor.
        #expect(model.items == plain.items)
        #expect(model.listedItems == plain.listedItems)
        #expect(model.totals == plain.totals)
        #expect(model.selectedNames == plain.selectedNames)
        #expect(model.cursor == plain.cursor)
        #expect(model.listedItems.first { $0.name == "dir3" }?.computedSize == 70)
        // The list is not another list for it.
        #expect(model.listVersion == version)
        #expect(model.shownVersion == shown)
        #expect(announced.count == 1)
        // A size set later, by either route, lands on top of these.
        plain.setComputedSizes([(name: "dir6", size: 11)])
        model.setComputedSizes([(name: "dir6", size: 11)])
        #expect(model.listedItems == plain.listedItems)
        #expect(model.totals == plain.totals)
    }

    /// Prepared sizes are refused after another size was set or the list changed, taken when
    /// prepared again, and report when no name was found; they survive an earlier prepared sort.
    @Test
    internal func preparedSizesAreRefusedWhenAnythingTheyRestOnHasChanged() {
        let model = panel((0..<50).map { folder("dir\($0)") })
        // Another size was set meanwhile: taking the prepared list would lose it.
        var prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "dir1", size: 10)])
        model.setComputedSizes([(name: "dir2", size: 5)])
        #expect(model.apply(prepared) == .stale)
        #expect(size(of: "dir2", in: model) == 5)
        #expect(size(of: "dir1", in: model) == nil)
        // Prepared again from the model as it is now, both are there.
        prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "dir1", size: 10)])
        #expect(model.apply(prepared) == .changed)
        #expect(size(of: "dir2", in: model) == 5)
        #expect(size(of: "dir1", in: model) == 10)
        // The list changed meanwhile.
        prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "dir3", size: 1)])
        model.setSort(ListOrder(key: .name, descending: true))
        #expect(model.apply(prepared) == .stale)
        // No name was found: nothing to do, and the model says so.
        prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "nobody", size: 1)])
        #expect(model.apply(prepared) == .unchanged)
        // The sizes survive a sort that was prepared before they were set.
        let sorted = PanelModel.prepare(model.basis, sort: ListOrder(key: .name))
        #expect(model.apply(PanelModel.prepare(model.basis, computedSizes: [(name: "dir7", size: 77)])) == .changed)
        #expect(model.apply(sorted) == .changed)
        #expect(size(of: "dir7", in: model) == 77)
        #expect(size(of: "dir1", in: model) == 10)
    }

    /// A size asked for with `é` written as `e` and an accent finds the folder whose name has it
    /// as one character.
    @Test
    internal func aNameWrittenInAnotherFormFindsItsFolderWhenSizesArePrepared() {
        let model = panel([folder("caf\u{E9}"), folder("plain")])
        let prepared = PanelModel.prepare(model.basis, computedSizes: [(name: "cafe\u{301}", size: 42)])
        #expect(model.apply(prepared) == .changed)
        #expect(model.listedItems.first { $0.name.hasPrefix("caf") }?.computedSize == 42)
    }

    private func file(_ name: String, size: Int64) -> FileItem { Fixture.file(name, in: Self.folder, size: size) }

    private func folder(_ name: String) -> FileItem { Fixture.folder(name, in: Self.folder) }

    private func panel(_ items: [FileItem]) -> PanelModel { Fixture.panel(items, at: Self.folder) }

    /// The calculated size of the listed entry called `name`.
    private func size(of name: String, in model: PanelModel) -> Int64? {
        model.listedItems.first { $0.name == name }?.computedSize
    }
}
