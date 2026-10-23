import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The tree model: names that come twice, linking from the middle, levels and searches.
@Suite
internal struct CoveragePlacesTree {
    /// The root of the trees.
    internal let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)
    /// Twelve names, the first one twice.
    internal var many: [String] { ["a", "a"] + (0..<10).map { "n\($0)" } }

    /// A name that comes twice is found as the first of the two, and keeps its place when linked again.
    @Test
    internal func aNameGivenTwiceInOrderIsFoundAsTheFirst() throws {
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

    /// Linking that starts in the middle of a level takes the rest of it.
    @Test
    internal func linkingThatStartsInTheMiddleTakesTheRest() {
        let tree = DirectoryTree(rootURL: root)
        let nodes = DirectoryTree.makeNodes(["x", "y", "z"], sorted: true)
        #expect(tree.attach(nodes, ofPath: "", from: 1) == 3)
        #expect(tree.root.children.map(\.name) == ["y", "z"] && tree.root.isScanned)
    }

    /// Levels are equal when they list the same folders in the same way.
    @Test
    internal func levelsAreEqualByWhatTheyList() {
        let one = TreeScanner.Level(path: "a", children: ["b"], isSorted: true)
        #expect(one == TreeScanner.Level(path: "a", children: ["b"], isSorted: true))
        #expect(one != TreeScanner.Level(path: "a", children: ["b"]))
    }

    /// A search with time to spare goes on past each look at the clock to the end.
    @Test
    internal func aSearchWithTimeToSpareGoesOnPastEachClockCheck() {
        let tree = DirectoryTree(rootURL: root)
        tree.setChildren((0..<2_000).map { "folder\($0)" }, ofPath: "")
        let result = tree.search("nothing", from: nil, timeBudget: 3_600)
        guard case .notFound = result else {
            Issue.record("expected no match, got \(result)")
            return
        }
        #expect(TreeQuickSearch("Ab*").text == "ab*" && TreeQuickSearch("Ab").text == "ab")
    }

    /// A folder that cannot be asked about is no mount point.
    @Test
    internal func aFolderThatCannotBeAskedIsNoMountPoint() {
        #expect(!TreeScanner.isMountPoint("/nowhere/\(UUID().uuidString)"))
        #expect(TreeScanner.isMountPoint("/") && !TreeScanner.isMountPoint(NSTemporaryDirectory()))
    }

    /// A search without time left says how many folders are left to look at.
    @Test
    internal func aSearchWithoutTimeLeftSaysWhereItStopped() {
        let tree = DirectoryTree(rootURL: root)
        tree.setChildren((0..<2_000).map { "folder\($0)" }, ofPath: "")
        let result = tree.search("nothing", from: nil, timeBudget: 0)
        guard case .pending(_, let remaining) = result else {
            Issue.record("expected a pending search, got \(result)")
            return
        }
        #expect(remaining > 0 && remaining < 2_001)
    }

    /// A scan stops at its limit of folders and keeps the rest as unread.
    @Test
    internal func aScanStopsAtItsFolderLimit() {
        let memory = MemoryFileSystem()
        memory.addDirectory("/R/a/a1")
        memory.addDirectory("/R/b")
        let scanner = TreeScanner(root: memory.url("/R"), provider: memory)
        scanner.folderLimit = 1
        let completed = scanner.run { _ in
            // Only where the scan stops matters here.
        }
        #expect(!completed)
        #expect(scanner.reachedLimit && scanner.paths == ["a", "b"] && scanner.unscanned == ["a", "b"])
    }
}
