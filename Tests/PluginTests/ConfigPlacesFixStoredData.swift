import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// Stored hotlists and histories survive missing keys, unknown keys and bad elements.
@MainActor
@Suite
internal struct ConfigPlacesFixStoredData {
    /// A hotlist with unknown keys, entries without a kind and bad elements is read as far as it goes, and the
    /// original is kept aside.
    @Test
    internal func aHotlistReadsLeniently() {
        let settings = MemorySettings()
        let json = """
            {"entries":[{"kind":"item","title":"A","command":"cd /a","future":1},
                        {"title":"No kind","command":"cd /b"},
                        {"kind":"weird","title":"bad"}, 7,
                        {"kind":"submenu","title":"S","children":[{"kind":"item","title":"in"},{"kind":"???"}]}],
             "unknown":true}
            """
        settings.set(Data(json.utf8) as Data?, forKey: "hotlist")
        var told: [String] = []
        let list = StoredSettings.load(Hotlist.self, key: "hotlist", in: settings) { told.append($0) }
        #expect(list?.entries.map(\.title) == ["A", "No kind", "S"])
        #expect(list?.entries[1].kind == .item && list?.entries[2].children.map(\.title) == ["in"])
        #expect(list?.hideCharacter == "?" && list?.hidesMarked == false)
        // The original is kept aside, the user is told.
        #expect(settings.data(forKey: "hotlist.unreadable") == Data(json.utf8) && told.count == 1)
    }

    /// Data that cannot be read is kept aside, so saving over it does not lose it.
    @Test
    internal func unreadableDataIsNotLostBySavingOver() {
        let settings = MemorySettings()
        settings.set(Data("{broken".utf8) as Data?, forKey: "hotlist")
        var told = 0
        let list = StoredSettings.load(Hotlist.self, key: "hotlist", in: settings) { _ in told += 1 }
        #expect(list == nil && told == 1)
        settings.set(Hotlist(entries: [.item("x", command: "cd /x")]), forKey: "hotlist")
        #expect(settings.data(forKey: "hotlist.unreadable") == Data("{broken".utf8))
    }

    /// A hotlist that reads cleanly raises no complaint and keeps nothing aside.
    @Test
    internal func aCleanHotlistRaisesNoComplaint() {
        let settings = MemorySettings()
        settings.set(Hotlist(entries: [.item("x", command: "cd /x"), .separator]), forKey: "hotlist")
        var told = 0
        #expect(StoredSettings.load(Hotlist.self, key: "hotlist", in: settings) { _ in told += 1 }?.entries.count == 2)
        #expect(told == 0 && settings.data(forKey: "hotlist.unreadable") == nil)
    }

    /// Histories and counts with unknown keys and bad visits are read as far as they go.
    @Test
    internal func historiesReadLeniently() {
        let settings = MemorySettings()
        settings.set(
            Data(
                #"{"visits":[{"location":"file:///a"},{"isVisible":true},{"location":"file:///b","isVisible":true,"x":1}]}"#
                    .utf8
            ) as Data?,
            forKey: "history.left"
        )
        settings.set(Data(#"{"counts":{"file:///a":2},"extra":1}"#.utf8) as Data?, forKey: "history.frequent")
        var told: [String] = []
        let tracker = DirectoryHistoryTracker(settings: settings, now: Date.init) { told.append($0) }
        #expect(
            tracker.history(of: .left).visits.map(\.location) == ["file:///a", "file:///b"]
                && tracker.frequent.counts == ["file:///a": 2]
        )
        #expect(told.count == 1 && settings.data(forKey: "history.left.unreadable") != nil)
    }

    /// An entry whose command starts with `em_` runs that user command; another word is a folder.
    @Test
    internal func hotlistEntriesRunUserCommands() {
        #expect(HotlistAction("em_build") == .command("em_build", .nothing))
        #expect(HotlistAction("em_open some words") == .command("em_open", .text("some words")))
        #expect(HotlistAction("emotion") == .changeDirectory(path: "emotion", focusingOnIt: false))
    }
}
