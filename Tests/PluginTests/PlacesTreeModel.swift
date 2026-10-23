import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The directory tree as a model: filling, paths and quick search.
@Suite
internal struct PlacesTreeModel {
    /// The root of the trees.
    internal let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)

    /// A tree of two folders with folders below them, names with numbers among them.
    internal func sample() -> DirectoryTree {
        DirectoryTree(
            rootURL: root,
            paths: ["Apps", "Apps/Tools", "Apps/Tools/test", "Work", "Work/file10", "Work/file2", "Work/Tests"]
        )
    }

    /// A tree made from cached paths sorts each level in natural order, whatever order the paths come in.
    @Test
    internal func buildsFromCachedPathsInNaturalOrder() {
        let tree = sample()
        #expect(tree.count == 7)
        #expect(tree.root.children.map(\.name) == ["Apps", "Work"])
        #expect(tree.node(at: "Work")?.children.map(\.name) == ["file2", "file10", "Tests"])
        #expect(
            tree.paths == ["Apps", "Apps/Tools", "Apps/Tools/test", "Work", "Work/file2", "Work/file10", "Work/Tests"]
        )
        #expect(tree.root.isScanned && tree.node(at: "Apps/Tools/test")?.isScanned == true)
        #expect(tree.node(at: "Apps/Tools/test")?.depth == 3 && tree.root.depth == 0)
        #expect(tree.node(at: "Nowhere") == nil)
        // Lines in any order and with missing parents still give one tree.
        let jumbled = DirectoryTree(rootURL: root, paths: ["b/c/d", "a", "b", "a/x", "b/c"])
        #expect(jumbled.paths == ["a", "a/x", "b", "b/c", "b/c/d"] && jumbled.count == 5)
    }

    /// Nodes know their paths and locations, and a location finds its node or the nearest one above it.
    @Test
    internal func pathsAndLocations() throws {
        let tree = sample()
        let node = try #require(tree.node(at: "Apps/Tools"))
        #expect(tree.relativePath(of: node) == "Apps/Tools" && tree.relativePath(of: tree.root).isEmpty)
        #expect(
            tree.url(of: node).path == "/Volumes/Disk/Apps/Tools" && tree.url(of: tree.root).path == "/Volumes/Disk"
        )
        #expect(tree.relativePath(of: URL(fileURLWithPath: "/Volumes/Disk/Work/Tests/")) == "Work/Tests")
        #expect(
            tree.relativePath(of: root)?.isEmpty == true
                && tree.relativePath(of: URL(fileURLWithPath: "/Volumes/Other")) == nil
        )
        #expect(tree.nearestNode(to: URL(fileURLWithPath: "/Volumes/Disk/Apps/Tools/new/deeper")) === node)
        #expect(tree.nearestNode(to: URL(fileURLWithPath: "/elsewhere")) == nil)
        let memory = MemoryFileSystem()
        #expect(DirectoryTree.relativePath(of: memory.url("/A/b c/d"), below: memory.url("/A")) == "b c/d")
        // Nodes refer to their parents weakly: the tree has to live as long as they are used.
        let spaced = DirectoryTree(rootURL: memory.url("/"), paths: ["A/b c"])
        #expect(spaced.node(at: "A/b c").map(spaced.url(of:)) == memory.url("/A/b c"))
    }

    /// Setting the children of a folder keeps the folders known below the ones that stay and drops the vanished ones.
    @Test
    internal func settingChildrenKeepsKnownFoldersAndDropsVanishedOnes() throws {
        let tree = DirectoryTree(rootURL: root)
        let known = try #require(tree.node(at: "Work/Deep/Deeper", creating: true))
        #expect(tree.count == 3 && !tree.root.isScanned && !known.isScanned)
        tree.setChildren(["Zeta", "Work", "alpha"], ofPath: "")
        #expect(tree.root.children.map(\.name) == ["alpha", "Work", "Zeta"] && tree.root.isScanned && tree.count == 5)
        #expect(tree.node(at: "Work/Deep/Deeper") === known)
        // A rescan that no longer finds a folder removes it with everything below.
        tree.setChildren(["Other"], ofPath: "Work")
        #expect(tree.count == 4 && tree.node(at: "Work/Deep") == nil)
        #expect(tree.setChildren(["x"], ofPath: "Work/Deep") == nil)
        #expect(tree.paths == ["alpha", "Work", "Work/Other", "Zeta"])
    }

    /// Stepping to the neighbours follows the order on screen and wraps around at the ends.
    @Test
    internal func neighboursFollowDisplayOrderAndWrapAround() {
        let tree = sample()
        var node = tree.root
        var forward: [String] = []
        for _ in 0..<8 {
            node = tree.neighbour(of: node, forward: true)
            forward.append(tree.relativePath(of: node))
        }
        #expect(forward == tree.paths + [""])
        var backward: [String] = []
        for _ in 0..<8 {
            node = tree.neighbour(of: node, forward: false)
            backward.append(tree.relativePath(of: node))
        }
        #expect(backward == Array(tree.paths.reversed()) + [""])
    }

    /// Quick search finds the next folder whose name starts with the text, with wildcards, either way round.
    @Test
    internal func quickSearchFindsTheNextFolderStartingWithTheText() {
        let tree = sample()
        func find(_ text: String, from path: String?, forward: Bool = true, includingStart: Bool = false) -> String? {
            tree.find(text, from: path.flatMap { tree.node(at: $0) }, forward: forward, includingStart: includingStart)
                .map(tree.relativePath(of:))
        }
        #expect(find("t", from: nil) == "Apps/Tools")
        #expect(find("t", from: "Apps/Tools") == "Apps/Tools/test")
        #expect(find("t", from: "Apps/Tools/test") == "Work/Tests")
        #expect(find("t", from: "Work/Tests") == "Apps/Tools")
        #expect(find("t", from: "Work/Tests", forward: false) == "Apps/Tools/test")
        // While typing, the folder under the cursor may stay the answer.
        #expect(find("to", from: "Apps/Tools", includingStart: true) == "Apps/Tools")
        #expect(find("te", from: "Apps/Tools", includingStart: true) == "Apps/Tools/test")
        #expect(find("*le1", from: nil) == "Work/file10")
        #expect(find("file?", from: "Work/file2") == "Work/file10")
        #expect(find("zzz", from: nil) == nil && find("", from: nil) == nil)
        #expect(DirectoryTree(rootURL: root).find("a", from: nil) == nil)
        #expect(
            TreeQuickSearch("*test").matches("test") && TreeQuickSearch("*test").matches("My Tests")
                && !TreeQuickSearch("test").matches("My Tests")
        )
    }

    /// The root of a location is the disk it is on, and the roots offered are the disks of the volume list.
    @Test
    internal func rootsFollowTheDisksOfTheVolumeList() {
        let home = URL(fileURLWithPath: "/Users/x")
        let places = [
            Place(name: "Home", url: home, kind: .home),
            Place(name: "Desktop", url: home.appending(name: "Desktop"), kind: .folder),
            Place(name: "Macintosh HD", url: URL(fileURLWithPath: "/"), kind: .internalDisk),
            Place(name: "Stick", url: URL(fileURLWithPath: "/Volumes/Stick"), kind: .externalDisk)
        ]
        let slash = URL(fileURLWithPath: "/")
        #expect(
            TreeRoots.root(for: URL(fileURLWithPath: "/Volumes/Stick/a/b"), places: places, providerRoot: slash).path
                == "/Volumes/Stick"
        )
        #expect(
            TreeRoots.root(for: URL(fileURLWithPath: "/Volumes/Stick"), places: places, providerRoot: slash).path
                == "/Volumes/Stick"
        )
        #expect(TreeRoots.root(for: home, places: places, providerRoot: slash).path == "/")
        let memory = MemoryFileSystem()
        #expect(TreeRoots.root(for: memory.url("/A"), places: [], providerRoot: memory.url("/")) == memory.url("/"))
        let choices = TreeRoots.choices(places: places, providerRoot: slash)
        #expect(choices.map(\.name) == ["Macintosh HD", "Home", "Stick"])
        #expect(TreeRoots.choices(places: [], providerRoot: memory.url("/")).map(\.url) == [memory.url("/")])
    }
}
