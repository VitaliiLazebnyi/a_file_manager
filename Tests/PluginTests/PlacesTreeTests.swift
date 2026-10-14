import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The directory tree as a model: filling, paths and quick search.
@Suite struct PlacesTreeModel {
    let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)

    func sample() -> DirectoryTree {
        DirectoryTree(
            rootURL: root,
            paths: ["Apps", "Apps/Tools", "Apps/Tools/test", "Work", "Work/file10", "Work/file2", "Work/Tests"])
    }

    @Test func buildsFromCachedPathsInNaturalOrder() {
        let tree = sample()
        #expect(tree.count == 7)
        #expect(tree.root.children.map(\.name) == ["Apps", "Work"])
        #expect(tree.node(at: "Work")?.children.map(\.name) == ["file2", "file10", "Tests"])
        #expect(
            tree.paths == ["Apps", "Apps/Tools", "Apps/Tools/test", "Work", "Work/file2", "Work/file10", "Work/Tests"])
        #expect(tree.root.isScanned && tree.node(at: "Apps/Tools/test")?.isScanned == true)
        #expect(tree.node(at: "Apps/Tools/test")?.depth == 3 && tree.root.depth == 0)
        #expect(tree.node(at: "Nowhere") == nil)
        // Lines in any order and with missing parents still give one tree.
        let jumbled = DirectoryTree(rootURL: root, paths: ["b/c/d", "a", "b", "a/x", "b/c"])
        #expect(jumbled.paths == ["a", "a/x", "b", "b/c", "b/c/d"] && jumbled.count == 5)
    }

    @Test func pathsAndLocations() throws {
        let tree = sample()
        let node = try #require(tree.node(at: "Apps/Tools"))
        #expect(tree.relativePath(of: node) == "Apps/Tools" && tree.relativePath(of: tree.root) == "")
        #expect(
            tree.url(of: node).path == "/Volumes/Disk/Apps/Tools" && tree.url(of: tree.root).path == "/Volumes/Disk")
        #expect(tree.relativePath(of: URL(fileURLWithPath: "/Volumes/Disk/Work/Tests/")) == "Work/Tests")
        #expect(
            tree.relativePath(of: root) == "" && tree.relativePath(of: URL(fileURLWithPath: "/Volumes/Other")) == nil)
        #expect(tree.nearestNode(to: URL(fileURLWithPath: "/Volumes/Disk/Apps/Tools/new/deeper")) === node)
        #expect(tree.nearestNode(to: URL(fileURLWithPath: "/elsewhere")) == nil)
        let memory = MemoryFileSystem()
        #expect(DirectoryTree.relativePath(of: memory.url("/A/b c/d"), below: memory.url("/A")) == "b c/d")
        // Nodes refer to their parents weakly: the tree has to live as long as they are used.
        let spaced = DirectoryTree(rootURL: memory.url("/"), paths: ["A/b c"])
        #expect(spaced.node(at: "A/b c").map(spaced.url(of:)) == memory.url("/A/b c"))
    }

    @Test func settingChildrenKeepsKnownFoldersAndDropsVanishedOnes() throws {
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

    @Test func neighboursFollowDisplayOrderAndWrapAround() {
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

    @Test func quickSearchFindsTheNextFolderStartingWithTheText() {
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
                && !TreeQuickSearch("test").matches("My Tests"))
    }

    @Test func rootsFollowTheDisksOfTheVolumeList() {
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
                == "/Volumes/Stick")
        #expect(
            TreeRoots.root(for: URL(fileURLWithPath: "/Volumes/Stick"), places: places, providerRoot: slash).path
                == "/Volumes/Stick")
        #expect(TreeRoots.root(for: home, places: places, providerRoot: slash).path == "/")
        let memory = MemoryFileSystem()
        #expect(TreeRoots.root(for: memory.url("/A"), places: [], providerRoot: memory.url("/")) == memory.url("/"))
        let choices = TreeRoots.choices(places: places, providerRoot: slash)
        #expect(choices.map(\.name) == ["Macintosh HD", "Home", "Stick"])
        #expect(TreeRoots.choices(places: [], providerRoot: memory.url("/")).map(\.url) == [memory.url("/")])
    }
}

/// Reading trees from file systems and keeping them: these run on several threads.
@Suite struct PlacesTreeScanning {
    let memory = MemoryFileSystem()

    /// Runs a scan and puts what it delivers into a tree.
    func scan(_ scanner: TreeScanner, root: URL) -> (tree: DirectoryTree, completed: Bool, batches: Int) {
        let tree = DirectoryTree(rootURL: root)
        var batches = 0
        let completed = scanner.run { levels in
            batches += 1
            for level in levels { tree.setChildren(level.children, ofPath: level.path) }
        }
        return (tree, completed, batches)
    }

