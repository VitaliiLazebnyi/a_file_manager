import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Saved marks (review 2, K010-K020 and the second pass): kept by name, found again in another
/// folder of the same names, and kept cheaply when they are many.
@MainActor
@Suite
internal struct SavedSelectionTests {
    /// The saved names outlive showing another folder and mark there what that folder has of them;
    /// a long saved selection is kept without its names being made.
    @Test
    internal func savedMarksAreFoundAgainInAnotherFolder() {
        let model = Fixture.panel(ModelSample.items(100), at: ModelSample.folder)
        model.setSelected(true, names: ["file1.md", "file2.md", "dir10"])
        model.saveSelection()
        #expect(model.savedSelection == ["file1.md", "file2.md", "dir10"])
        let other = URL(fileURLWithPath: "/review2/other")
        let there = [
            Fixture.file("file2.md", in: other), Fixture.file("zzz", in: other), Fixture.folder("dir10", in: other)
        ]
        model.show(Fixture.listing(there, at: other))
        #expect(model.savedSelection == ["file1.md", "file2.md", "dir10"])
        model.restoreSelection()
        #expect(model.selectedNames.sorted() == ["dir10", "file2.md"])
        // A long saved selection is kept without making its names on the way out.
        let long = Fixture.panel(ModelSample.items(30_000), at: ModelSample.folder)
        long.selectAll()
        long.saveSelection()
        long.show(Fixture.listing(ModelSample.items(40_000), at: ModelSample.folder))
        long.restoreSelection()
        #expect(long.selectionCount == 30_000)
    }

    /// More marks than the model keeps as names: the saved list is restored in another folder
    /// with most of the names in another order, and under a filter only on what is shown.
    @Test
    internal func aLongSavedSelectionIsRestoredInAnotherFolderOfTheSameNames() {
        let count = 60_000
        let folder = URL(fileURLWithPath: "/review2/second")
        let items = (0..<count).map { Fixture.file("f\($0).dat", in: folder, size: Int64($0 % 7)) }
        let model = Fixture.panel(items, at: folder)
        // More than the model keeps as names: the list itself is kept for the saved marks.
        model.select { $0.size != 0 }
        #expect(model.selectionCount > 30_000)
        model.saveSelection()
        // Another folder with most of the names, some gone, some new, in another order.
        let other = URL(fileURLWithPath: "/review2/elsewhere")
        let kept = (0..<count).reversed().filter { !$0.isMultiple(of: 11) }
        let there =
            kept.map { Fixture.file("f\($0).dat", in: other, size: 3) } + [Fixture.file("new.dat", in: other, size: 0)]
        model.show(Listing(directory: other, items: there, parent: folder, root: URL(fileURLWithPath: "/")))
        #expect(!model.hasSelection)
        model.restoreSelection()
        let expected = Set(
            (0..<count).filter { !$0.isMultiple(of: 7) && !$0.isMultiple(of: 11) }.map { "f\($0).dat" }
        )
        #expect(model.selectionCount == expected.count)
        #expect(Set(model.selectedNames) == expected)
        // With a filter on, only what is shown is marked.
        model.setFilter(PanelFilter(title: "ones") { $0.name.hasSuffix("1.dat") })
        model.restoreSelection()
        #expect(Set(model.selectedNames) == expected.filter { $0.hasSuffix("1.dat") })
    }
}
