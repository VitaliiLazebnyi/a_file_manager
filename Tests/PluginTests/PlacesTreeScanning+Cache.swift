import AFMKernel
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The tree cache: trees kept in memory and in files, learnt from the panels, used from many
/// threads.
extension PlacesTreeScanning {
    /// The cache keeps trees in memory and in a file for each root in its own folder, and reads them back after
    /// a restart.
    @Test
    internal func cacheKeepsTreesInMemoryAndInFilesOfItsOwnFolder() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = memory.url("/V")
        #expect(cache.entry(for: root)?.paths == nil)
        cache.store(["a", "a/b c", "z"], for: root)
        #expect(cache.entry(for: root)?.paths == ["a", "a/b c", "z"])
        let file = try #require(cache.fileURL(for: root))
        #expect(file.deletingLastPathComponent() == box.url("cache"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "root=mem:///V\n[a]\n[a/b c]\n[z]\n")
        // Another root has another file, even when the names look alike.
        #expect(
            cache.fileURL(for: memory.url("/V_"))?.lastPathComponent
                != cache.fileURL(for: memory.url("/V/"))?.lastPathComponent
        )
        #expect(cache.fileURL(for: memory.url("/V/")) == file)
        #expect(cache.entry(for: memory.url("/other"))?.paths == nil)

        // A new cache, as after a restart, reads the file.
        let restarted = TreeCache(directory: box.url("cache"))
        #expect(restarted.entry(for: root)?.paths == ["a", "a/b c", "z"])
        restarted.remove(for: root)
        #expect(restarted.entry(for: root)?.paths == nil && !FileManager.default.fileExists(atPath: file.path))
        #expect(TreeCache(directory: box.url("cache")).entry(for: root)?.paths == nil)
    }

    /// A cache without a folder keeps its trees in memory only.
    @Test
    internal func cacheWithoutFolderStaysInMemory() {
        let cache = TreeCache(directory: nil)
        cache.store(["a"], for: memory.url("/"))
        #expect(cache.entry(for: memory.url("/"))?.paths == ["a"] && cache.fileURL(for: memory.url("/")) == nil)
    }

    /// A file of another root, or one without its root line, is not taken; bad lines are skipped.
    @Test
    internal func cacheFilesOfOtherRootsAndBrokenFilesAreNotTaken() {
        let root = memory.url("/V")
        #expect(TreeCache.parseEntry("root=mem:///V\n[a]\n\ngarbage\n[]\n[b/c]\n", root: root)?.paths == ["a", "b/c"])
        #expect(TreeCache.parseEntry("root=mem:///elsewhere\n[a]\n", root: root)?.paths == nil)
        #expect(
            TreeCache.parseEntry("[a]\n[b]\n", root: root)?.paths == nil
                && TreeCache.parseEntry("", root: root)?.paths == nil
        )
        #expect(TreeCache.parseEntry(TreeCache.format([], root: root), root: root)?.paths.isEmpty == true)
    }

    /// The cache learns the folders the panels show, below a tree that was read.
    @Test
    internal func cacheLearnsFoldersThePanelsShow() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let root = memory.url("/")
        // Nothing is noted for a tree that was never read.
        cache.noteFolder("x/y", below: root)
        cache.waitForUpdates()
        #expect(cache.entry(for: root)?.paths == nil)
        cache.store(["a", "a/b"], for: root)
        cache.noteFolder("a/b", below: root)
        cache.noteFolder("a/new/deeper", below: root)
        cache.noteFolder("", below: root)
        cache.waitForUpdates()
        #expect(cache.entry(for: root)?.paths == ["a", "a/b", "a/new", "a/new/deeper"])
        #expect(TreeCache(directory: box.url("cache")).entry(for: root)?.paths == ["a", "a/b", "a/new", "a/new/deeper"])
        #expect(
            DirectoryTree(rootURL: root, paths: cache.entry(for: root)?.paths ?? []).paths == [
                "a", "a/b", "a/new", "a/new/deeper"
            ]
        )
    }

    /// The cache can be used from many threads at once and stays consistent.
    @Test
    internal func cacheIsSafeToUseFromManyThreads() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        let roots = (0..<4).map { memory.url("/r\($0)") }
        for root in roots {
            cache.store(["base"], for: root)
        }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let root = roots[index % roots.count]
            switch index % 3 {
            case 0:
                cache.noteFolder("base/n\(index)", below: root)

            case 1:
                _ = cache.entry(for: root)?.paths

            default:
                cache.store((cache.entry(for: root)?.paths ?? []) + ["s\(index)"], for: root)
            }
        }
        cache.waitForUpdates()
        for root in roots {
            let paths = try #require(cache.entry(for: root)?.paths)
            #expect(Set(paths).count == paths.count)
            #expect((TreeCache(directory: box.url("cache")).entry(for: root)?.paths).map(Set.init) == Set(paths))
        }
    }

    /// The plugin tells the cache of the folders the panels visit, and writes nothing for a tree never read.
    @MainActor
    @Test
    internal func pluginTellsTheCacheAboutVisitedFoldersWithoutTouchingRealFolders() throws {
        let box = try Sandbox()
        memory.addDirectory("/A/new")
        memory.addDirectory("/B")
        let plugin = PlacesPlugin(treeCacheDirectory: box.url("trees"), favorites: [])
        let bench = TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url("/A"),
            right: memory.url("/B")
        )
        // A tree that was never read learns nothing; nothing is written for it either.
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        plugin.treeCache.waitForUpdates()
        #expect(namesOnDisk(box.url("trees")).isEmpty)
        plugin.treeCache.store(["A", "B"], for: memory.url("/"))
        bench.left.show(memory.url("/A/new"))
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        plugin.treeCache.waitForUpdates()
        #expect(plugin.treeCache.entry(for: memory.url("/"))?.paths == ["A", "B", "A/new"])
        #expect(TreeCache(directory: box.url("trees")).entry(for: memory.url("/"))?.paths == ["A", "B", "A/new"])
        #expect(namesOnDisk(box.url("trees")).count == 1)
    }
}
