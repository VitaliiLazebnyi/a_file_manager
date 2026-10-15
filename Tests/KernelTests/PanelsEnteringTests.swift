import Foundation
import Testing

@testable import AFMKernel

/// Entering a directory before it is read, and going back to a snapshot: nothing that belonged
/// to the lists that were shown survives into the ones that take their place.
@MainActor
@Suite
internal struct PanelsEnteringTests {
    private static let first = URL(fileURLWithPath: "/first")
    private static let second = URL(fileURLWithPath: "/second")

    private static func listing(_ names: [String], at directory: URL) -> Listing {
        let items = names.map { name in
            FileItem(url: directory.appendingPathComponent(name), name: name, stat: .init(size: 3))
        }
        return Listing(
            directory: directory,
            items: items,
            parent: URL(fileURLWithPath: "/"),
            root: URL(fileURLWithPath: "/")
        )
    }

    private static func model() -> PanelModel {
        let model = PanelModel(directory: first)
        model.show(listing(["a", "b", "c"], at: first))
        return model
    }

    /// Marks saved in one list are put back by name in the list a snapshot brings back.
    @Test
    internal func savedMarksGoByNameIntoARestoredList() {
        let model = Self.model()
        let snapshot = model.snapshot()
        model.show(Self.listing(["x", "y", "z", "w"], at: Self.second))
        model.setSelected(true, names: ["y"])
        model.saveSelection()
        model.restore(snapshot)
        model.restoreSelection()
        #expect(!model.hasSelection)
    }

    /// Marks saved before a directory is entered are put back by name once it is read.
    @Test
    internal func savedMarksGoByNameIntoAnEnteredDirectory() {
        let model = Self.model()
        model.setSelected(true, names: ["b"])
        model.saveSelection()
        model.open(Self.second, parent: URL(fileURLWithPath: "/"), root: URL(fileURLWithPath: "/"))
        model.show(Self.listing(["x", "b", "y"], at: Self.second))
        model.restoreSelection()
        #expect(model.selectedNames == ["b"])
    }

    /// The figures of the status line are those of the list now shown.
    @Test
    internal func theFiguresAreThoseOfTheListShown() {
        let model = Self.model()
        let snapshot = model.snapshot()
        model.show(Self.listing(["x", "y", "z", "w"], at: Self.second))
        model.selectAll()
        #expect(model.totals.totalFiles == 4 && model.totals.selectedFiles == 4)
        model.restore(snapshot)
        #expect(model.totals.totalFiles == 3 && model.totals.selectedFiles == 0)
        model.selectAll()
        #expect(model.totals.selectedFiles == 3)
        model.open(Self.second, parent: URL(fileURLWithPath: "/"), root: URL(fileURLWithPath: "/"))
        #expect(model.totals.totalFiles == 0 && model.totals.selectedFiles == 0)
    }

    /// What was worked out for the lists shown before is stale for the ones that replace them.
    @Test
    internal func changesPreparedBeforeAreStaleAfter() {
        let model = Self.model()
        let snapshot = model.snapshot()
        model.show(Self.listing(["x", "y"], at: Self.second))
        let beforeRestore = PanelModel.prepare(model.basis, sort: ListOrder(key: .name, descending: true))
        let version = model.listVersion
        model.restore(snapshot)
        #expect(model.listVersion != version && model.apply(beforeRestore) == .stale)
        let beforeOpen = PanelModel.prepare(model.basis, sort: ListOrder(key: .name, descending: true))
        model.open(Self.second, parent: URL(fileURLWithPath: "/"), root: URL(fileURLWithPath: "/"))
        #expect(model.apply(beforeOpen) == .stale)
    }

    /// A sum that reached the largest number stays there when a folder's size goes down: it is
    /// counted again rather than taken for exact.
    @Test
    internal func aSaturatedSumIsCountedAgain() {
        let directory = URL(fileURLWithPath: "/huge")
        let items = [
            FileItem(url: directory.appendingPathComponent("big"), name: "big", stat: .init(size: .max)),
            FileItem(url: directory.appendingPathComponent("small"), name: "small", stat: .init(size: 10)),
            FileItem(url: directory.appendingPathComponent("dir"), name: "dir", kind: .directory)
        ]
        let model = PanelModel(directory: directory)
        model.show(Listing(directory: directory, items: items, parent: nil, root: directory))
        model.setComputedSizes([(name: "dir", size: 20)])
        #expect(model.totals.totalBytes == .max)
        model.setComputedSizes([(name: "dir", size: 5)])
        #expect(model.totals.totalBytes == .max)
    }
}
