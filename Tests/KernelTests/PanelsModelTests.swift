import Foundation
import Testing

@testable import AFMKernel

/// The panel model in the cases the other suites leave out: lists replaced while marks, sizes and
/// the cursor have to follow their entries, twins, saved selections of long lists, and the
/// history.
@MainActor
@Suite
internal struct PanelsModelTests {
    private static let directory = URL(fileURLWithPath: "/panels")

    private static func file(_ name: String, size: Int64 = 10, in folder: URL = directory) -> FileItem {
        FileItem(url: folder.appendingPathComponent(name), name: name, stat: .init(size: size))
    }

    private static func folder(_ name: String, in parent: URL = directory) -> FileItem {
        FileItem(url: parent.appendingPathComponent(name), name: name, kind: .directory)
    }

    private static func listing(_ items: [FileItem], at directory: URL = directory) -> Listing {
        Listing(directory: directory, items: items, parent: URL(fileURLWithPath: "/"), root: URL(fileURLWithPath: "/"))
    }

    private static func model(_ items: [FileItem]) -> PanelModel {
        let model = PanelModel(directory: directory)
        model.show(listing(items))
        return model
    }

    /// A size calculated while a filter was worked out in the background reaches what is shown.
    @Test
    internal func aSizeSetWhileAFilterIsMadeIsShown() {
        let model = Self.model([Self.folder("a"), Self.folder("b"), Self.file("c.txt")])
        let prepared = PanelModel.prepare(model.basis, filter: PanelFilter(title: "folders") { $0.isFolder })
        model.setComputedSizes([(name: "b", size: 77)])
        #expect(model.apply(prepared) == .changed)
        #expect(model.items.map(\.name) == ["a", "b"] && model.items[1].computedSize == 77)
    }

    /// Ending a load that has ended announces nothing.
    @Test
    internal func finishingTwiceAnnouncesOnce() {
        let model = PanelModel(directory: Self.directory)
        model.show(Self.listing([Self.file("a")]), complete: false)
        var changes = 0
        model.onChange = { _ in changes += 1 }
        model.finishLoading()
        model.finishLoading()
        #expect(changes == 1 && model.isComplete)
    }

    /// When the cursor's item is not in the grown list, the cursor stays inside the list.
    @Test
    internal func theCursorStaysInsideAListThatLostItsItem() {
        let model = PanelModel(directory: Self.directory)
        let items = (0..<5).map { Self.file("f\($0)") }
        model.show(Self.listing(items), complete: false)
        model.moveCursor(to: model.row(ofName: "f4") ?? 0)
        model.extend(to: Array(items.prefix(2)), sortedBy: model.sort)
        #expect(model.cursor == model.rowCount - 1 && model.cursorItem?.name == "f1")
    }

    /// The calculated size of a file is not carried into a fresh reading; a folder's is.
    @Test
    internal func aFreshReadingTakesTheSizesOfFoldersOnly() {
        let model = Self.model([Self.folder("d"), Self.file("f"), Self.file("g")])
        model.setComputedSizes([(name: "d", size: 5), (name: "f", size: 6)])
        model.setComputedSizes([(name: "d", size: 7)])
        model.update(with: Self.listing([Self.folder("d"), Self.file("f"), Self.file("h")]))
        #expect(model.listedItems.first { $0.name == "d" }?.computedSize == 7)
        #expect(model.listedItems.first { $0.name == "f" }?.computedSize == nil)
    }

    /// Very many marked entries are found again all at once when the list is read again.
    @Test
    internal func manyMarksAreFoundAgainAtOnce() {
        let items = (0..<25_000).map { Self.file("f\($0)") }
        let model = Self.model(items)
        model.selectAll()
        model.update(with: Self.listing(items.reversed() + [Self.file("new")]))
        #expect(model.selectionCount == 25_000 && !model.isSelected(Self.file("new")))
    }

    /// Without a filter the marked indexes are the marked places; the answer about files is kept.
    @Test
    internal func operandsOfAnUnfilteredList() {
        let model = Self.model([Self.folder("d"), Self.file("a"), Self.file("b")])
        model.setSelected(true, names: ["a", "d"])
        let operands = model.operandsSnapshot()
        #expect(operands.markedIndices() == [0, 1] && operands.isMarked(at: 1) && !operands.isMarked(at: 2))
        #expect(model.hasOperandFile && model.hasOperandFile)
        model.setSelection(names: ["d"])
        #expect(!model.hasOperandFile && !model.hasOperandFile)
        model.clearSelection()
        model.moveCursor(to: 0)
        #expect(model.operandsSnapshot().items().isEmpty && model.operands().isEmpty)
    }

