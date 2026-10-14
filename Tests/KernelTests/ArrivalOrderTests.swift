import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Whether a panel's list is still in the order its files came in (review 2, second pass, K047).
@MainActor
@Suite
internal struct ArrivalOrderTests {
    private static let folder = URL(fileURLWithPath: "/review2/second")
    private static let came = ["m.txt", "a.txt", "z.txt"].map { Fixture.file($0, in: folder) }

    /// Another key loses the order of arrival, choosing Unsorted again does not bring it back,
    /// and reading the directory again does; the model says which each time.
    @Test
    internal func theModelSaysWhetherItsListIsStillInTheOrderItCameIn() {
        let unsorted = ListOrder(key: .unsorted)
        let model = Fixture.panel(Self.came, at: Self.folder, sort: unsorted)
        #expect(model.isInArrivalOrder)
        #expect(model.items.map(\.name) == ["m.txt", "a.txt", "z.txt"])
        // Another key puts the files in its order, and the order they came in is gone…
        model.setSort(ListOrder(key: .name))
        #expect(!model.isInArrivalOrder)
        #expect(model.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // …so that choosing Unsorted again leaves them as they are, and the model says so:
        model.setSort(unsorted)
        #expect(!model.isInArrivalOrder)
        #expect(model.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // whoever wants the old order reads the directory again, which brings it back.
        model.update(with: Fixture.listing(Self.came, at: Self.folder))
        #expect(model.isInArrivalOrder)
        #expect(model.items.map(\.name) == ["m.txt", "a.txt", "z.txt"])
    }

    /// The answer is the same by the background route, through snapshots, copies and new
    /// folders, and for a directory that arrives in pieces while the order is Unsorted.
    @Test
    internal func theOrderOfArrivalIsFollowedThroughEveryWayAListChanges() throws {
        let (unsorted, byName) = (ListOrder(key: .unsorted), ListOrder(key: .name))
        // Shown sorted by a key: never in the order of arrival.
        #expect(!Fixture.panel(Self.came, at: Self.folder, sort: byName).isInArrivalOrder)
        // The background route says the same as the direct one.
        let model = Fixture.panel(Self.came, at: Self.folder, sort: unsorted)
        let basis = model.basis
        let prepared = try #require(OtherThread.result { PanelModel.prepare(basis, sort: byName) })
        #expect(model.apply(prepared) == .changed)
        #expect(!model.isInArrivalOrder)
        // A snapshot remembers it, a copy takes it along, and a new folder starts afresh.
        let fresh = Fixture.panel(Self.came, at: Self.folder, sort: unsorted)
        let before = fresh.snapshot()
        fresh.setSort(byName)
        #expect(!fresh.isInArrivalOrder)
        #expect(!fresh.duplicate().isInArrivalOrder)
        fresh.open(URL(fileURLWithPath: "/review2/other"), parent: Self.folder, root: URL(fileURLWithPath: "/"))
        #expect(fresh.isInArrivalOrder)
        fresh.restore(before)
        // The panel's order is by name now, so the restored list was sorted, too.
        #expect(!fresh.isInArrivalOrder)
        #expect(fresh.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // A directory that arrives in pieces while the order is Unsorted stays as it came.
        let arriving = PanelModel(directory: Self.folder, sort: unsorted)
        arriving.show(Fixture.listing([Self.came[0]], at: Self.folder), complete: false)
        arriving.extend(to: Self.came, sortedBy: unsorted)
        #expect(arriving.isInArrivalOrder)
        #expect(arriving.items.map(\.name) == ["m.txt", "a.txt", "z.txt"])
    }
}
