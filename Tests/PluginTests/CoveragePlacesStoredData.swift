import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// Stored hotlists and histories with keys left out, more than is kept, and passwords.
@MainActor
@Suite
internal struct CoveragePlacesStoredData {
    /// Reads `json`, stored under a key, as `type`; the value, or nil, and what the user was told.
    internal func load<Value: Decodable>(_ type: Value.Type, _ json: String) -> (Value?, [String]) {
        let settings = MemorySettings()
        settings.set(Data(json.utf8) as Data?, forKey: "key")
        var told: [String] = []
        let value = StoredSettings.load(type, key: "key", in: settings) { told.append($0) }
        return (value, told)
    }

    /// Lists and entries stored without some of their keys take the defaults for them.
    @Test
    internal func entriesAndListsWithoutTheirKeysTakeTheDefaults() {
        let (list, told) = load(Hotlist.self, #"{"hidesMarked":true}"#)
        #expect(list == Hotlist(entries: [], hideCharacter: "?", hidesMarked: true) && told.isEmpty)
        let (withEntry, _) = load(Hotlist.self, #"{"entries":[{"kind":"item","command":"cd /a"}]}"#)
        #expect(withEntry?.entries == [HotlistEntry(kind: .item, title: "", command: "cd /a")])
    }

    /// A history or a count of visits stored without its keys is read as empty.
    @Test
    internal func historiesAndCountsWithoutTheirKeysAreEmpty() {
        #expect(load(DirectoryHistory.self, "{}").0 == DirectoryHistory())
        #expect(load(FrequentFolders.self, "{}").0 == FrequentFolders())
    }

    /// Of more counts than are kept only the most visited stay, and a negative count reads as none.
    @Test
    internal func onlyTheMostVisitedOfTooManyStoredCountsAreKept() throws {
        let counts = (0..<(FrequentFolders.storedLimit + 5)).map { "\"file:///f\($0)\": \($0 - 2)" }
        let (frequent, _) = load(FrequentFolders.self, #"{"counts":{"# + counts.joined(separator: ",") + "}}")
        let kept = try #require(frequent).counts
        // The five least visited go; a negative count reads as none.
        #expect(kept.count == FrequentFolders.storedLimit)
        #expect((0..<5).allSatisfy { kept["file:///f\($0)"] == nil } && kept["file:///f204"] == 202)
        let (few, _) = load(FrequentFolders.self, #"{"counts":{"file:///a":-3}}"#)
        #expect(few?.counts == ["file:///a": 0])
    }

    /// A visit without a location has an empty key.
    @Test
    internal func aVisitWithoutALocationKeyHasAnEmptyKey() {
        let visit = DirectoryVisit(location: "", isVisible: true)
        #expect(visit.key.isEmpty && visit.location.isEmpty)
    }

    /// Stored locations leave the password out and keep everything else.
    @Test
    internal func storedLocationsLeaveThePasswordOut() throws {
        let remote = try #require(URL(string: "sftp://user:secret@host.example/home/me/"))
        #expect(DirectoryHistory.stored(remote) == "sftp://user@host.example/home/me/")
        let empty = try #require(URL(string: "smb://user:@host/share"))
        #expect(DirectoryHistory.stored(empty) == "smb://user@host/share")
        // A user without a password, and an @ in a path, stay as they are.
        let plain = try #require(URL(string: "sftp://user@host/a@b"))
        #expect(DirectoryHistory.stored(plain) == "sftp://user@host/a@b")
        #expect(DirectoryHistory.stored(URL(fileURLWithPath: "/a@b")) == "file:///a@b")
    }

    /// A tracker nobody asked to tell of damaged data still keeps it aside, and measures stays by the clock.
    @Test
    internal func aTrackerWithoutAProblemHandlerStillKeepsTheDamagedDataAside() {
        let settings = MemorySettings()
        settings.set(Data("{broken".utf8) as Data?, forKey: "history.left")
        let tracker = DirectoryHistoryTracker(settings: settings)
        #expect(tracker.history(of: .left) == DirectoryHistory())
        #expect(settings.data(forKey: "history.left.unreadable") == Data("{broken".utf8))
        // It measures stays with the clock.
        tracker.visited(URL(fileURLWithPath: "/a"), on: .left)
        #expect(tracker.history(of: .left).visits.map(\.location) == ["file:///a"])
    }
}
