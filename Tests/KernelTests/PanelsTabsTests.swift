import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Folder tabs, what is kept of them between sessions, and the calls every panel answers alike.
@MainActor
@Suite
internal struct PanelsTabsTests {
    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private static func tabs(_ paths: [String]) -> PanelTabs {
        let tabs = PanelTabs(PanelModel(directory: url(paths[0])))
        for path in paths.dropFirst() { tabs.openTab(showing: url(path), activate: false) }
        return tabs
    }

    /// Moving a tab keeps the active tab the active one, wherever the two end up.
    @Test
    internal func movingATabKeepsTheActiveOne() {
        let tabs = Self.tabs(["/a", "/b", "/c", "/d"])
        tabs.activate(1)
        tabs.activate(1)
        tabs.moveTab(from: 1, to: 3)
        #expect(tabs.activeIndex == 3 && tabs.active.directory.path == "/b")
        tabs.moveTab(from: 0, to: 3)
        #expect(tabs.activeIndex == 2 && tabs.active.directory.path == "/b")
        tabs.moveTab(from: 3, to: 0)
        #expect(tabs.activeIndex == 3 && tabs.active.directory.path == "/b")
        tabs.moveTab(from: 0, to: 1)
        #expect(tabs.activeIndex == 3)
        tabs.moveTab(from: 0, to: 0)
        tabs.moveTab(from: 9, to: 0)
        #expect(tabs.tabs.map(\.directory.path) == ["/c", "/a", "/d", "/b"])
    }

    /// A tab inserted after the active one, before it, or at the end.
    @Test
    internal func insertedTabsGoWhereTheyAreAsked() {
        let tabs = Self.tabs(["/a", "/b"])
        tabs.insertTab(showing: Self.url("/x"))
        #expect(tabs.activeIndex == 1 && tabs.active.directory.path == "/x")
        tabs.insertTab(showing: Self.url("/y"), at: 0, activate: false)
        #expect(tabs.activeIndex == 2 && tabs.active.directory.path == "/x")
        tabs.insertTab(showing: Self.url("/z"), at: 99, activate: false)
        #expect(tabs.tabs.map(\.directory.path) == ["/y", "/a", "/x", "/b", "/z"] && tabs.activeIndex == 2)
    }

    /// Titles: the folder's name, the user's, with a star on a locked tab; the root is `/`.
    @Test
    internal func tabTitles() throws {
        let tabs = Self.tabs(["/", "/work"])
        tabs.tabs[1].customTitle = "Mine"
        tabs.tabs[1].isLocked = true
        tabs.tabs[0].isLocked = true
        #expect(tabs.title(at: 0) == "*/" && tabs.title(at: 1) == "*Mine")
        tabs.tabs[1].isLocked = false
        #expect(tabs.title(at: 1) == "Mine")
        // A server's top has no name of its own.
        let server = try #require(URL(string: "smb://server"))
        tabs.insertTab(showing: server, at: 2, activate: false)
        #expect(tabs.title(at: 2) == "/")
    }

    /// The state of a session goes out and comes back, a tab whose location is no URL left out;
    /// `locked` is stored for a locked tab only, as it always was.
    @Test
    internal func stateComesBackAsItWent() throws {
        let tabs = Self.tabs(["/a", "/b"])
        tabs.tabs[1].isLocked = true
        tabs.tabs[1].customTitle = "B"
        var state = tabs.state
        let data = try JSONEncoder().encode(state)
        let text = String(bytes: data, encoding: .utf8) ?? ""
        #expect(text.components(separatedBy: "locked").count == 2)
        #expect(try JSONDecoder().decode(PanelTabs.State.self, from: data) == state)
        state.tabs.insert(PanelTabState(location: Self.url("/c")), at: 0)
        state.tabs[0].location = ""
        state.tabs[1].sortKey = 99
        let restored = PanelTabs(restoring: state, fallback: Self.url("/f"))
        #expect(restored.tabs.map(\.directory.path) == ["/a", "/b"] && restored.tabs[1].isLocked)
        #expect(restored.tabs[0].sort.key == .name)
        let old = Data(#"{"location":"file:///o","sortKey":3,"descending":true,"showHidden":false}"#.utf8)
        let tab = try JSONDecoder().decode(PanelTabState.self, from: old)
        #expect(!tab.locked && tab.title == nil && tab.sortKey == 3)
    }

    /// The calls every panel answers by way of the ones it implements.
    @Test
    internal func panelsShowAndReloadThroughTheirOwnCalls() {
        let (left, right) = (PanelsRecordingPanel(Self.url("/l")), PanelsRecordingPanel(Self.url("/r")))
        left.show(Self.url("/l/x"))
        left.reload(focus: "f")
        #expect(
            left.shown.map(\.0.path) == ["/l/x"] && left.reloads.map(\.0) == ["f"] && left.model === left.tabs.active
        )
        let panels = PanelsRecordingPanels(left, right)
        panels.refresh([Self.url("/l")], focus: Self.url("/l/new.txt"))
        panels.refresh([Self.url("/r"), Self.url("/elsewhere")])
        #expect(left.reloads.last?.0 == "new.txt" && right.reloads.count == 1 && right.reloads[0].0 == nil)
        #expect(panels.all.count == 2)
    }
}
