import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import AFMShell

/// Readings whose answer meets a panel that has moved on, or a list that has changed, while it
/// was on its way: remembered visits, readings taken over from the read-ahead, a folder that
/// fails while the one before was still arriving, an order changed under way.
///
/// The background is held where the test needs it, by a reading ahead the test ends (`Ahead`)
/// or a listing that holds (`ShellFixPanel.script`); a step that must come before an answer is
/// taken in the same turn of the main thread as the call that sends the work out.
@MainActor
@Suite(.serialized)
internal struct ShellFixPanelReadingTests {
    private let fixture = ShellFixPanel()
    private var panel: PanelViewController { fixture.panel }
    private var model: PanelModel { fixture.panel.model }

    /// A long fresh listing that comes before the remembered one was shown is entered from the
    /// background, in the tab's order.
    @Test
    internal func aLongFreshListingThatComesFirstIsEnteredFromTheBackground() async throws {
        await fixture.remember("/a")
        model.setSort(ListOrder(key: .name, descending: true))
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/a"), focus: nil, history: .record, completion: nil)
        let names = ShellFixPanel.names(PanelViewController.backgroundSortThreshold)
        ahead.end(.success(try fixture.fresh("/a", names)))
        #expect(await PanelWait.until { !panel.isLoading })
        #expect(model.directory.path == "/a" && model.items.count == names.count && model.isComplete)
        #expect(fixture.names.first == names.last && fixture.names.last == names.first)
    }

    /// A fresh listing that is still being put in the tab's order when the visit is overtaken is
    /// dropped: the tab stays where the newer visit took it.
    @Test
    internal func aFreshListingOfAnOvertakenVisitIsDropped() async throws {
        await fixture.remember("/a")
        model.setSort(ListOrder(key: .name, descending: true))
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/a"), focus: nil, history: .record, completion: nil)
        // The fresh listing is sorted in the background; meanwhile the panel goes elsewhere.
        ahead.end(.success(try fixture.fresh("/a", ["x.txt", "z.txt"])))
        panel.show(fixture.memory.url("/b"), focus: nil, history: .record, completion: nil)
        #expect(await PanelWait.until { !panel.isLoading })
        await PanelWait.drainMainQueue()
        #expect(model.directory.path == "/b" && fixture.names == ["y.txt"])
    }

    /// A long remembered listing that was being sorted when the order changed once more is sorted
    /// again and shown in the order the tab has by then.
    @Test
    internal func aLongRememberedListingFollowsAnOrderChangedWhileItWasSorted() async throws {
        let names = ShellFixPanel.names(PanelViewController.backgroundSortThreshold)
        for name in names {
            fixture.memory.addFile("/long/" + name)
        }
        await fixture.remember("/long")
        model.setSort(ListOrder(key: .name, descending: true))
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/long"), focus: nil, history: .record, completion: nil)
        // The remembered listing is put in the descending order in the background; the order
        // goes back to ascending before that is done.
        model.setSort(ListOrder(key: .name, descending: false))
        #expect(await PanelWait.until { model.directory.path == "/long" && model.items.count == names.count })
        #expect(fixture.names.first == names.first && fixture.names.last == names.last && panel.isLoading)
        ahead.end(.success(try fixture.fresh("/long", names)))
        #expect(await PanelWait.until { !panel.isLoading })
        #expect(fixture.names.first == names.first && model.isComplete)
    }

    /// A remembered visit whose fresh reading fails takes the tab back to the folder it was still
    /// reading, which is read again.
    @Test
    internal func aFailedVisitReadsAgainTheHalfReadFolderItLeft() async {
        await fixture.remember("/a")
        await fixture.enterHalfOfC()
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/a"), focus: nil, history: .record, completion: nil)
        #expect(fixture.names == ["x.txt"])
        ahead.end(.failure(CocoaError(.fileReadNoPermission)))
        #expect(model.directory.path == "/c" && fixture.names == ["z1.txt", "z2.txt"])
        #expect(await PanelWait.until { fixture.script.listingsBegun == 2 })
        fixture.script.open()
        #expect(await PanelWait.until { !panel.isLoading && model.isComplete })
        #expect(fixture.names == ["z1.txt", "z2.txt", "z3.txt"] && !fixture.interaction.log.isEmpty)
    }

