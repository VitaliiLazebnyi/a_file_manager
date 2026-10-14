import AFMContracts
import AFMKernel
import Foundation
import Testing

/// Settings of the kernel written by earlier versions: the button bar's layout and the panels'
/// tabs load as they were meant, and are written again in the same shape.
@MainActor
@Suite
internal struct KernelSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The button bar as commit 16d647d (2026-10-14) wrote it, in one line.
        ///
        /// `toolbar.layout` before the bar could have more than one line: command names in
        /// order, an empty text for a separator. This one is Copy, a separator, Delete.
        internal static let toolbarOneLine = #"["cm_Copy","","cm_Delete"]"#

        /// The button bar as commit eaa5ea7 (2026-10-14) and later write it, with lines.
        ///
        /// The same as before, and `afm_ButtonBarLineBreak` where a new line starts. This one
        /// is Copy and Move, then a second line with Delete.
        internal static let toolbarLines = #"["cm_Copy","cm_RenMov","afm_ButtonBarLineBreak","cm_Delete"]"#

        /// The tabs of a panel as the versions before git wrote them, without titles.
        ///
        /// `left.tabs` when a tab had no title and no lock. Two tabs, the second one active;
        /// the first sorted by date, newest first, with hidden files shown.
        internal static let tabsWithoutTitles = #"""
            {"tabs":[{"location":"file:\/\/\/Users\/me\/Projects\/","sortKey":3,"descending":true,"showHidden":true},\#
            {"location":"file:\/\/\/tmp\/","sortKey":0,"descending":false,"showHidden":false}],"active":1}
            """#

        /// The tabs of a panel as commit 16d647d (2026-10-14) wrote them, with titles.
        ///
        /// A tab may have a title of its own and a lock; `locked` is written only when it is
        /// on, and `title` only when there is one. A locked tab named "Work" sorted by size,
        /// and a tab on a server.
        internal static let tabsWithTitles = #"""
            {"tabs":[{"location":"file:\/\/\/Users\/me\/Projects\/","sortKey":2,"descending":false,\#
            "showHidden":false,"title":"Work","locked":true},{"location":"sftp:\/\/me@files.example.com\/home\/me\/",\#
            "sortKey":1,"descending":true,"showHidden":true,"title":"Server"}],"active":0}
            """#
    }

    private static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    /// The tabs that are stored under `key` after loading the fixture and saving it again.
    private static func resaved(_ fixture: String) -> Data? {
        let settings = MemorySettings()
        SettingsJSON.store(fixture, forKey: "left.tabs", in: settings)
        let tabs = PanelTabs(restoring: settings.value(PanelTabs.State.self, forKey: "left.tabs"), fallback: home)
        settings.set(tabs.state, forKey: "left.tabs")
        return settings.data(forKey: "left.tabs")
    }

    /// A layout written before the bar had lines is one line: no line break is made up.
    @Test
    internal func aButtonBarOfOneLineLoads() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.toolbarOneLine, forKey: ToolbarRegistry.settingsKey, in: settings)
        let toolbar = ToolbarRegistry()
        toolbar.setSymbol("doc.on.doc", for: .copy)
        let layout = toolbar.layout(from: settings)
        #expect(toolbar.hasUserLayout(in: settings))
        #expect(layout.map { $0?.command } == [.copy, nil, .delete])
        #expect(!layout.contains { $0?.command == ToolbarRegistry.lineBreak })
        // A command whose plugin gave no picture gets the placeholder.
        #expect(layout.first??.symbol == "doc.on.doc" && layout.last??.symbol == "square.dashed")
    }

    /// A layout with lines keeps its line break where it was.
    @Test
    internal func aButtonBarWithLinesLoads() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.toolbarLines, forKey: ToolbarRegistry.settingsKey, in: settings)
        let layout = ToolbarRegistry().layout(from: settings)
        #expect(layout.map { $0?.command } == [.copy, .renameMove, ToolbarRegistry.lineBreak, .delete])
    }

    /// Both layouts are stored again as they were read.
    @Test(arguments: [Fixture.toolbarOneLine, Fixture.toolbarLines])
    internal func aButtonBarIsSavedInTheSameShape(_ fixture: String) {
        let settings = MemorySettings()
        SettingsJSON.store(fixture, forKey: ToolbarRegistry.settingsKey, in: settings)
        let toolbar = ToolbarRegistry()
        toolbar.setLayout(toolbar.layout(from: settings).map { $0?.command }, in: settings)
        #expect(SettingsJSON.matches(settings.data(forKey: ToolbarRegistry.settingsKey), fixture))
    }

    /// Tabs without titles and locks come back unlocked, named after their folders.
    @Test
    internal func tabsWithoutTitlesLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.tabsWithoutTitles, forKey: "left.tabs", in: settings)
        let state = try #require(settings.value(PanelTabs.State.self, forKey: "left.tabs"))
        let tabs = PanelTabs(restoring: state, fallback: Self.home)
        #expect(tabs.count == 2 && tabs.activeIndex == 1)
        let first = tabs.tabs[0]
        #expect(first.directory.path == "/Users/me/Projects" && first.sort.key == .date && first.sort.descending)
        #expect(first.showHidden && first.customTitle == nil && !first.isLocked)
        let second = tabs.tabs[1]
        #expect(second.directory.path == "/tmp" && second.sort.key == .name && !second.sort.descending)
        #expect(!second.showHidden && !second.isLocked)
        #expect(tabs.title(at: 0) == "Projects" && tabs.title(at: 1) == "tmp")
    }

    /// Tabs with a title and a lock keep both; a tab on a server keeps its address.
    @Test
    internal func tabsWithTitlesLoad() throws {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.tabsWithTitles, forKey: "left.tabs", in: settings)
        let state = try #require(settings.value(PanelTabs.State.self, forKey: "left.tabs"))
        let tabs = PanelTabs(restoring: state, fallback: Self.home)
        #expect(tabs.count == 2 && tabs.activeIndex == 0)
        let first = tabs.tabs[0]
        #expect(first.customTitle == "Work" && first.isLocked && first.sort.key == .size && !first.showHidden)
        let second = tabs.tabs[1]
        #expect(second.directory.absoluteString == "sftp://me@files.example.com/home/me/")
        #expect(second.customTitle == "Server" && !second.isLocked && second.sort.key == .ext)
        #expect(second.sort.descending && second.showHidden)
        // A locked tab is marked with a star.
        #expect(tabs.title(at: 0) == "*Work" && tabs.title(at: 1) == "Server")
    }

    /// Both kinds of tabs are stored again as they were read.
    @Test(arguments: [Fixture.tabsWithoutTitles, Fixture.tabsWithTitles])
    internal func tabsAreSavedInTheSameShape(_ fixture: String) {
        #expect(SettingsJSON.matches(Self.resaved(fixture), fixture))
    }
}
