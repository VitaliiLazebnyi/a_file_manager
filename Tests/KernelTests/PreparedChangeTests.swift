import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Changes of a panel's list prepared on another thread and applied on the main thread
/// (review 2, K010-K020, K041-K046): the same result as the direct call, and refused once the
/// model has moved on.
@MainActor
@Suite
internal struct PreparedChangeTests {
    /// One change, made directly and prepared from a basis.
    internal struct Change {
        /// What the change is, for the messages of failed checks.
        internal let name: String
        /// The change made by the direct call.
        internal let direct: (PanelModel) -> Void
        /// The same change prepared from a basis, on any thread.
        internal let prepare: @Sendable (PanelModel.Basis) -> PanelModel.Prepared
    }

    /// Every kind of change, prepared elsewhere and applied, leaves the model as the direct call
    /// does, saved marks included, announces itself once and keeps the totals right.
    @Test(arguments: [200, 50_000])
    internal func aPreparedChangeIsWhatTheDirectCallDoes(count: Int) throws {
        let items = ModelSample.items(count)
        for change in changes(of: items) {
            let (one, two) = (try prepared(items), try prepared(items))
            change.direct(one)
            var announced = 0
            two.onChange = { kind in
                if kind == .contents {
                    announced += 1
                }
            }
            let basis = two.basis
            // Marks, the cursor and sizes that change while the work is under way are kept.
            let prepare = change.prepare
            let made = try #require(OtherThread.result { prepare(basis) })
            #expect(two.apply(made) == .changed, "\(change.name)")
            #expect(announced == 1, "\(change.name)")
            #expect(PanelFigures.state(one) == PanelFigures.state(two), "\(change.name)")
            #expect(two.totals == PanelFigures.counted(two), "\(change.name)")
            one.restoreSelection()
            two.restoreSelection()
            #expect(PanelFigures.state(one) == PanelFigures.state(two), "\(change.name), saved marks")
        }
    }

    /// Changes prepared before the order changed are all refused and change nothing; what only
    /// touches marks, the cursor or sizes does not make a prepared change stale.
    @Test
    internal func aPreparedChangeOfAModelThatMovedOnIsNotTaken() throws {
        let items = ModelSample.items(400)
        let model = Fixture.panel(items, at: ModelSample.folder)
        let stale = [
            PanelModel.prepare(model.basis, sort: ListOrder(key: .size)),
            PanelModel.prepare(model.basis, filter: .mask("*.txt")),
            PanelModel.prepare(model.basis, update: Fixture.listing(Array(items.dropFirst()), at: ModelSample.folder))
        ]
        let rows = PanelModel.rows(of: model.basis) { $0.name.hasSuffix("txt") }
        model.setSort(ListOrder(key: .ext))
        let before = PanelFigures.state(model)
        var announced = 0
        model.onChange = { _ in announced += 1 }
        for prepared in stale {
            #expect(model.apply(prepared) == .stale)
        }
        #expect(!model.setSelection(rows))
        #expect(PanelFigures.state(model) == before)
        #expect(announced == 0)
        try expectMarksCursorAndSizesDoNotMakeItStale(model)
    }

    /// Prepares a sort, then marks, sizes and moves the cursor: the sort is still taken, and all of that is kept.
    private func expectMarksCursorAndSizesDoNotMakeItStale(_ model: PanelModel) throws {
        let prepared = PanelModel.prepare(model.basis, sort: ListOrder(key: .name, descending: true))
        model.setSelected(true, names: ["file7.md", "file8.md"])
        model.setComputedSizes([(name: "dir20", size: 20), (name: "dir30", size: 30)])
        model.moveCursor(to: try #require(model.row(ofName: "file8.md")))
        #expect(model.apply(prepared) == .changed)
        #expect(model.selectedNames.sorted() == ["file7.md", "file8.md"])
        #expect(model.cursorItem?.name == "file8.md")
        #expect(model.item(atRow: try #require(model.row(ofName: "dir20")))?.computedSize == 20)
        #expect(model.listedItems.first { $0.name == "dir30" }?.computedSize == 30)
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.totals.totalBytes == PanelFigures.counted(model).totalBytes)
    }

    /// A model with a filter, marks, sizes, saved marks and the cursor somewhere in the list.
    private func prepared(_ items: [FileItem]) throws -> PanelModel {
        let model = Fixture.panel(items, at: ModelSample.folder)
        model.setFilter(PanelFilter(title: "no 7") { !$0.name.contains("7") })
        model.setSelected(true, names: ["file3.txt", "file5.md", "dir10", "file13.md", "file33.txt"])
        model.setComputedSizes([(name: "dir10", size: 1_000), (name: "dir70", size: 70)])
        model.saveSelection()
        model.moveCursor(to: try #require(model.row(ofName: "file23.md")))
        return model
    }

    /// Sorting, turning round, filtering, unfiltering, a fresh reading and a list that grew.
    private func changes(of items: [FileItem]) -> [Change] {
        let filter = PanelFilter(title: "3") { $0.isFolder || $0.name.contains("3") }
        let fresh = Fixture.listing(
            Array(items.dropFirst(4))
                + [
                    Fixture.file("new3.txt", in: ModelSample.folder, size: 9),
                    Fixture.folder("newdir", in: ModelSample.folder)
                ],
            at: ModelSample.folder
        )
        let byExtension = ListOrder(key: .ext)
        let grown = Sorter.sort(
            items + [Fixture.file("zz3.txt", in: ModelSample.folder), Fixture.file("aa.md", in: ModelSample.folder)],
            by: byExtension
        )
        let bySize = ListOrder(key: .size, descending: true)
        let turned = ListOrder(key: .name, descending: true)
        return [
            Change(name: "sort", direct: { $0.setSort(bySize) }, prepare: { PanelModel.prepare($0, sort: bySize) }),
            Change(name: "turn", direct: { $0.setSort(turned) }, prepare: { PanelModel.prepare($0, sort: turned) }),
            Change(
                name: "filter",
                direct: { $0.setFilter(filter) },
                prepare: { PanelModel.prepare($0, filter: filter) }
            ),
            Change(name: "no filter", direct: { $0.setFilter(nil) }, prepare: { PanelModel.prepare($0, filter: nil) }),
            Change(
                name: "update",
                direct: { $0.update(with: fresh) },
                prepare: { PanelModel.prepare($0, update: fresh) }
            ),
            Change(
                name: "extend",
                direct: { $0.extend(to: grown, sortedBy: byExtension) },
                prepare: { PanelModel.prepare($0, extendingTo: grown, sortedBy: byExtension) }
            )
        ]
    }
}
