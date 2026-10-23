import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// Round 2 of the review, second pass, Places: the limit of the hotlist, the tree cache and its file, and a tree that
/// is linked in turns.
@Suite
internal struct Review2PluginsA2Places {
    /// The folders on disk the caches write to.
    internal let box: Sandbox
    /// The root of the trees, which need not exist.
    internal let root = URL(fileURLWithPath: "/tmp/tree-root/", isDirectory: true)

    /// A fresh sandbox.
    internal init() throws {
        box = try Sandbox()
    }

    /// Where `node` stands among its parent's children, or -1 when it is not among them.
    private static func indexInParent(_ node: TreeNode) -> Int {
        node.parent?.children.firstIndex { $0 === node } ?? -1
    }

    /// A stored hotlist with more entries than the limit is cut to the limit when read, counting submenus with what
    /// they hold.
    @Test
    internal func theHotlistLimitHoldsForWhatIsStored() throws {
        var hotlist = Hotlist()
        for index in 0..<(Hotlist.limit + 25) {
            hotlist.entries.append(.item("t\(index)", command: "cd /x\(index)"))
        }
        let data = try JSONEncoder().encode(hotlist)
        let report = DecodeReport()
        let loaded = try DecodeReport.$current.withValue(report) {
            try JSONDecoder().decode(Hotlist.self, from: data)
        }
        #expect(loaded.count == Hotlist.limit && loaded.entries.first?.title == "t0" && report.skipped == 25)
        // Submenus count with what they hold, in display order.
        var nested = Hotlist()
        nested.entries = [
            HotlistEntry(
                kind: .submenu,
                title: "m",
                children: (0..<(Hotlist.limit + 5)).map { .item("c\($0)", command: "cd /c\($0)") }
            ),
            .item("after", command: "cd /after")
        ]
        let reloaded = try JSONDecoder().decode(Hotlist.self, from: try JSONEncoder().encode(nested))
        #expect(reloaded.count == Hotlist.limit && reloaded.entries.count == 1)
    }

    /// A folder noted in the cache after the tree was stored shows, with the folders on its way, as not read yet.
    @Test
    internal func aFolderNotedLaterShowsAsNotReadYet() {
        let cache = TreeCache(directory: nil)
        cache.store(["a", "b"], for: root)
        cache.noteFolder("a/new/deeper", below: root)
        cache.waitForUpdates()
        let entry = cache.entry(for: root)
        #expect(entry?.paths.sorted() == ["a", "a/new", "a/new/deeper", "b"])
        #expect(Set(entry?.unscanned ?? []) == ["a/new", "a/new/deeper"])
        let tree = DirectoryTree(rootURL: root, paths: entry?.paths ?? [], unscanned: entry?.unscanned ?? [])
        #expect(tree.node(at: "a/new/deeper")?.isScanned == false && tree.node(at: "b")?.isScanned == true)
    }

    /// Names that begin with a combining mark come back from the cache file and its text, and are found in the tree.
    @Test
    internal func namesThatBeginWithACombiningMarkComeBackFromTheFile() {
        let paths = ["\u{301}start", "dir", "dir/\u{301}inside", "dir/\u{0300}\u{0301}x", "plain"]
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(paths, for: root, unscanned: ["\u{301}start"])
        let fresh = TreeCache(directory: box.url("cache"))
        let entry = fresh.entry(for: root)
        #expect(entry?.paths == paths && entry?.unscanned == ["\u{301}start"] && entry?.isComplete == true)
        // The same through the text.
        let text = TreeCache.format(TreeCache.Entry(paths: paths, unscanned: ["\u{301}start"]), root: root)
        #expect(TreeCache.parseEntry(text, root: root)?.paths == paths)
        // A name with a combining mark after the slash is found in the tree too.
        let tree = DirectoryTree(rootURL: root, paths: paths)
        #expect(tree.node(at: "dir/\u{301}inside") != nil && tree.count == 5)
    }

    /// A tree of many folders is written to a file only its user may read, with no temporary file left behind.
    @Test
    internal func aTreeOfManyFoldersIsWrittenInPiecesForTheUserAlone() throws {
        let paths = (0..<300_000).map { "folder-\($0)" }
        let cache = TreeCache(directory: box.url("big"))
        cache.store(paths, for: root)
        let file = try #require(cache.fileURL(for: root))
        var info = stat()
        #expect(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_size > 4_000_000)
        #expect(TreeCache(directory: box.url("big")).entry(for: root)?.paths == paths)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".tmp\(getpid())"))
    }

