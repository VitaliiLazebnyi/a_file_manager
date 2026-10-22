import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// Stored hotlists and histories survive missing keys, unknown keys and bad elements.
@MainActor
@Suite
struct ConfigPlacesFixStoredData {
    @Test
    func aHotlistReadsLeniently() {
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

    @Test
    func unreadableDataIsNotLostBySavingOver() {
        let settings = MemorySettings()
        settings.set(Data("{broken".utf8) as Data?, forKey: "hotlist")
        var told = 0
        let list = StoredSettings.load(Hotlist.self, key: "hotlist", in: settings) { _ in told += 1 }
        #expect(list == nil && told == 1)
        settings.set(Hotlist(entries: [.item("x", command: "cd /x")]), forKey: "hotlist")
        #expect(settings.data(forKey: "hotlist.unreadable") == Data("{broken".utf8))
    }

    @Test
    func aCleanHotlistRaisesNoComplaint() {
        let settings = MemorySettings()
        settings.set(Hotlist(entries: [.item("x", command: "cd /x"), .separator]), forKey: "hotlist")
        var told = 0
        #expect(StoredSettings.load(Hotlist.self, key: "hotlist", in: settings) { _ in told += 1 }?.entries.count == 2)
        #expect(told == 0 && settings.data(forKey: "hotlist.unreadable") == nil)
    }

    @Test
    func historiesReadLeniently() {
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
        let tracker = DirectoryHistoryTracker(settings: settings, problem: { told.append($0) })
        #expect(
            tracker.history(of: .left).visits.map(\.location) == ["file:///a", "file:///b"]
                && tracker.frequent.counts == ["file:///a": 2]
        )
        #expect(told.count == 1 && settings.data(forKey: "history.left.unreadable") != nil)
    }

    @Test
    func hotlistEntriesRunUserCommands() {
        #expect(HotlistAction("em_build") == .command("em_build", .nothing))
        #expect(HotlistAction("em_open some words") == .command("em_open", .text("some words")))
        #expect(HotlistAction("emotion") == .changeDirectory(path: "emotion", focusingOnIt: false))
    }
}

/// The tree: neighbours in constant time, a name index, folded names, failed prefixes.
@Suite
struct ConfigPlacesFixTreeModel {
    let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)

    @Test
    func steppingThroughAWideFolderIsLinear() {
        let names = (0..<20_000).map { "folder\($0)" }
        let tree = DirectoryTree(rootURL: root)
        tree.setChildren(names, ofPath: "")
        // Measured in the work this thread does, not by the clock: among the other tests (and
        // under a sanitizer) a thread stands still for longer than the limit without working.
        let started = ThreadTime.used
        #expect(tree.find("zzz", from: nil) == nil)
        // Quadratic stepping took more than half a second for 50 000; this is a few milliseconds.
        #expect(ThreadTime.used - started < 0.5)
        #expect(tree.find("folder1999", from: nil)?.name == "folder1999")
        // A text that extends one that matched nothing is refused without a pass.
        #expect(tree.find("zzzz", from: nil) == nil)
        tree.setChildren(["zzzz1"], ofPath: "folder1")
        #expect(tree.find("zzzz", from: nil)?.name == "zzzz1")
    }

    @Test
    func indexesStayRightAfterInsertsAndRewrites() {
        let tree = DirectoryTree(rootURL: root, paths: ["b", "d", "f"])
        _ = tree.node(at: "c", creating: true)
        _ = tree.node(at: "a", creating: true)
        #expect(tree.root.children.map(\.name) == ["a", "b", "c", "d", "f"])
        var visited: [String] = []
        var node = tree.root
        for _ in 0..<5 {
            node = tree.neighbour(of: node, forward: true)
            visited.append(node.name)
        }
        #expect(visited == ["a", "b", "c", "d", "f"])
        tree.setChildren(["f", "e", "a"], ofPath: "")
        #expect(tree.root.children.map(\.name) == ["a", "e", "f"])
        #expect(tree.neighbour(of: tree.node(at: "f")!, forward: false).name == "e")
        #expect(tree.neighbour(of: tree.node(at: "a")!, forward: false).isRoot)
    }

    @Test
    func aWideFolderResolvesNamesQuickly() {
        let names = (0..<30_000).map { "n\($0)" }
        let tree = DirectoryTree(rootURL: root)
        tree.setChildren(names, ofPath: "", sorted: true)
        // (The thread's own time: see `steppingThroughAWideFolderIsLinear`. Looking each name up
        // by walking the list would be 450 million comparisons.)
        let started = ThreadTime.used
        for name in names.shuffled() { _ = tree.node(at: name) }
        #expect(ThreadTime.used - started < 1)
        #expect(tree.count == 30_000)
    }

    @Test
    func unscannedFoldersStayUnscannedFromTheCache() {
        let tree = DirectoryTree(rootURL: root, paths: ["a", "a/b", "Volumes"], unscanned: ["Volumes"])
        #expect(tree.node(at: "Volumes")?.isScanned == false && tree.node(at: "a")?.isScanned == true)
    }
}

