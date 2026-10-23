import Foundation
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// What the Multi-Rename Tool remembers, as earlier versions wrote it: the saved settings, the
/// runs that can be undone and the histories of its fields load as they were meant, and are
/// written again in the same shape.
@MainActor
@Suite
internal struct MultiRenameSettingsMigration {
    /// What earlier versions wrote, one fixture per format.
    internal enum Fixture {
        /// The saved settings as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `multirename.saved`: the fields of the tool by the name they were saved under.
        /// "Photos" makes `IMG_0100.jpg`, `IMG_0105.jpg`… in lower case (`letterCase` 1).
        internal static let saved = #"""
            {"Photos":{"nameMask":"IMG_[C]","extensionMask":"[E]","search":"","replacement":"","caseSensitive":false,\#
            "firstOnly":false,"searchesExtension":true,"regularExpression":false,"substitute":false,"letterCase":1,\#
            "counter":{"start":100,"step":5,"digits":4}},\#
            "Dashes":{"nameMask":"[N]","extensionMask":"[E]","search":" ","replacement":"-","caseSensitive":true,\#
            "firstOnly":true,"searchesExtension":false,"regularExpression":false,"substitute":false,"letterCase":0,\#
            "counter":{"start":1,"step":1,"digits":1}}}
            """#

        /// The runs that can be undone, as commit 16d647d (2026-10-14) wrote them.
        ///
        /// `multirename.undo`: one list of renamed files per run, the latest last. Two runs:
        /// one photo renamed, then two documents.
        internal static let undo = #"""
            [[{"from":"file:\/\/\/Users\/me\/Pictures\/a.jpg","to":"file:\/\/\/Users\/me\/Pictures\/IMG_0100.jpg"}],\#
            [{"from":"file:\/\/\/Users\/me\/Documents\/x%20y.txt","to":"file:\/\/\/Users\/me\/Documents\/x-y.txt"},\#
            {"from":"file:\/\/\/Users\/me\/Documents\/b.txt","to":"file:\/\/\/Users\/me\/Documents\/B.txt"}]]
            """#

        /// The number of runs beside them, as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `multirename.undoCount`: read instead of decoding the runs, which can be megabytes.
        internal static let undoCount = "2"

        /// A field's history as commit 16d647d (2026-10-14) wrote it.
        ///
        /// `multirename.history.nameMask`: what was typed into the mask field, newest first.
        internal static let nameMaskHistory = #"["IMG_[C]","[N]_old"]"#
    }

    /// A store on a fresh settings object holding the fixtures under their keys.
    private static func store(_ fixtures: [String: String]) -> (store: RenameStore, settings: MemorySettings) {
        let settings = MemorySettings()
        for (key, fixture) in fixtures {
            SettingsJSON.store(fixture, forKey: "multirename." + key, in: settings)
        }
        return (RenameStore(settings: settings), settings)
    }

    /// Both saved settings load with every field.
    @Test
    internal func theSavedSettingsLoad() throws {
        let (store, _) = Self.store(["saved": Fixture.saved])
        #expect(store.savedNames == ["Dashes", "Photos"])
        let photos = try #require(store.saved["Photos"])
        #expect(photos.nameMask == "IMG_[C]" && photos.extensionMask == "[E]" && photos.letterCase == .lower)
        #expect(photos.counter == CounterDefinition(start: 100, step: 5, digits: 4))
        #expect(photos.searchesExtension && !photos.caseSensitive && !photos.regularExpression)
        let dashes = try #require(store.saved["Dashes"])
        #expect(dashes.search == " " && dashes.replacement == "-" && dashes.caseSensitive && dashes.firstOnly)
        #expect(!dashes.searchesExtension && dashes.letterCase == .unchanged && dashes.counter == CounterDefinition())
    }

    /// The runs load in order, with their count beside them.
    @Test
    internal func theUndoHistoryLoads() throws {
        let (store, _) = Self.store(["undo": Fixture.undo, "undoCount": Fixture.undoCount])
        #expect(store.undoCount == 2)
        let runs = store.undoHistory
        try #require(runs.count == 2)
        #expect(runs[0].map(\.destination.lastPathComponent) == ["IMG_0100.jpg"])
        #expect(runs[1].map(\.from.path) == ["/Users/me/Documents/x y.txt", "/Users/me/Documents/b.txt"])
        #expect(store.lastUndo.map(\.destination.lastPathComponent) == ["x-y.txt", "B.txt"])
    }

    /// Runs saved before their count was kept: there is something to undo until they are
    /// decoded, and then the count is theirs (`RenameStore.undoCount`).
    @Test
    internal func anUndoHistoryWithoutItsCountLoads() {
        let (store, settings) = Self.store(["undo": Fixture.undo])
        #expect(store.undoCount == 1)
        #expect(store.undoHistory.count == 2 && store.undoCount == 2)
        // Written again, the count is there.
        store.flush()
        #expect(SettingsJSON.matches(settings.data(forKey: "multirename.undoCount"), Fixture.undoCount))
    }

    /// The history of a field loads, newest first.
    @Test
    internal func theHistoriesLoad() {
        let (store, _) = Self.store(["history.nameMask": Fixture.nameMaskHistory])
        #expect(store.history(.nameMask) == ["IMG_[C]", "[N]_old"])
        #expect(store.history(.search).isEmpty)
    }

    /// Saved settings, runs, count and history are stored again in the same shape.
    @Test
    internal func everythingIsSavedInTheSameShape() {
        let (store, settings) = Self.store([
            "saved": Fixture.saved, "undo": Fixture.undo, "undoCount": Fixture.undoCount,
            "history.nameMask": Fixture.nameMaskHistory
        ])
        store.saved = store.saved
        _ = store.undoHistory
        store.flush()
        // Using the newest mask again leaves the history as it was.
        store.remember("IMG_[C]", in: .nameMask)
        #expect(SettingsJSON.matches(settings.data(forKey: "multirename.saved"), Fixture.saved))
        #expect(SettingsJSON.matches(settings.data(forKey: "multirename.undo"), Fixture.undo))
        #expect(SettingsJSON.matches(settings.data(forKey: "multirename.undoCount"), Fixture.undoCount))
        #expect(SettingsJSON.matches(settings.data(forKey: "multirename.history.nameMask"), Fixture.nameMaskHistory))
    }
}