    @Test func scansFoldersOnlyLevelByLevel() {
        memory.addFile("/V/a/file.txt")
        memory.addFile("/V/a/b/c/deep.txt")
        memory.addDirectory("/V/z")
        memory.addDirectory("/V/.hidden/inside")
        var order: [String] = []
        let scanner = TreeScanner(root: memory.url("/V"), provider: memory, batchSize: 1)
        #expect(scanner.run { levels in order += levels.map(\.path) })
        #expect(order == ["", "a", "z", "a/b", "a/b/c"])
        let result = scan(TreeScanner(root: memory.url("/V"), provider: memory), root: memory.url("/V"))
        #expect(result.completed && result.tree.paths == ["a", "a/b", "a/b/c", "z"])
        #expect(result.tree.node(at: "a/b/c")?.isScanned == true)
        let withHidden = scan(
            TreeScanner(root: memory.url("/V"), provider: memory, showHidden: true), root: memory.url("/V"))
        #expect(withHidden.tree.paths == [".hidden", ".hidden/inside", "a", "a/b", "a/b/c", "z"])
    }

    @Test func excludedFoldersAreListedButNotRead() {
        memory.addDirectory("/V/Volumes/Other/deep")
        memory.addDirectory("/V/keep/inner")
        let excluded = memory.url("/V/Volumes").locationKey
        let result = scan(
            TreeScanner(root: memory.url("/V"), provider: memory) { $0.locationKey == excluded },
            root: memory.url("/V"))
        #expect(result.tree.paths == ["keep", "keep/inner", "Volumes"])
        #expect(result.tree.node(at: "Volumes")?.isScanned == false && result.tree.node(at: "keep")?.isScanned == true)
        #expect(memory.listRequests(for: "/V/Volumes") == 0)
    }

