import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Marks in a panel's list (review 2, K010-K020): cheap on long lists, with figures that agree
/// with the rows, and each on its own entry when names repeat or read the same.
@MainActor
@Suite
internal struct MarkTests {
    /// Marking everything, inverting, unmarking by condition and by mask, and restoring saved
    /// marks in a list of 200,000 keep the count and the totals right.
    @Test
    internal func marksOfALongListCostNothingAndTheFiguresAreRight() throws {
        let count = 200_000
        let model = Fixture.panel(ModelSample.items(count), at: ModelSample.folder)
        model.selectAll()
        #expect(model.selectionCount == count)
        #expect(model.totals == PanelFigures.counted(model))
        model.toggleSelection(row: try #require(model.row(ofName: "file7.md")))
        model.invertSelection()
        #expect(model.selectedNames == ["file7.md"])
        #expect(model.totals == PanelFigures.counted(model))
        model.invertSelection()
        #expect(model.selectionCount == count - 1)
        #expect(model.totals == PanelFigures.counted(model))
        model.saveSelection()
        model.select(where: { $0.isFolder }, select: false)
        #expect(model.selectionCount == count - 1 - count / 10)
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.totals.selectedFolders == 0)
        model.select(mask: "*.txt", select: false)
        #expect(model.operands().allSatisfy { $0.name.hasSuffix(".md") })
        #expect(model.totals == PanelFigures.counted(model))
        model.restoreSelection()
        #expect(model.selectionCount == count - 1)
        #expect(!model.isSelected(row: try #require(model.row(ofName: "file7.md"))))
        try expectEverythingShownAndRowsFoundElsewhere(model)
    }

    /// The same entry name twice, in two folders: a mark on a row is a mark on that entry, a name
    /// stands for both, and marks stay with their entries through another order and reading.
    @Test(arguments: [0, 300])
    internal func theSameNameTwiceIsTwoEntriesEverywhere(others: Int) throws {
        // A list gathered from several folders: two files of the very same name.
        let (first, second) = (URL(fileURLWithPath: "/review2/a"), URL(fileURLWithPath: "/review2/b"))
        let items =
            [
                Fixture.file("twin.txt", in: first, size: 2), Fixture.file("twin.txt", in: second, size: 5),
                Fixture.file("single.txt", in: ModelSample.folder)
            ]
            + (0..<others).map { Fixture.file("other\($0).txt", in: ModelSample.folder) }
        let model = Fixture.panel(items, at: ModelSample.folder)
        let rows = model.items.indices.filter { model.items[$0].name == "twin.txt" }.map { $0 + 1 }
        try #require(rows.count == 2)
        // A mark on a row is a mark on that entry: the figures, the count and the operands agree,
        // whether or not the model has made its index of names yet.
        model.toggleSelection(row: rows[1])
        #expect(model.selectionCount == 1)
        #expect(model.totals.selectedFiles == 1)
        #expect(model.operands().count == 1)
        #expect(model.totals.selectedBytes == model.operands()[0].size)
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.isSelected(model.items[rows[1] - 1]))
        #expect(!model.isSelected(model.items[rows[0] - 1]))
        expectANameStandsForBothTwins(model)
        // The marks stay with their entries through another order and another reading.
        model.toggleSelection(row: rows[1])
        let marked = model.operands()[0].url
        model.setSort(ListOrder(key: .size, descending: true))
        #expect(model.operands().map(\.url) == [marked])
        #expect(model.totals == PanelFigures.counted(model))
        model.update(
            with: Fixture.listing(items + [Fixture.file("more.txt", in: ModelSample.folder)], at: ModelSample.folder)
        )
        #expect(model.operands().map(\.url) == [marked])
        #expect(model.selectionCount == 1)
    }

    /// The names as written tell apart two names that are equal as strings; the set of strings
    /// cannot, as its documentation says.
    @Test
    internal func namesThatReadTheSameAreToldApartByWhoeverAsksForTheNamesAsWritten() {
        let (composed, decomposed) = ("caf\u{E9}.txt", "cafe\u{301}.txt")
        let model = Fixture.panel(
            [
                Fixture.file(composed, in: ModelSample.folder, size: 2),
                Fixture.file(decomposed, in: ModelSample.folder, size: 3),
                Fixture.file("plain.txt", in: ModelSample.folder)
            ],
            at: ModelSample.folder
        )
        model.selectAll()
        #expect(model.selectionCount == 3)
        #expect(model.selectedNames.count == 3)
        #expect(Set(model.selectedNames.map { Array($0.utf8) }).count == 3)
        // The set of `String`s cannot hold both, as its documentation says.
        #expect(model.selection.count == 2)
    }

    /// A range of every integer marks the list; ranges outside it mark nothing and stop nothing.
    @Test
    internal func aRangeFarLongerThanTheListMarksTheList() {
        let model = Fixture.panel(ModelSample.items(50), at: ModelSample.folder)
        model.setSelected(true, rows: Int.min...Int.max)
        #expect(model.selectionCount == 50)
        // Ranges that lie outside the list altogether mark nothing and stop nothing.
        model.setSelected(false, rows: 60...70)
        model.setSelected(false, rows: -9...(-3))
        model.setSelected(false, rows: 51...51)
        #expect(model.selectionCount == 50)
        model.setSelected(false, rows: 0...0)
        #expect(model.selectionCount == 50)
        model.setSelected(false, rows: 1...3)
        #expect(model.selectionCount == 47)
    }

    /// With a filter on, everything means everything shown; rows found on another thread mark,
    /// add and take away like any other set of rows.
    private func expectEverythingShownAndRowsFoundElsewhere(_ model: PanelModel) throws {
        model.setFilter(.mask("*.txt"))
        model.selectAll()
        #expect(model.selectionCount == model.items.count)
        #expect(model.totals == PanelFigures.counted(model))
        model.invertSelection()
        #expect(model.selectionCount == 0)
        #expect(!model.hasSelection)
        // A set of rows found on another thread.
        let basis = model.basis
        let rows = try #require(OtherThread.result { PanelModel.rows(of: basis) { !$0.isFolder && $0.size > 50 } })
        #expect(model.setSelection(rows))
        #expect(model.selectionCount == rows.count)
        #expect(rows.count >= 1)
        #expect(model.operands().allSatisfy { $0.size > 50 && $0.name.hasSuffix(".txt") })
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.setSelection(rows, .remove))
        #expect(model.selectionCount == 0)
        #expect(model.setSelection(rows, .add))
        #expect(model.selectionCount == rows.count)
    }

    /// Marking by the twins' name marks both; the figures follow, also once the model has its index of names.
    private func expectANameStandsForBothTwins(_ model: PanelModel) {
        model.clearSelection()
        model.setSelected(true, names: ["twin.txt"])
        #expect(model.selectionCount == 2)
        #expect(model.totals.selectedFiles == 2)
        #expect(model.totals.selectedBytes == 7)
        #expect(model.operands().count == 2)
        for _ in 0..<4 {
            _ = model.row(ofName: "single.txt")
        }
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.selectionCount == 2)
        model.setSelected(false, names: ["twin.txt"])
        #expect(model.selectionCount == 0)
        #expect(model.totals.selectedBytes == 0)
    }
}
