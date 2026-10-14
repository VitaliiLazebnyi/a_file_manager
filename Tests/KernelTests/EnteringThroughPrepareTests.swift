import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Entering a folder through `prepare` and `apply`, the background route of `show` (review 2,
/// integration: shell-p2 request 2).
@MainActor
@Suite
internal struct EnteringThroughPrepareTests {
    /// The folder the panel shows to begin with.
    nonisolated private static let home = URL(fileURLWithPath: "/review2/integration/home")
    /// The folder it enters.
    nonisolated private static let other = URL(fileURLWithPath: "/review2/integration/other")

    /// What `other` holds, in the order the file system gave it.
    nonisolated private static var arrival: [FileItem] {
        [
            Fixture.file("zeta.txt", in: other, size: 3), Fixture.folder("Docs", in: other),
            Fixture.file("alpha.log", in: other, size: 5),
            Fixture.file("mid.txt", in: other, size: 7)
        ]
    }

    /// The listing of `other` with `items`.
    nonisolated private static func otherListing(_ items: [FileItem]) -> Listing {
        Fixture.listing(items, at: other)
    }

    /// The panel `prepare` is tried on: `home` with two files, sorted by name.
    private func model() -> PanelModel {
        let folder = Self.home
        return Fixture.panel(
            [Fixture.file("b.txt", in: folder), Fixture.file("a.txt", in: folder)],
            at: folder,
            sort: ListOrder(key: .name)
        )
    }

    /// Prepared on another thread and applied, the folder is entered exactly as `show` enters
    /// it: entries, cursor, state, totals and history.
    @Test
    internal func aFolderEnteredThroughPrepareIsTheFolderShowWouldHaveEntered() throws {
        let direct = model()
        direct.show(Self.otherListing(Self.arrival), focus: "mid.txt")
        let prepared = model()
        let basis = prepared.basis
        let change = try #require(
            OtherThread.result {
                PanelModel.prepare(basis, show: Self.otherListing(Self.arrival), focus: "mid.txt")
            }
        )
        #expect(prepared.apply(change) == .changed)
        #expect(prepared.directory == direct.directory && prepared.items.map(\.name) == direct.items.map(\.name))
        #expect(prepared.items.map(\.name) == ["Docs", "alpha.log", "mid.txt", "zeta.txt"])
        #expect(prepared.cursorItem?.name == "mid.txt" && prepared.cursor == direct.cursor)
        #expect(prepared.isComplete && prepared.isListed)
        #expect(!prepared.isRefreshing && !prepared.hasSelection)
        #expect(prepared.totals.totalFiles == direct.totals.totalFiles && prepared.totals.totalBytes == 15)
        // The visit is in the history, as after `show`.
        #expect(prepared.backLocation == direct.backLocation && prepared.backLocation?.path == Self.home.path)
    }

    /// The panel's filter, an order asked for and not yet applied, and a remembered listing
    /// are all taken as `show` takes them.
    @Test
    internal func theFilterTheOrderThatWasAskedForAndARememberedListingAreTakenAsShowTakesThem() throws {
        let model = model()
        model.setFilter(.mask("*.txt"))
        // An order the user asked for and the list is not in yet.
        model.requestSort(ListOrder(key: .size, descending: true))
        let basis = model.basis
        let change = try #require(
            OtherThread.result {
                PanelModel.prepare(basis, show: Self.otherListing(Self.arrival), history: .keep, remembered: true)
            }
        )
        #expect(model.apply(change) == .changed)
        // Filtered (folders stay), in the order that was asked for, which is the panel's now.
        #expect(model.items.map(\.name) == ["Docs", "mid.txt", "zeta.txt"])
        #expect(model.sort == ListOrder(key: .size, descending: true) && model.requestedSort == nil)
        // A remembered listing: usable, and not complete until the fresh reading has come.
        #expect(model.isRefreshing && !model.isComplete && model.isListed)
        #expect(model.backLocation == nil)
        let fresh = Self.arrival + [Fixture.file("new.txt", in: Self.other, size: 9)]
        #expect(model.update(with: Self.otherListing(fresh)))
        #expect(model.isComplete && !model.isRefreshing)
        #expect(model.items.map(\.name) == ["Docs", "new.txt", "mid.txt", "zeta.txt"])
    }

    /// A change prepared before the filter changed is refused, and one prepared afterwards is taken.
    @Test
    internal func aPanelThatChangedMeanwhileRefusesTheEnteringAndTakesTheNextOne() {
        let model = model()
        let stale = PanelModel.prepare(model.basis, show: Self.otherListing(Self.arrival))
        // Another filter since the basis was taken: what was prepared shows the wrong entries.
        model.setFilter(.mask("*.log"))
        #expect(model.apply(stale) == .stale && model.directory.path == Self.home.path)
        #expect(model.apply(PanelModel.prepare(model.basis, show: Self.otherListing(Self.arrival))) == .changed)
        #expect(model.items.map(\.name) == ["Docs", "alpha.log"])
    }

    /// A list of thirty thousand entries is entered with its cursor, its index of names and its totals.
    @Test
    internal func aLongListIsEnteredWithItsIndexOfNamesMadeInTheBackground() throws {
        let model = model()
        let many = (0..<30_000).map { Fixture.file("file-\($0).dat", in: Self.other, size: Int64($0 % 11)) }
        let basis = model.basis
        let change = try #require(
            OtherThread.result {
                PanelModel.prepare(basis, show: Self.otherListing(many), focus: "file-29999.dat")
            }
        )
        #expect(model.apply(change) == .changed)
        #expect(model.items.count == 30_000 && model.cursorItem?.name == "file-29999.dat")
        #expect(model.row(ofName: "file-12345.dat").flatMap(model.item(atRow:))?.name == "file-12345.dat")
        #expect(model.totals.totalFiles == 30_000)
    }
}