    @Test func wideTreesAreReadInBatches() {
        for folder in 0..<300 {
            for sub in 0..<3 { memory.addDirectory("/W/d\(folder)/s\(sub)") }
        }
        memory.listBatchDelay = 0.001
        memory.listBatchSize = 1
        let result = scan(
            TreeScanner(root: memory.url("/W"), provider: memory, batchSize: 64), root: memory.url("/W"))
        #expect(result.completed && result.tree.count == 1_200)
        #expect(
            result.tree.root.children.count == 300
                && result.tree.node(at: "d10")?.children.map(\.name) == ["s0", "s1", "s2"])
        // One call for the root, five for the 300 folders, and so on: results come in batches.
        #expect(result.batches > 5)
        // Whether the folders of a batch were really read side by side depends on how many
        // threads the system has to spare, which other tests running at the same time use up;
        // `Concurrency.parallelMapUsesSeveralThreads` in the kernel tests checks that part alone.
    }

    @Test func cancellingStopsTheScan() {
        for folder in 0..<50 { memory.addDirectory("/C/d\(folder)/sub/deeper") }
        let scanner = TreeScanner(root: memory.url("/C"), provider: memory, batchSize: 10)
        var received = 0
        let completed = scanner.run { _ in
            received += 1
            scanner.cancellation.cancel()
        }
        #expect(!completed && received == 1)
        #expect(scanner.subfolders(of: memory.url("/C")).isEmpty)

        // Cancelled from another thread while it runs.
        memory.listBatchDelay = 0.02
        memory.listBatchSize = 1
        let second = TreeScanner(root: memory.url("/C"), provider: memory, batchSize: 4)
        // A thread of its own: the shared queues may be busy with other tests.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.02)
            second.cancellation.cancel()
        }
        #expect(!second.run { _ in })
    }

    @Test func unreadableFoldersCountAsEmptyAndLinksAndPackagesAreLeftOut() throws {
        let box = try Sandbox()
        try box.folder("real/inner")
        try box.folder("Some.app/Contents")
        try box.file("real/file.txt")
        try FileManager.default.createSymbolicLink(at: box.url("link"), withDestinationURL: box.url("real"))
        try box.folder("locked/secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.url("locked").path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.url("locked").path)
        }
        let result = scan(TreeScanner(root: box.root, provider: LocalFileSystem()), root: box.root)
        #expect(result.completed && result.tree.paths == ["locked", "real", "real/inner"])
    }

    // MARK: Cache

    @Test func cacheKeepsTreesInMemoryAndInFilesOfItsOwnFolder() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = memory.url("/V")
        #expect(cache.paths(for: root) == nil)
        cache.store(["a", "a/b c", "z"], for: root)
        #expect(cache.paths(for: root) == ["a", "a/b c", "z"])
        let file = try #require(cache.fileURL(for: root))
        #expect(file.deletingLastPathComponent() == box.url("cache"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "root=mem:///V\n[a]\n[a/b c]\n[z]\n")
        // Another root has another file, even when the names look alike.
        #expect(
            cache.fileURL(for: memory.url("/V_"))?.lastPathComponent
                != cache.fileURL(for: memory.url("/V/"))?.lastPathComponent)
        #expect(cache.fileURL(for: memory.url("/V/")) == file)
        #expect(cache.paths(for: memory.url("/other")) == nil)

        // A new cache, as after a restart, reads the file.
        let restarted = TreeCache(directory: box.url("cache"))
        #expect(restarted.paths(for: root) == ["a", "a/b c", "z"])
        restarted.remove(for: root)
        #expect(restarted.paths(for: root) == nil && !FileManager.default.fileExists(atPath: file.path))
        #expect(TreeCache(directory: box.url("cache")).paths(for: root) == nil)
    }

    @Test func cacheWithoutFolderStaysInMemory() {
        let cache = TreeCache(directory: nil)
        cache.store(["a"], for: memory.url("/"))
        #expect(cache.paths(for: memory.url("/")) == ["a"] && cache.fileURL(for: memory.url("/")) == nil)
    }

    @Test func cacheFilesOfOtherRootsAndBrokenFilesAreNotTaken() {
        let root = memory.url("/V")
        #expect(TreeCache.parse("root=mem:///V\n[a]\n\ngarbage\n[]\n[b/c]\n", root: root) == ["a", "b/c"])
        #expect(TreeCache.parse("root=mem:///elsewhere\n[a]\n", root: root) == nil)
        #expect(TreeCache.parse("[a]\n[b]\n", root: root) == nil && TreeCache.parse("", root: root) == nil)
        #expect(TreeCache.parse(TreeCache.format([], root: root), root: root) == [])
    }

    @Test func cacheLearnsFoldersThePanelsShow() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = memory.url("/")
        // Nothing is noted for a tree that was never read.
        cache.noteFolder("x/y", below: root)
        cache.waitForUpdates()
        #expect(cache.paths(for: root) == nil)
        cache.store(["a", "a/b"], for: root)
        cache.noteFolder("a/b", below: root)
        cache.noteFolder("a/new/deeper", below: root)
        cache.noteFolder("", below: root)
        cache.waitForUpdates()
        #expect(cache.paths(for: root) == ["a", "a/b", "a/new", "a/new/deeper"])
        #expect(TreeCache(directory: box.url("cache")).paths(for: root) == ["a", "a/b", "a/new", "a/new/deeper"])
        #expect(
            DirectoryTree(rootURL: root, paths: cache.paths(for: root) ?? []).paths == [
                "a", "a/b", "a/new", "a/new/deeper"
            ])
    }

    @Test func cacheIsSafeToUseFromManyThreads() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let roots = (0..<4).map { memory.url("/r\($0)") }
        roots.forEach { cache.store(["base"], for: $0) }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let root = roots[index % roots.count]
            switch index % 3 {
            case 0: cache.noteFolder("base/n\(index)", below: root)
            case 1: _ = cache.paths(for: root)
            default: cache.store((cache.paths(for: root) ?? []) + ["s\(index)"], for: root)
            }
        }
        cache.waitForUpdates()
        for root in roots {
            let paths = try #require(cache.paths(for: root))
            #expect(Set(paths).count == paths.count)
            #expect(TreeCache(directory: box.url("cache")).paths(for: root).map(Set.init) == Set(paths))
        }
    }

    @MainActor @Test func pluginTellsTheCacheAboutVisitedFoldersWithoutTouchingRealFolders() throws {
        let box = try Sandbox()
        memory.addDirectory("/A/new")
        memory.addDirectory("/B")
        let plugin = PlacesPlugin(treeCacheDirectory: box.url("trees"), favorites: [])
        let bench = TestBench(
            plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
        // A tree that was never read learns nothing; nothing is written for it either.
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        plugin.treeCache.waitForUpdates()
        #expect(namesOnDisk(box.url("trees")).isEmpty)
        plugin.treeCache.store(["A", "B"], for: memory.url("/"))
        bench.left.show(memory.url("/A/new"))
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        plugin.treeCache.waitForUpdates()
        #expect(plugin.treeCache.paths(for: memory.url("/")) == ["A", "B", "A/new"])
        #expect(TreeCache(directory: box.url("trees")).paths(for: memory.url("/")) == ["A", "B", "A/new"])
        #expect(namesOnDisk(box.url("trees")).count == 1)
    }
}