    /// Two entries of one name in different folders are two entries, each with its own mark.
    @Test
    internal func twinsAreMarkedOneByOne() {
        let other = URL(fileURLWithPath: "/elsewhere")
        let first = Self.file("same", size: 1)
        let second = Self.file("same", size: 2, in: other)
        let model = Self.model([first, second, Self.file("x")])
        #expect(!model.isSelected(first))
        model.setSelected(true, rows: (model.offset + 1)...(model.offset + 1))
        #expect(!model.isSelected(first) && model.isSelected(second))
        // An older reading of the second: found by its location.
        #expect(model.isSelected(Self.file("same", size: 9, in: other)))
        #expect(!model.isSelected(Self.file("absent")))
        model.setFilter(PanelFilter(title: "big") { $0.size > 1 })
        #expect(model.isSelected(Self.file("same", size: 9, in: URL(fileURLWithPath: "/third"))))
    }

    /// Restore Selection with nothing saved, with many names, and with a long list left behind.
    @Test
    internal func savedSelectionsComeBackInEveryForm() {
        let model = Self.model((0..<20).map { Self.file("f\($0)") })
        model.setSelected(true, names: ["f1"])
        model.restoreSelection()
        #expect(!model.hasSelection)
        model.setSelection(names: (0..<10).map { "f\($0)" })
        model.saveSelection()
        let other = URL(fileURLWithPath: "/other")
        model.show(Self.listing((0..<12).map { Self.file("f\($0)", in: other) }, at: other))
        model.restoreSelection()
        #expect(model.selectionCount == 10)
        let long = Self.model((0..<6_000).map { Self.file("g\($0)") })
        long.selectAll()
        long.saveSelection()
        long.show(Self.listing((0..<100).map { Self.file("g\($0)", in: other) }, at: other))
        long.restoreSelection()
        #expect(long.selectionCount == 100)
    }

    /// An order the list is in already is refused when another one has been asked for since.
    @Test
    internal func anUnwantedOrderIsStaleEvenWithoutSorting() {
        let model = Self.model([Self.file("b"), Self.file("a")])
        let prepared = PanelModel.prepare(model.basis, sort: model.sort)
        model.requestSort(ListOrder(key: .size))
        #expect(model.apply(prepared) == .stale)
    }

    /// A few saved names are looked up one by one in a long list.
    @Test
    internal func aFewSavedNamesAreLookedUp() {
        let model = Self.model((0..<4).map { Self.file("f\($0)") })
        model.setSelected(true, names: ["f1"])
        model.saveSelection()
        let other = URL(fileURLWithPath: "/many")
        model.show(Self.listing((0..<40).map { Self.file("f\($0)", in: other) }, at: other))
        model.restoreSelection()
        #expect(model.selectedNames == ["f1"])
    }

    /// A size that leaves the range of a number, or goes below zero, has the sums counted again.
    @Test
    internal func extremeSizesHaveTheSumsCountedAgain() {
        let model = Self.model([Self.folder("d"), Self.folder("e"), Self.file("f")])
        model.selectAll()
        _ = model.totals
        model.setComputedSizes([(name: "d", size: .max)])
        model.setComputedSizes([(name: "d", size: -5)])
        #expect(model.totals.totalBytes == -5 + 10 && model.totals.selectedBytes == 5)
        // A name written as no entry is: the entry that reads the same gets the size.
        let accented = Self.model([Self.folder("e\u{301}")])
        accented.setComputedSizes([(name: "\u{E9}", size: 3)])
        #expect(accented.listedItems[0].computedSize == 3)
    }

    /// A fresh reading counts as a change when any one thing the panel shows is different: the
    /// entries, the volume, being listed at all, or being complete.
    @Test
    internal func aReadingIsAChangeWhenAnyOneThingDiffers() {
        let items = [Self.file("a"), Self.file("b")]
        // Other entries, the cursor where it was.
        let entries = Self.model(items)
        #expect(entries.update(with: Self.listing(items + [Self.file("c")])) && entries.cursor == 0)
        // Another volume.
        let volume = Self.model(items)
        let other = Listing(
            directory: Self.directory,
            items: items,
            parent: URL(fileURLWithPath: "/"),
            root: URL(fileURLWithPath: "/"),
            volume: VolumeInfo(name: "Other", freeBytes: 5, totalBytes: 10)
        )
        #expect(volume.update(with: other))
        // Listed for the first time, the list as empty as it was.
        let fresh = PanelModel(directory: Self.directory)
        #expect(fresh.update(with: Self.listing([])))
        // Complete now, the entries as they were.
        let partial = PanelModel(directory: Self.directory)
        partial.show(Self.listing(items), complete: false)
        #expect(partial.update(with: Self.listing(items)) && partial.isComplete)
        // Nothing different.
        #expect(!partial.update(with: Self.listing(items)))
    }

    /// The history remembers where the panel was; the most recent wanted place is found.
    @Test
    internal func theLastVisitedPlaceIsFound() {
        let model = PanelModel(directory: URL(fileURLWithPath: "/a"))
        for path in ["/b", "/c"] {
            model.open(URL(fileURLWithPath: path), parent: URL(fileURLWithPath: "/"), root: URL(fileURLWithPath: "/"))
        }
        #expect(model.lastVisited { $0.path != "/b" }?.path == "/a")
        #expect(model.lastVisited { $0.path == "/b" }?.path == "/b")
        #expect(model.lastVisited { _ in false } == nil)
    }
}