extension TreeNode {
    fileprivate var isRoot: Bool { parent == nil }
}

/// The cache: keyed by the hidden flag, partial trees, unscanned folders, debounced writes.
@Suite
struct ConfigPlacesFixCache {
    let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)

    @Test
    func hiddenAndVisibleTreesAreSeparate() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["a"], for: root)
        cache.store([".h", "a"], for: root, showHidden: true)
        #expect(cache.paths(for: root) == ["a"] && cache.paths(for: root, showHidden: true) == [".h", "a"])
        #expect(TreeCache(directory: box.url("cache")).paths(for: root, showHidden: true) == [".h", "a"])
        // A hidden folder is noted in the hidden tree only.
        cache.noteFolder("a/.git", below: root)
        cache.waitForUpdates()
        #expect(cache.paths(for: root) == ["a"] && cache.paths(for: root, showHidden: true) == [".h", "a", "a/.git"])
        cache.remove(for: root)
        #expect(cache.paths(for: root) == nil && cache.paths(for: root, showHidden: true) == nil)
    }

    @Test
    func unscannedAndPartialSurviveTheFile() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["a", "a/b", "Volumes"], unscanned: ["Volumes", "a/b"], isComplete: false, for: root)
        let restarted = TreeCache(directory: box.url("cache")).entry(for: root)
        #expect(
            restarted
                == TreeCache.Entry(paths: ["a", "a/b", "Volumes"], unscanned: ["Volumes", "a/b"], isComplete: false)
        )
        #expect(TreeCache.parse("root=file:///Volumes/Disk/\n[a]\n(a)\n", root: root) == ["a"])
    }

    @Test
    func notedFoldersAreWrittenOnceAfterABurst() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["base"], for: root)
        let file = try #require(cache.fileURL(for: root))
        let before = try Data(contentsOf: file)
        for index in 0..<200 { cache.noteFolder("base/n\(index)", below: root) }
        // The caller returned at once; nothing is written until the delay is over or it is asked for.
        #expect(try Data(contentsOf: file) == before)
        cache.waitForUpdates()
        #expect(cache.paths(for: root)?.count == 201)
        #expect(TreeCache(directory: box.url("cache")).paths(for: root)?.count == 201)
    }
}

/// A scan with the lean reader on the real disk, and its paths.
@Suite
struct ConfigPlacesFixScanning {
    @Test
    func theLeanReaderHonoursHiddenFoldersPackagesAndLinks() throws {
        let box = try Sandbox()
        try box.folder("b/inner")
        try box.folder("a")
        try box.folder(".hid/in")
        try box.folder("Some.app/Contents")
        try box.file("file.txt")
        try box.file("b/inner/file.txt")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("a"))
        for hidden in [false, true] {
            let scanner = TreeScanner(root: box.root, provider: LocalFileSystem(), showHidden: hidden)
            var levels: [TreeScanner.Level] = []
            #expect(scanner.run { levels += $0 })
            #expect(
                levels.first?.children == (hidden ? [".hid", "a", "b"] : ["a", "b"]) && levels.allSatisfy(\.isSorted)
            )
            #expect(
                scanner.paths == (hidden ? [".hid", "a", "b", ".hid/in", "b/inner"] : ["a", "b", "b/inner"])
                    && scanner.unscanned.isEmpty
            )
        }
    }

    @Test
    func excludedAndUnreachedFoldersAreRecorded() {
        let memory = MemoryFileSystem()
        memory.addDirectory("/V/Volumes/Other")
        memory.addDirectory("/V/keep/inner")
        let excluded = memory.url("/V/Volumes").locationKey
        let scanner = TreeScanner(root: memory.url("/V"), provider: memory) { $0.locationKey == excluded }
        #expect(scanner.run { _ in })
        #expect(scanner.paths == ["keep", "Volumes", "keep/inner"] && scanner.unscanned == ["Volumes"])

        let stopped = TreeScanner(root: memory.url("/V"), provider: memory, batchSize: 1)
        #expect(!stopped.run { _ in stopped.cancellation.cancel() })
        #expect(stopped.unscanned.contains("keep") && !stopped.paths.isEmpty)
    }
}
