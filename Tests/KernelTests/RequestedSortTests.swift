import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// An order asked for while the directory keeps arriving (review 2, second pass): it comes with
/// the next list that arrives, and a sort for an order no longer wanted is refused.
@MainActor
@Suite
internal struct RequestedSortTests {
    private static let folder = URL(fileURLWithPath: "/review2/second")
    private static let byName = ListOrder(key: .name)
    private static let bySize = ListOrder(key: .size)

    /// Asking costs nothing and shows nothing; the next reading, prepared or direct, brings the
    /// wanted order with it, and a sort prepared for it meanwhile is stale.
    @Test
    internal func anOrderThatWasAskedForComesWithTheNextListThatArrives() throws {
        let came = [file("m.txt", size: 2), file("a.txt", size: 3), file("z.txt", size: 1)]
        let model = Fixture.panel(came, at: Self.folder, sort: Self.byName)
        var announced = 0
        model.onChange = { _ in announced += 1 }
        let version = model.listVersion
        // Asking costs nothing and shows nothing.
        model.requestSort(Self.bySize)
        #expect(model.requestedSort == Self.bySize)
        #expect(model.wantedSort == Self.bySize)
        #expect(model.sort == Self.byName)
        #expect(announced == 0)
        #expect(model.listVersion == version)
        #expect(model.items.map(\.name) == ["a.txt", "m.txt", "z.txt"])
        // A sort for the wanted order is made in the background; meanwhile the directory
        // changes, so the sort is stale…
        let (basis, wanted) = (model.basis, Self.bySize)
        let sorted = try #require(OtherThread.result { PanelModel.prepare(basis, sort: wanted) })
        let fresh = came + [file("k.txt", size: 9)]
        let listing = Fixture.listing(fresh, at: Self.folder)
        let update = try #require(OtherThread.result { PanelModel.prepare(basis, update: listing) })
        #expect(model.apply(update) == .changed)
        // …but the reading that arrived brought the order with it: nothing is left to race.
        #expect(model.sort == Self.bySize)
        #expect(model.requestedSort == nil)
        #expect(model.wantedSort == Self.bySize)
        #expect(model.items.map(\.name) == Sorter.sort(fresh, by: Self.bySize).map(\.name))
        #expect(model.apply(sorted) == .stale)
    }

    /// The direct calls bring the asked-for order too: a fresh reading, a list that grows
    /// (prepared or direct), and another folder shown.
    @Test
    internal func theCallsThatDoEverythingAtOnceBringTheOrderToo() throws {
        let came = [file("m.txt", size: 2), file("a.txt", size: 3), file("z.txt", size: 1)]
        let fresh = came + [file("k.txt", size: 9)]
        let model = Fixture.panel(fresh, at: Self.folder, sort: Self.bySize)
        model.requestSort(Self.byName)
        model.update(with: Fixture.listing(fresh + [file("b.txt", size: 1)], at: Self.folder))
        #expect(model.sort == Self.byName)
        #expect(model.requestedSort == nil)
        #expect(model.items.map(\.name) == ["a.txt", "b.txt", "k.txt", "m.txt", "z.txt"])
        model.requestSort(Self.bySize)
        model.extend(to: Sorter.sort(fresh, by: Self.byName), sortedBy: Self.byName)
        #expect(model.sort == Self.bySize)
        #expect(model.requestedSort == nil)
        #expect(model.items.map(\.name) == Sorter.sort(fresh, by: Self.bySize).map(\.name))
        model.requestSort(Self.byName)
        let (basis, wanted) = (model.basis, Self.byName)
        let grown = try #require(
            OtherThread.result {
                PanelModel.prepare(basis, extendingTo: Sorter.sort(fresh, by: wanted), sortedBy: wanted)
            }
        )
        #expect(model.apply(grown) == .changed)
        #expect(model.sort == Self.byName)
        #expect(model.requestedSort == nil)
        // Another folder shown while an order is wanted is shown in it.
        model.requestSort(Self.bySize)
        model.show(Fixture.listing(came, at: Self.folder))
        #expect(model.sort == Self.bySize)
        #expect(model.requestedSort == nil)
        #expect(model.items.map(\.name) == Sorter.sort(came, by: Self.bySize).map(\.name))
    }

    /// Of two orders chosen one after the other, the sort for the first is refused; asking for
    /// the present order asks for nothing; a snapshot taken before a request comes back in the
    /// wanted order.
    @Test
    internal func aSortThatIsNoLongerTheOneAskedForIsRefused() {
        let came = (0..<40).map { file("f\($0).txt", size: Int64(40 - $0)) }
        let byDate = ListOrder(key: .date)
        let model = Fixture.panel(came, at: Self.folder, sort: Self.byName)
        // The user chooses one order and, before it is ready, another.
        model.requestSort(Self.bySize)
        let first = PanelModel.prepare(model.basis, sort: Self.bySize)
        model.requestSort(byDate)
        let second = PanelModel.prepare(model.basis, sort: byDate)
        #expect(model.apply(first) == .stale)
        #expect(model.sort == Self.byName)
        #expect(model.apply(second) == .changed)
        #expect(model.sort == byDate)
        #expect(model.requestedSort == nil)
        // Asking for the order the list is in asks for nothing; so does sorting directly.
        model.requestSort(byDate)
        #expect(model.requestedSort == nil)
        model.requestSort(Self.bySize)
        model.setSort(Self.byName)
        #expect(model.requestedSort == nil)
        #expect(model.sort == Self.byName)
        // A caller that never asks is served as before.
        #expect(model.apply(PanelModel.prepare(model.basis, sort: Self.bySize)) == .changed)
        #expect(model.sort == Self.bySize)
        // Preparing the order the list is in changes nothing in it.
        let before = model.items
        #expect(model.apply(PanelModel.prepare(model.basis, sort: Self.bySize)) == .changed)
        #expect(model.items == before)
        // A snapshot taken before a request: going back puts the list into the wanted order.
        let snapshot = model.snapshot()
        model.open(URL(fileURLWithPath: "/review2/other"), parent: Self.folder, root: URL(fileURLWithPath: "/"))
        model.requestSort(Self.byName)
        model.restore(snapshot)
        #expect(model.sort == Self.byName)
        #expect(model.requestedSort == nil)
        #expect(model.items.map(\.name) == Sorter.sort(came, by: Self.byName).map(\.name))
    }

    private func file(_ name: String, size: Int64) -> FileItem { Fixture.file(name, in: Self.folder, size: size) }
}
