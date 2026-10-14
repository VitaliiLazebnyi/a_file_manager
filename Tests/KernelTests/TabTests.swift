import AFMKernel
import Foundation
import TestSupport
import Testing

/// The tabs of a panel: new tabs, tabs read when shown, marks of their own, closing, and the
/// state saved and restored.
@MainActor
@Suite
internal struct TabTests {
    /// The file system that holds `/A` (with `one.txt`) and `/B`.
    private let memory = MemoryFileSystem()
    /// The registry the first tab was read through.
    private let fileSystems = FileSystemRegistry()
    /// The tabs, one of them showing `/A`.
    private let tabs: PanelTabs

    /// One tab showing `/A`, read.
    internal init() throws {
        memory.addFile("/A/one.txt")
        memory.addDirectory("/B")
        fileSystems.register(memory)
        let model = PanelModel(directory: memory.url("/A"))
        model.show(try PanelLoader.load(memory.url("/A"), showHidden: false, fileSystems: fileSystems).listing)
        tabs = PanelTabs(model)
    }

    /// A new tab is a copy of the active one (folder, order, entries) and becomes the active
    /// one, announced once.
    @Test
    internal func newTabCopiesTheActiveTab() {
        var changes = 0
        tabs.onChange = { changes += 1 }
        tabs.active.setSort(ListOrder(key: .size, descending: true))
        tabs.openTab()
        #expect(tabs.count == 2 && tabs.activeIndex == 1 && changes == 1)
        #expect(tabs.active.directory.isSameLocation(as: memory.url("/A")))
        #expect(tabs.active.sort == ListOrder(key: .size, descending: true))
        #expect(tabs.active.isListed && tabs.active.items.map(\.name) == ["one.txt"])
    }

    /// Checks that a tab opened in the background for another folder has its title and is
    /// not read yet.
    @Test
    internal func aTabForAnotherFolderIsReadWhenItIsShown() {
        let tab = tabs.openTab(showing: memory.url("/B"), activate: false)
        #expect(tabs.activeIndex == 0 && tabs.title(at: 1) == "B")
        #expect(!tab.isListed && tab.items.isEmpty)
    }

    /// Checks that a new tab starts without marks and the first keeps its own.
    @Test
    internal func tabsKeepTheirOwnSelection() {
        tabs.active.selectAll()
        tabs.openTab()
        #expect(tabs.active.selection.isEmpty)
        tabs.activateNeighbour(1)
        #expect(tabs.activeIndex == 0)
        #expect(tabs.active.selection == ["one.txt"])
    }

    /// The last tab cannot be closed; closing another moves the active index as needed.
    @Test
    internal func closingTabs() {
        #expect(!tabs.closeTab(at: 0))
        tabs.openTab()
        tabs.openTab()
        #expect(tabs.closeTab(at: 2))
        #expect(tabs.activeIndex == 1)
        #expect(tabs.closeTab(at: 0))
        #expect(tabs.activeIndex == 0)
        #expect(tabs.count == 1)
    }

    /// The saved state brings back the tabs, the active one, its order and hidden files,
    /// unread; without a state there is one tab at the fallback.
    @Test
    internal func stateRoundTrip() {
        tabs.openTab(showing: memory.url("/B"))
        tabs.active.setSort(ListOrder(key: .date, descending: true))
        tabs.active.setShowHidden(true)
        let settings = MemorySettings()
        settings.set(tabs.state, forKey: "left.tabs")
        let restored = PanelTabs(
            restoring: settings.value(PanelTabs.State.self, forKey: "left.tabs"),
            fallback: memory.url("/")
        )
        #expect(restored.count == 2 && restored.activeIndex == 1)
        #expect(restored.active.directory.isSameLocation(as: memory.url("/B")))
        #expect(restored.active.sort == ListOrder(key: .date, descending: true))
        #expect(restored.active.showHidden && !restored.active.isListed)
        let fallback = PanelTabs(restoring: nil, fallback: memory.url("/A"))
        #expect(fallback.active.directory.isSameLocation(as: memory.url("/A")))
    }
}