    /// Trees of more folders than the memory limit are trimmed from memory, and each is still read from its file.
    @Test
    internal func aHugeSetOfTreesInMemoryIsTrimmedByTheNumberOfFolders() {
        let cache = TreeCache(directory: box.url("many"))
        for index in 0..<4 {
            cache.store(
                (0..<600_000).map { "p\($0)" },
                for: URL(fileURLWithPath: "/tmp/root\(index)/", isDirectory: true)
            )
        }
        // Not all four are held (that would be more than the limit); each is still there from its file.
        for index in 0..<4 {
            #expect(
                cache.entry(for: URL(fileURLWithPath: "/tmp/root\(index)/", isDirectory: true))?.paths.count == 600_000
            )
        }
    }

    /// A folder made while the scan is linking is linked once and keeps its node; one not in the listing goes.
    @Test
    internal func aFolderMadeMeanwhileIsNotLinkedTwiceAndKeepsItsNode() throws {
        let tree = DirectoryTree(rootURL: root)
        let names = (0..<100).map { "a\($0)" }
        let nodes = DirectoryTree.makeNodes(names)
        var done = tree.attach(nodes, ofPath: "", from: 0, limit: 10)
        #expect(done == 10)
        // The window makes the folder of the panel while the scan is still linking.
        let made = try #require(tree.node(at: "a50", creating: true))
        let later = try #require(tree.node(at: "a95", creating: true))
        while done < nodes.count {
            done = tree.attach(nodes, ofPath: "", from: done, limit: 10)
        }
        let children = tree.root.children
        #expect(children.count == 100 && Set(children.map(\.name)).count == 100)
        #expect(children.map(\.name) == DirectoryTree.makeNodes(names).map(\.name))
        #expect(children.first { $0.name == "a50" } === made && children.first { $0.name == "a95" } === later)
        #expect(
            tree.count == 100 && children.enumerated().allSatisfy { Self.indexInParent($0.element) == $0.offset }
                && tree.root.isScanned
        )
        // A folder that was made and is not in the listing has gone.
        let tree2 = DirectoryTree(rootURL: root)
        var linked = tree2.attach(Array(DirectoryTree.makeNodes(["x1", "x2", "x3"])), ofPath: "", from: 0, limit: 1)
        _ = tree2.node(at: "ghost", creating: true)
        while linked < 3 {
            linked = tree2.attach(DirectoryTree.makeNodes(["x1", "x2", "x3"]), ofPath: "", from: linked, limit: 1)
        }
        #expect(tree2.root.children.map(\.name) == ["x1", "x2", "x3"] && tree2.count == 3)
    }

    /// A folder that already had children is rebuilt in turns of the limit, keeping what it had until the last turn.
    @Test
    internal func aFolderThatHadChildrenIsRebuiltInTurnsOfLimitedSize() throws {
        let tree = DirectoryTree(rootURL: root)
        // The way to the folder the window opened is made beforehand, with a stale child.
        let chain = try #require(tree.node(at: "mid/x", creating: true))
        _ = tree.node(at: "mid/gone", creating: true)
        let names = ["x"] + (0..<1_000).map { "n\($0)" }
        let nodes = DirectoryTree.makeNodes(names)
        let mid = try #require(tree.node(at: "mid"))
        var done = tree.attach(nodes, ofPath: "mid", from: 0, limit: 100)
        #expect(done == 100)
        // Until the last turn the folder has what it had, and no turn linked more than the limit.
        #expect(mid.children.count == 2 && !mid.isScanned)
        var turns = 1
        while done < nodes.count {
            done = tree.attach(nodes, ofPath: "mid", from: done, limit: 100)
            turns += 1
        }
        #expect(turns == 11 && mid.children.count == 1_001 && mid.isScanned)
        #expect(mid.children.first { $0.name == "x" } === chain && mid.children.allSatisfy { $0.name != "gone" })
        #expect(
            tree.count == 1 + 1_001
                && mid.children.enumerated().allSatisfy { Self.indexInParent($0.element) == $0.offset }
        )
    }
}
