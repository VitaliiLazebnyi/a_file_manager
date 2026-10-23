import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The cache: keyed by the hidden flag, partial trees, unscanned folders, debounced writes.
@Suite
internal struct ConfigPlacesFixCache {
    /// The root whose trees are stored.
    internal let root = URL(fileURLWithPath: "/Volumes/Disk", isDirectory: true)

    /// The trees with and without hidden folders are stored apart, and a hidden folder is noted in its tree only.
    @Test
    internal func hiddenAndVisibleTreesAreSeparate() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["a"], for: root)
        cache.store([".h", "a"], for: root, showHidden: true)
        #expect(
            cache.entry(for: root)?.paths == ["a"] && cache.entry(for: root, showHidden: true)?.paths == [".h", "a"]
        )
        #expect(TreeCache(directory: box.url("cache")).entry(for: root, showHidden: true)?.paths == [".h", "a"])
        // A hidden folder is noted in the hidden tree only.
        cache.noteFolder("a/.git", below: root)
        cache.waitForUpdates()
        #expect(
            cache.entry(for: root)?.paths == ["a"]
                && cache.entry(for: root, showHidden: true)?.paths == [".h", "a", "a/.git"]
        )
        cache.remove(for: root)
        #expect(cache.entry(for: root)?.paths == nil && cache.entry(for: root, showHidden: true)?.paths == nil)
    }

    /// Unread folders and an incomplete tree are read back from the file as they were stored.
    @Test
    internal func unscannedAndPartialSurviveTheFile() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["a", "a/b", "Volumes"], for: root, unscanned: ["Volumes", "a/b"], isComplete: false)
        let restarted = TreeCache(directory: box.url("cache")).entry(for: root)
        #expect(
            restarted
                == TreeCache.Entry(paths: ["a", "a/b", "Volumes"], unscanned: ["Volumes", "a/b"], isComplete: false)
        )
        #expect(TreeCache.parseEntry("root=file:///Volumes/Disk/\n[a]\n(a)\n", root: root)?.paths == ["a"])
    }

    /// Folders noted in a burst are written once, after a delay or when asked for.
    @Test
    internal func notedFoldersAreWrittenOnceAfterABurst() throws {
        let box = try Sandbox()
        let cache = TreeCache(directory: box.url("cache"))
        cache.store(["base"], for: root)
        let file = try #require(cache.fileURL(for: root))
        let before = try Data(contentsOf: file)
        for index in 0..<200 { cache.noteFolder("base/n\(index)", below: root) }
        // The caller returned at once; nothing is written until the delay is over or it is asked for.
        #expect(try Data(contentsOf: file) == before)
        cache.waitForUpdates()
        #expect(cache.entry(for: root)?.paths.count == 201)
        #expect(TreeCache(directory: box.url("cache")).entry(for: root)?.paths.count == 201)
    }
}
