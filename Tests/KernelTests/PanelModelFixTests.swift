import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The panel model keeps its index of names, its totals and its marks right through every
/// change, and announces a change made in one step once.
@MainActor
@Suite
internal struct PanelModelFixTests {
    /// The folder every model here shows.
    private static let directory = URL(fileURLWithPath: "/work", isDirectory: true)

    /// A model showing the three hundred numbered entries, sorted by name.
    private static func model() -> PanelModel {
        Fixture.panel(TmpEntries.numbered, at: directory)
    }

    /// Whether every shown entry is found at its own row by its name (`[..]` is row 0).
    private static func rowsMatchNames(_ model: PanelModel) -> Bool {
        model.items.enumerated().allSatisfy { index, item in model.row(ofName: item.name) == index + 1 }
    }

    /// Checks that a row is found by its name however often it is asked, and that the index of
    /// names follows the list through another order and a filter.
    @Test
    internal func rowsAreFoundByNameThroughEveryChange() {
        let model = Self.model()
        for _ in 0..<3 {
            #expect(Self.rowsMatchNames(model))
            #expect(model.row(ofName: "missing") == nil)
        }
        model.setSort(ListOrder(key: .size, descending: true))
        #expect(Self.rowsMatchNames(model))
        model.setFilter(.mask("*7.txt"))
        #expect(model.row(ofName: "file7.txt") != nil && model.row(ofName: "file8.txt") == nil)
        #expect(Self.rowsMatchNames(model))
    }

    /// Checks the totals against a count from scratch after marks by row, by range and by name.
    @Test
    internal func theTotalsStayRightThroughMarks() {
        let model = Self.model()
        #expect(model.totals == PanelFigures.counted(model))
        model.toggleSelection(row: 5)
        model.toggleSelection(row: 1)
        #expect(model.totals == PanelFigures.counted(model) && model.totals.selectedFolders == 2)
        model.toggleSelection(row: 5)
        model.setSelected(true, rows: 10...40)
        model.setSelected(false, rows: 20...25)
        model.setSelected(true, rows: 0...3)
        #expect(model.totals == PanelFigures.counted(model))
        model.setSelected(true, names: ["file7.txt", "folder0", "missing", "file7.txt"])
        #expect(model.selection.contains("file7.txt") && !model.selection.contains("missing"))
        #expect(model.totals == PanelFigures.counted(model))
        model.setSelected(false, names: ["file7.txt", "file12.txt"])
        #expect(model.totals == PanelFigures.counted(model))
        model.invertSelection()
        #expect(model.totals == PanelFigures.counted(model))
        model.deselect(["file1.txt", "file2.txt"])
        #expect(model.totals == PanelFigures.counted(model))
    }

    /// Checks the totals against a count from scratch after calculated sizes, with and without a
    /// filter, and after a fresh reading.
    @Test
    internal func theTotalsStayRightThroughSizesFiltersAndReadings() {
        let model = Self.model()
        model.setSelected(true, names: ["folder0", "folder10"])
        model.setComputedSize(5_000, forName: "folder0")
        #expect(model.totals == PanelFigures.counted(model) && model.totals.selectedBytes >= 5_000)
        model.setComputedSize(70, forName: "folder0")
        model.setComputedSize(9, forName: "folder10")
        #expect(model.totals == PanelFigures.counted(model))
        model.setComputedSizes(["folder20": 11, "folder30": 12, "missing": 13])
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.items.first { $0.name == "folder30" }?.computedSize == 12)
        #expect(model.listedItems.first { $0.name == "folder20" }?.computedSize == 11)
        model.setFilter(.mask("*1.txt"))
        #expect(model.totals == PanelFigures.counted(model))
        model.setComputedSize(8, forName: "folder40")
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.listedItems.first { $0.name == "folder40" }?.computedSize == 8)
        model.setFilter(nil)
        model.selectAll()
        model.update(with: Fixture.listing(Array(TmpEntries.numbered.dropFirst(7)), at: Self.directory))
        #expect(model.totals == PanelFigures.counted(model))
        #expect(model.items.first { $0.name == "folder20" }?.computedSize == 11)
    }

    /// Checks that several sizes, or several marks by name, are announced once, and that a
    /// batch that changes nothing is not announced.
    @Test
    internal func batchChangesAreAnnouncedOnce() {
        let model = Self.model()
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.setComputedSizes(["folder0": 1, "folder10": 2, "folder20": 3])
        #expect(changes == 1)
        model.setSelected(true, names: ["file1.txt", "file2.txt", "file3.txt"])
        #expect(changes == 2 && model.selection.count == 3)
        model.setComputedSizes(["missing": 1])
        model.setComputedSizes([:])
        #expect(changes == 2)
    }

    /// Checks that replacing the marks by a set of names is one announcement, unknown names
    /// left out, and that an empty set clears them.
    @Test
    internal func theSelectionIsReplacedInOneAnnouncement() {
        let model = Self.model()
        model.setSelected(true, names: ["file1.txt", "file2.txt"])
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.setSelection(names: ["file2.txt", "file3.txt", "missing"])
        #expect(changes == 1 && model.selection == ["file2.txt", "file3.txt"])
        #expect(model.totals == PanelFigures.counted(model))
        model.setSelection(names: [] as [String])
        #expect(changes == 2 && model.selection.isEmpty)
    }

    /// Without marks the cursor decides whether a file is among the operands (on `[..]` and on
    /// a folder there is none); with marks, the marks decide, even with the cursor on a file.
    @Test
    internal func whetherAFileIsAnOperandIsFoundWithoutTheList() throws {
        let model = Self.model()
        model.moveCursor(to: 0)
        #expect(!model.hasOperandFile)
        model.moveCursor(to: try #require(model.row(ofName: "folder0")))
        #expect(!model.hasOperandFile)
        model.moveCursor(to: try #require(model.row(ofName: "file1.txt")))
        #expect(model.hasOperandFile)
        model.setSelected(true, names: ["folder0", "folder10"])
        #expect(!model.hasOperandFile)
        model.setSelected(true, names: ["file7.txt"])
        #expect(model.hasOperandFile)
    }

    /// Checks that narrowing a filter gives what setting the narrow filter gives: entries,
    /// marks, cursor and totals, while the list itself stays what it was.
    @Test
    internal func aNarrowingFilterGivesWhatTheFullFilterGives() throws {
        let wide = PanelFilter(title: "wide") { $0.isFolder || $0.name.contains("1") }
        let narrow = PanelFilter(title: "narrow") { $0.isFolder || $0.name.contains("12") }
        let (narrowed, whole) = (Self.model(), Self.model())
        narrowed.setSelected(true, names: ["file12.txt", "file120.txt", "file5.txt"])
        whole.setSelected(true, names: ["file12.txt", "file120.txt", "file5.txt"])
        narrowed.setFilter(wide)
        narrowed.moveCursor(to: try #require(narrowed.row(ofName: "file12.txt")))
        let version = narrowed.listVersion
        narrowed.setFilter(narrow, narrowing: true)
        whole.setFilter(narrow)
        // A filter shows less of the list; the list itself is what it was.
        #expect(narrowed.listVersion == version)
        #expect(narrowed.items.map(\.name) == whole.items.map(\.name) && narrowed.listedItems.count == 300)
        #expect(narrowed.selection == whole.selection && narrowed.cursorItem?.name == "file12.txt")
        #expect(narrowed.totals == PanelFigures.counted(narrowed))
        // Taking the filter off shows everything again.
        narrowed.setFilter(nil)
        #expect(narrowed.items.count == 300)
    }
}
