import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The directory hotlist and the directory histories written by earlier versions load as they
/// were meant, and are written again in the same shape.
@MainActor
@Suite
internal struct PlacesSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The hotlist as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `places.hotlist`: every entry with all its fields. An entry "Projects" (P is its
        /// accelerator) that also shows the backup in the other panel, a separator, and a
        /// submenu "Servers" with one entry hidden by the `?` mark, which is switched on.
        internal static let hotlist = #"""
            {"entries":[{"kind":"item","title":"&Projects","command":"cd \/Users\/me\/Projects",\#
            "target":"\/Volumes\/Backup\/Projects","children":[]},\#
            {"kind":"separator","title":"-","command":"","target":"","children":[]},\#
            {"kind":"submenu","title":"Servers","command":"","target":"","children":[\#
            {"kind":"item","title":"?Old share","command":"cd smb:\/\/nas\/old","target":"","children":[]}]}],\#
            "hideCharacter":"?","hidesMarked":true}
            """#

        /// A hotlist with fields missing and fields this version does not know.
        ///
        /// What a version with fewer or more fields would write: an entry without `target` and
        /// `children`, one without `kind` (an item), a field `color` nobody reads, and no
        /// `hideCharacter` or `hidesMarked` (`?` and off).
        internal static let hotlistOtherFields = #"""
            {"entries":[{"kind":"item","title":"Home","command":"cd ~","color":"red"},\#
            {"title":"Downloads","command":"cd ~\/Downloads"}],"sortedBy":"title"}
            """#

        /// The left panel's history as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `places.history.left`: the folders in the order they were visited, oldest first.
        /// Downloads was only passed through, so it is hidden when the list is thinned; the
        /// server is where the panel is now.
        internal static let historyLeft = #"""
            {"visits":[{"location":"file:\/\/\/Users\/me\/","isVisible":true},\#
            {"location":"file:\/\/\/Users\/me\/Downloads\/","isVisible":false},\#
            {"location":"ftp:\/\/files.example.com\/pub\/","isVisible":true}]}
            """#

        /// A history with a visit that lacks `isVisible` and one with a field nobody reads.
        ///
        /// The first visit counts as passed through.
        internal static let historyOtherFields = #"""
            {"visits":[{"location":"file:\/\/\/a\/"},{"location":"file:\/\/\/b\/","isVisible":true,"pinned":true}]}
            """#

        /// The frequently used folders as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `places.history.frequent`: how often each folder was visited, in either panel.
        internal static let frequent = #"""
            {"counts":{"file:\/\/\/Users\/me\/":12,"file:\/\/\/Users\/me\/Downloads\/":3}}
            """#
    }

    /// A test bench with the Places plugin on the given settings; trees are not kept on disk.
    private static func bench(_ settings: any SettingsStore) -> (bench: TestBench, plugin: PlacesPlugin) {
        let memory = MemoryFileSystem()
        let plugin = PlacesPlugin(keepsTreesOnDisk: false, favorites: [])
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.addDirectory("/A"),
            right: memory.addDirectory("/B"),
            settings: settings
        )
        return (bench, plugin)
    }

    /// The hotlist loads with its entries, the submenu, the target and the hiding mark.
    @Test
    internal func theHotlistLoads() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.hotlist, forKey: "places.hotlist", in: settings)
        let (bench, plugin) = Self.bench(settings)
        let hotlist = plugin.hotlist(in: bench.kernel)
        #expect(hotlist.entries.map(\.kind) == [.item, .separator, .submenu])
        let projects = hotlist.entries[0]
        #expect(projects.title == "&Projects" && projects.displayTitle == "Projects")
        #expect(projects.command == "cd /Users/me/Projects" && projects.target == "/Volumes/Backup/Projects")
        #expect(hotlist.entries[2].children.map(\.command) == ["cd smb://nas/old"])
        #expect(hotlist.hideCharacter == "?" && hotlist.hidesMarked)
        #expect(hotlist.isHidden(hotlist.entries[2].children[0]) && !hotlist.isHidden(projects))
        // Nothing was left out, so nothing was kept aside and nobody was told.
        #expect(settings.data(forKey: "places.hotlist.unreadable") == nil && bench.interaction.log.isEmpty)
    }

    /// Missing fields take their defaults and unknown ones are ignored, without a complaint.
    @Test
    internal func aHotlistWithOtherFieldsLoads() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.hotlistOtherFields, forKey: "places.hotlist", in: settings)
        let (bench, plugin) = Self.bench(settings)
        let hotlist = plugin.hotlist(in: bench.kernel)
        #expect(hotlist.entries.map(\.title) == ["Home", "Downloads"])
        #expect(hotlist.entries.allSatisfy { $0.kind == .item && $0.target.isEmpty && $0.children.isEmpty })
        #expect(hotlist.entries[1].command == "cd ~/Downloads")
        #expect(hotlist.hideCharacter == "?" && !hotlist.hidesMarked)
        #expect(settings.data(forKey: "places.hotlist.unreadable") == nil && bench.interaction.log.isEmpty)
    }

    /// The hotlist is stored again in the same shape when the editor hands it back unchanged.
    @Test
    internal func theHotlistIsSavedInTheSameShape() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.hotlist, forKey: "places.hotlist", in: settings)
        let (bench, plugin) = Self.bench(settings)
        plugin.editHotlist = \.self
        bench.commands.perform(.configureHotlist)
        #expect(SettingsJSON.matches(settings.data(forKey: "places.hotlist"), Fixture.hotlist))
    }

    /// The history loads in order, with what thinning hides, and so do the frequent folders.
    @Test
    internal func theHistoriesLoad() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.historyLeft, forKey: "places.history.left", in: settings)
        SettingsJSON.store(Fixture.frequent, forKey: "places.history.frequent", in: settings)
        var told: [String] = []
        let problem: (String) -> Void = { told.append($0) }
        let tracker = DirectoryHistoryTracker(settings: settings.scoped(to: "places"), problem: problem)
        let history = tracker.history(of: .left)
        #expect(
            history.visits.map(\.location) == [
                "file:///Users/me/", "file:///Users/me/Downloads/", "ftp://files.example.com/pub/"
            ]
        )
        #expect(history.visits.map(\.isVisible) == [true, false, true])
        #expect(history.current?.absoluteString == "ftp://files.example.com/pub/")
        #expect(
            history.shown(thinning: true).map(\.absoluteString) == ["ftp://files.example.com/pub/", "file:///Users/me/"]
        )
        #expect(tracker.history(of: .right).visits.isEmpty)
        let top = tracker.frequent.top()
        #expect(top.map(\.directory.path) == ["/Users/me", "/Users/me/Downloads"] && top.map(\.visits) == [12, 3])
        #expect(told.isEmpty)
    }

    /// A visit without `isVisible` counts as passed through; an unknown field is ignored.
    @Test
    internal func aHistoryWithOtherFieldsLoads() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.historyOtherFields, forKey: "places.history.left", in: settings)
        var told: [String] = []
        let problem: (String) -> Void = { told.append($0) }
        let tracker = DirectoryHistoryTracker(settings: settings.scoped(to: "places"), problem: problem)
        let visits = tracker.history(of: .left).visits
        #expect(visits.map(\.location) == ["file:///a/", "file:///b/"] && visits.map(\.isVisible) == [false, true])
        #expect(told.isEmpty)
    }

    /// "Save now" writes both in the shape they were read in.
    @Test
    internal func theHistoriesAreSavedInTheSameShape() {
        let settings = MemorySettings()
        SettingsJSON.store(Fixture.historyLeft, forKey: "places.history.left", in: settings)
        SettingsJSON.store(Fixture.frequent, forKey: "places.history.frequent", in: settings)
        DirectoryHistoryTracker(settings: settings.scoped(to: "places")).save()
        #expect(SettingsJSON.matches(settings.data(forKey: "places.history.left"), Fixture.historyLeft))
        #expect(SettingsJSON.matches(settings.data(forKey: "places.history.frequent"), Fixture.frequent))
    }
}
