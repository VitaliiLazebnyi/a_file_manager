import AFMKernel
import Foundation
import Testing

@testable import PlacesPlugin

/// The tree: neighbours in constant time, a name index, folded names, failed prefixes.
@Suite
internal struct ConfigPlacesFixTreeModel {
    /// The root of the trees.
    internal let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)

    /// A search through a wide folder takes linear time, and a text that extends one that found nothing is
    /// refused at once.
    @Test
    internal func steppingThroughAWideFolderIsLinear() {
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

    /// The neighbours of a folder stay right after folders are added and a level is read again.
    @Test
    internal func indexesStayRightAfterInsertsAndRewrites() throws {
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
        #expect(tree.neighbour(of: try #require(tree.node(at: "f")), forward: false).name == "e")
        #expect(tree.neighbour(of: try #require(tree.node(at: "a")), forward: false).parent == nil)
    }

    /// Each name of a wide folder is found without walking the level.
    @Test
    internal func aWideFolderResolvesNamesQuickly() {
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

    /// Folders the cache names as unread are not read in the tree made from it.
    @Test
    internal func unscannedFoldersStayUnscannedFromTheCache() {
        let tree = DirectoryTree(rootURL: root, paths: ["a", "a/b", "Volumes"], unscanned: ["Volumes"])
        #expect(tree.node(at: "Volumes")?.isScanned == false && tree.node(at: "a")?.isScanned == true)
    }
}
