import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// Stored hotlists and histories with keys left out, more than is kept, and passwords.
@MainActor
@Suite
struct CoveragePlacesStoredData {
    func load<Value: Decodable>(_ type: Value.Type, _ json: String) -> (Value?, [String]) {
        let settings = MemorySettings()
        settings.set(Data(json.utf8) as Data?, forKey: "key")
        var told: [String] = []
        let value = StoredSettings.load(type, key: "key", in: settings) { told.append($0) }
        return (value, told)
    }

    @Test
    func entriesAndListsWithoutTheirKeysTakeTheDefaults() {
        let (list, told) = load(Hotlist.self, #"{"hidesMarked":true}"#)
        #expect(list == Hotlist(entries: [], hideCharacter: "?", hidesMarked: true) && told.isEmpty)
        let (withEntry, _) = load(Hotlist.self, #"{"entries":[{"kind":"item","command":"cd /a"}]}"#)
        #expect(withEntry?.entries == [HotlistEntry(kind: .item, title: "", command: "cd /a")])
    }

    @Test
    func historiesAndCountsWithoutTheirKeysAreEmpty() {
        #expect(load(DirectoryHistory.self, "{}").0 == DirectoryHistory())
        #expect(load(FrequentFolders.self, "{}").0 == FrequentFolders())
    }

    @Test
    func onlyTheMostVisitedOfTooManyStoredCountsAreKept() throws {
        let counts = (0..<(FrequentFolders.storedLimit + 5)).map { "\"file:///f\($0)\": \($0 - 2)" }
        let (frequent, _) = load(FrequentFolders.self, #"{"counts":{"# + counts.joined(separator: ",") + "}}")
        let kept = try #require(frequent).counts
        // The five least visited go; a negative count reads as none.
        #expect(kept.count == FrequentFolders.storedLimit)
        #expect((0..<5).allSatisfy { kept["file:///f\($0)"] == nil } && kept["file:///f204"] == 202)
        let (few, _) = load(FrequentFolders.self, #"{"counts":{"file:///a":-3}}"#)
        #expect(few?.counts == ["file:///a": 0])
    }

    @Test
    func aVisitWithoutALocationKeyHasAnEmptyKey() {
        let visit = DirectoryHistory.Visit(location: "", isVisible: true)
        #expect(visit.key.isEmpty && visit.location.isEmpty)
    }

    @Test
    func storedLocationsLeaveThePasswordOut() throws {
        let remote = try #require(URL(string: "sftp://user:secret@host.example/home/me/"))
        #expect(DirectoryHistory.stored(remote) == "sftp://user@host.example/home/me/")
        let empty = try #require(URL(string: "smb://user:@host/share"))
        #expect(DirectoryHistory.stored(empty) == "smb://user@host/share")
        // A user without a password, and an @ in a path, stay as they are.
        let plain = try #require(URL(string: "sftp://user@host/a@b"))
        #expect(DirectoryHistory.stored(plain) == "sftp://user@host/a@b")
        #expect(DirectoryHistory.stored(URL(fileURLWithPath: "/a@b")) == "file:///a@b")
    }

    @Test
    func aTrackerWithoutAProblemHandlerStillKeepsTheDamagedDataAside() {
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

/// The hotlist value: levels that do not exist, trimming, damaged lists and quoting.
@Suite
struct CoveragePlacesHotlist {
    let sample = Hotlist(entries: [
        .item("A", command: "cd /a"),
        .submenu("S", [.item("In", command: "cd /in"), .item("In2", command: "cd /in2")]),
        .item("B", command: "cd /b")
    ])

    @Test
    func aLevelThatDoesNotExistIsEmptyAndCannotBeChanged() {
        var list = sample
        #expect(list.children(of: [7]).isEmpty && list.children(of: [0, 3]).isEmpty)
        #expect(list.remove(at: []) == nil && list.remove(at: [9, 0]) == nil)
        #expect(!list.update(at: []) { $0.title = "x" } && !list.update(at: [9, 0]) { $0.title = "x" })
        #expect(!list.update(at: [1, 5]) { $0.title = "x" })
        #expect(list == sample)
    }

    @Test
    func trimmingCountsWhatIsCutOffWithEverythingInside() {
        var entries: [HotlistEntry] = [
            .item("kept", command: ""),
            .submenu("cut", [.submenu("inner", [.item("deep", command: "")]), .separator])
        ]
        var room = 1
        #expect(Hotlist.trimmed(&entries, room: &room) == 4)
        #expect(entries.map(\.title) == ["kept"] && room == 0)
    }

    @Test
    func aMoveThatGoesNowhereLeavesTheListAlone() {
        var list = sample
        #expect(list.move(at: [0], by: 0) == [0] && list.move(at: [], by: 1) == [])
        #expect(list.move(at: [0], by: -1) == [0] && list.move(at: [9], by: 1) == [9])
        #expect(list.move(at: [5, 0, 0], by: 1) == [5, 0, 0] && list.move(at: [1, 7], by: 1) == [1, 7])
        #expect(list == sample)
    }

    @Test
    func entriesMoveIntoAndOutOfSubmenusAsInAFlatList() {
        var list = sample
        #expect(list.move(at: [0], by: 1) == [0, 0])
        #expect(list.entries[0].children.map(\.title) == ["A", "In", "In2"])
        #expect(list.move(at: [0, 0], by: -1) == [0])
        #expect(list == sample)
        #expect(list.move(at: [2], by: -1) == [1, 2] && list.entries[1].children.last?.title == "B")
        #expect(list.move(at: [1, 2], by: 1) == [2] && list == sample)
    }

    @Test
    func anEntryInsideADamagedItemIsTakenOutNotDoubled() {
        // Read from damaged data: an item holding entries. The editor lists them; a move takes
        // the entry out to the level of the item, once.
        var list = Hotlist(entries: [
            HotlistEntry(kind: .item, title: "Odd", children: [.item("x", command: ""), .submenu("y")])
        ])
        #expect(list.move(at: [0, 0], by: 1) == [1])
        #expect(list.entries.map(\.title) == ["Odd", "x"] && list.entries[0].children.map(\.title) == ["y"])
        #expect(list.count == 3)
    }

    @Test
    func withoutAHideCharacterNothingIsMarked() {
        var list = sample
        list.hideCharacter = ""
        list.toggleHideMark(at: [0])
        #expect(list == Hotlist(entries: sample.entries, hideCharacter: ""))
    }

    @Test
    func anEmptyPathNeedsNoQuotes() {
        #expect(HotlistAction.changeDirectoryCommand(to: "") == "cd ")
    }
}

/// The tree model: names that come twice, linking from the middle, levels and searches.
@Suite
struct CoveragePlacesTree {
    let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)
    var many: [String] { ["a", "a"] + (0..<10).map { "n\($0)" } }

    @Test
    func aNameGivenTwiceInOrderIsFoundAsTheFirst() throws {
        let tree = DirectoryTree(rootURL: root)
        let node = try #require(tree.setChildren(many, ofPath: "", sorted: true))
        #expect(node.children.count == 12)
        #expect(tree.node(at: "a") === node.children[0])
        // Read again, and linked again: the first of the two keeps its place.
        tree.setChildren(["a", "b"], ofPath: "", sorted: true)
        #expect(tree.root.children.map(\.name) == ["a", "b"])
        let again = DirectoryTree(rootURL: root)
        again.setChildren(many, ofPath: "", sorted: true)
        let first = again.root.children[0]
        let nodes = DirectoryTree.makeNodes(["a", "c"], sorted: true)
        #expect(again.attach(nodes, ofPath: "") == 2)
        #expect(again.root.children.map(\.name) == ["a", "c"] && again.root.children[0] === first)
    }

    @Test
    func linkingThatStartsInTheMiddleTakesTheRest() {
        let tree = DirectoryTree(rootURL: root)
        let nodes = DirectoryTree.makeNodes(["x", "y", "z"], sorted: true)
        #expect(tree.attach(nodes, ofPath: "", from: 1) == 3)
        #expect(tree.root.children.map(\.name) == ["y", "z"] && tree.root.isScanned)
    }

    @Test
    func levelsAreEqualByWhatTheyList() {
        let one = TreeScanner.Level(path: "a", children: ["b"], isSorted: true)
        #expect(one == TreeScanner.Level(path: "a", children: ["b"], isSorted: true))
        #expect(one != TreeScanner.Level(path: "a", children: ["b"]))
    }

    @Test
    func aSearchWithTimeToSpareGoesOnPastEachClockCheck() {
        let tree = DirectoryTree(rootURL: root)
        tree.setChildren((0..<2_000).map { "folder\($0)" }, ofPath: "")
        let result = tree.search("nothing", from: nil, timeBudget: 3_600)
        guard case .none = result else {
            Issue.record("expected no match, got \(result)")
            return
        }
        #expect(TreeQuickSearch("Ab*").text == "ab*" && TreeQuickSearch("Ab").text == "ab")
    }

    @Test
    func aFolderThatCannotBeAskedIsNoMountPoint() {
        #expect(!TreeScanner.isMountPoint("/nowhere/\(UUID().uuidString)"))
        #expect(TreeScanner.isMountPoint("/") && !TreeScanner.isMountPoint(NSTemporaryDirectory()))
    }

    @Test
    func aSearchWithoutTimeLeftSaysWhereItStopped() {
        let tree = DirectoryTree(rootURL: root)
        tree.setChildren((0..<2_000).map { "folder\($0)" }, ofPath: "")
        let result = tree.search("nothing", from: nil, timeBudget: 0)
        guard case .pending(_, let remaining) = result else {
            Issue.record("expected a pending search, got \(result)")
            return
        }
        #expect(remaining > 0 && remaining < 2_001)
    }

    @Test
    func aScanStopsAtItsFolderLimit() {
        let memory = MemoryFileSystem()
        memory.addDirectory("/R/a/a1")
        memory.addDirectory("/R/b")
        let scanner = TreeScanner(root: memory.url("/R"), provider: memory)
        scanner.folderLimit = 1
        #expect(!scanner.run { _ in })
        #expect(scanner.reachedLimit && scanner.paths == ["a", "b"] && scanner.unscanned == ["a", "b"])
    }
}