    /// A reading that fails while the folder before was still arriving leaves the tab there, and
    /// that folder is read again.
    @Test
    internal func aFailedReadingReadsAgainTheHalfReadFolderItLeft() async {
        fixture.memory.addDirectory("/locked")
        fixture.memory.unreadable = ["/locked"]
        await fixture.show("/b")
        await fixture.enterHalfOfC()
        panel.show(fixture.memory.url("/locked"), focus: nil, history: .record, completion: nil)
        #expect(await PanelWait.until { fixture.script.listingsBegun == 2 })
        #expect(model.directory.path == "/c" && fixture.names == ["z1.txt", "z2.txt"])
        fixture.script.open()
        #expect(await PanelWait.until { !panel.isLoading && model.isComplete })
        #expect(fixture.names == ["z1.txt", "z2.txt", "z3.txt"])
        #expect(await PanelWait.until { !fixture.interaction.log.isEmpty })
    }

    /// A folder that is not remembered, taken over from the read-ahead, whose reading fails: the
    /// tab stays where it was and the user hears of it.
    @Test
    internal func aReadingTakenOverThatFailsLeavesTheTabWhereItWas() async {
        fixture.memory.addFile("/d/w.txt")
        await fixture.show("/b")
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/d"), focus: nil, history: .record, completion: nil)
        ahead.end(.failure(CocoaError(.fileReadNoPermission)))
        #expect(!panel.isLoading && model.directory.path == "/b" && fixture.names == ["y.txt"])
        #expect(await PanelWait.until { !fixture.interaction.log.isEmpty })
    }

    /// A reading taken over from the read-ahead that ends after the panel went elsewhere is
    /// dropped.
    @Test
    internal func aReadingTakenOverThatEndsAfterThePanelMovedOnIsDropped() async throws {
        fixture.memory.addFile("/d/w.txt")
        await fixture.remember("/d")
        let listing = try #require(fixture.kernel.listingCache.entry(for: fixture.memory.url("/d"), showHidden: false))
        fixture.kernel.listingCache.forget(fixture.memory.url("/d"))
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/d"), focus: nil, history: .record, completion: nil)
        await fixture.show("/a")
        #expect(ahead.left == 1)
        ahead.end(.success(PanelLoading.Whole(listing: listing.listing, focus: nil, order: listing.order)))
        #expect(model.directory.path == "/a" && fixture.names == ["x.txt"] && !panel.isLoading)
    }

    /// The order changed while a folder is held half-way: the rest arrives in the new order.
    @Test
    internal func anOrderChangedWhileAFolderIsHeldIsTheOrderItEndsIn() async {
        await fixture.show("/b")
        await fixture.enterHalfOfC()
        model.setSort(ListOrder(key: .name, descending: true))
        fixture.script.open()
        #expect(await PanelWait.until { !panel.isLoading && model.isComplete })
        #expect(fixture.names == ["z3.txt", "z2.txt", "z1.txt"] && model.sort.descending)
    }

    /// A remembered visit that fails while text typed into the quick filter of a long list had
    /// not reached the list yet brings the text back, and the list follows it.
    @Test
    internal func aFailedVisitBringsBackTextTypedThatHadNotReachedTheList() async {
        await fixture.remember("/a")
        for name in ShellFixPanel.names(PanelViewController.backgroundSortThreshold) {
            fixture.memory.addFile("/big/" + name)
        }
        await fixture.show("/big")
        panel.showQuickFilter()
        defer { panel.removeQuickFilter() }
        // Filtered in the background: the list does not have the filter yet when the visit begins.
        panel.quickFilterTyped("f00001")
        let id = ObjectIdentifier(model)
        #expect(panel.filterJobs[id] != nil)
        let ahead = fixture.readingAhead()
        panel.show(fixture.memory.url("/a"), focus: nil, history: .record, completion: nil)
        ahead.end(.failure(CocoaError(.fileReadNoPermission)))
        #expect(model.directory.path == "/big" && panel.quickFilterText == "f00001")
        #expect(await PanelWait.until { panel.filterJobs[id] == nil && !panel.isLoading })
        #expect(model.filter?.title == panel.quickFilters[id]?.title && model.items.count == 10)
    }
}
