import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// Scans of the tree window: stopped with Esc, going on without the window, ended by a limit,
/// by quitting or by another root, and scans of very wide folders.
extension CoveragePlacesTreeWindow {
    /// Esc stops a scan: the results that come after it are stored as incomplete and never
    /// reach the window.
    @Test
    internal func escStopsAScanWhoseLateResultsAreDropped() async {
        let cache = TreeCache(directory: nil)
        folders.hold("/B")
        folders.hold("/A/a1")
        let tree = window(cache: cache)
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { folders.isWaiting("/B") && tree.rows.contains("B") })
        // The same folder again while the scan runs: the cursor moves, the scan goes on.
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { tree.status == "Reading directories… (Esc to abort)" })
        // The next level is read and handed over; before the window takes it, Esc.
        folders.release("/B")
        #expect(Wait.until { folders.isWaiting("/A/a1") })
        #expect(tree.escape())
        #expect(tree.status == "4 directories, reading aborted")
        await CoveragePlacesLoop.settle()
        folders.release("/A/a1")
        // What was read is stored as incomplete; nothing of it reaches the window any more.
        #expect(await spin { cache.entry(for: root)?.isComplete == false })
        await CoveragePlacesLoop.settle()
        #expect(tree.status == "4 directories, reading aborted" && !tree.rows.contains("a2"))
        // Closing now leaves the tree: it is not in the cache as it is shown.
        tree.controller.close()
        #expect(tree.rows.count > 1)
    }

    /// The scan of a closed window goes on until its limit and then stops, keeping what it read
    /// as incomplete.
    @Test
    internal func aClosedWindowsScanGoesOnUntilItsLimit() async {
        let cache = TreeCache(directory: nil)
        folders.hold("/B")
        let tree = window(cache: cache, hiddenScanLimit: 0.05)
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { folders.isWaiting("/B") && tree.rows.contains("B") })
        tree.controller.close()
        #expect(await spin { tree.status == "4 directories, reading aborted" })
        folders.release("/B")
        #expect(await spin { cache.entry(for: root)?.isComplete == false })
    }

    /// A scan that ends after its window closed stores the whole tree, which the window shows
    /// from the cache when it opens again.
    @Test
    internal func aScanThatEndsWithoutTheWindowLeavesTheTreeToTheCache() async {
        let cache = TreeCache(directory: nil)
        folders.hold("/B")
        let tree = window(cache: cache)
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { folders.isWaiting("/B") })
        tree.controller.close()
        folders.release("/B")
        // The tree is filled without the window and let go when the scan has stored it.
        #expect(await spin { cache.entry(for: root)?.isComplete == true && tree.rows.isEmpty })
        // Back from the cache.
        tree.controller.show(for: folders.url("/A/a1"), showHidden: false)
        #expect(tree.status == "Reading the directory tree…")
        #expect(await spin { tree.isIdle && tree.selected == "a1" })
        // A window that closes a second time has nothing more to let go of.
        tree.controller.close()
        tree.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(tree.rows.isEmpty)
    }

    /// A limit that ends after the window came back leaves the scan running.
    @Test
    internal func aLimitThatEndsAfterTheWindowCameBackDoesNothing() async {
        folders.hold("/B")
        let tree = window(cache: TreeCache(directory: nil), hiddenScanLimit: 0.05)
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { folders.isWaiting("/B") })
        tree.controller.close()
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        // A block of the main queue due after the limit's: when it has run, so has the limit's.
        let passed = Shared(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { passed.value = true }
        #expect(await spin { passed.value })
        #expect(tree.status.hasPrefix("Reading directories"))
        folders.release("/B")
        #expect(await spin { tree.isIdle })
        tree.controller.close()
    }

    /// Quitting closes the window and ends its scan, which stores what it read as incomplete.
    @Test
    internal func quittingEndsAScanWithoutAWindow() async {
        let cache = TreeCache(directory: nil)
        folders.hold("/B")
        let tree = window(cache: cache)
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { folders.isWaiting("/B") })
        tree.controller.shutDown()
        #expect(!presenter.isOpen(tree.window))
        folders.release("/B")
        #expect(await spin { cache.entry(for: root)?.isComplete == false })
        // The tree stays: what it showed was not stored as it is.
        #expect(tree.rows.count > 1)
    }

    /// Another root chosen while a scan runs replaces it once the old scan has given up.
    @Test
    internal func anotherRootWhileReadingReplacesTheScan() async {
        let cache = TreeCache(directory: nil)
        folders.hold("/B")
        let tree = window(cache: cache)
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/A"), showHidden: false)
        #expect(await spin { folders.isWaiting("/B") })
        tree.chooseRoot(3)
        // Scans run one after the other: the new one starts when the old one has given up.
        folders.release("/B")
        #expect(await spin { tree.isIdle && tree.rows.first == "mem:/" })
        #expect(tree.rows == ["mem:/", "M"])
        tree.controller.close()
    }

    /// A folder of very many subfolders is linked into the tree in turns, and a rescan keeps
    /// the cursor on it.
    @Test
    internal func aFolderOfManySubfoldersIsLinkedInTurns() async {
        folders.add("/W")
        folders.addMany(30_000, below: "/W")
        let cache = TreeCache(directory: nil)
        let tree = await opened("/W", cache: cache, showHidden: false)
        defer { tree.controller.close() }
        #expect(cache.entry(for: root)?.paths.count == 30_010)
        expand("W", in: tree)
        #expect(tree.rows.count > 30_000)
        // Read again: the folders known to be empty lose their triangles where they are on screen.
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.isIdle })
        #expect(tree.rows.count > 30_000 && tree.selected == "W")
    }

    /// Esc while the folders of a huge level wait to be linked drops them: the tree stays as it
    /// was when Esc came.
    @Test
    internal func escWhileManyFoldersWaitDropsTheRest() async {
        folders.add("/W")
        folders.addMany(300_000, below: "/W")
        let tree = window(cache: TreeCache(directory: nil))
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/W"), showHidden: false)
        // The big folder is being linked, a part in each turn of the main thread.
        #expect(await spin { tree.status.hasPrefix("Reading directories:") && tree.count > 50_000 })
        #expect(tree.escape())
        // What waited is dropped: the tree stays as it was when Esc came.
        #expect(await spin { tree.status.hasSuffix("F2 reads the rest") })
        #expect(tree.count < 300_000)
    }

    /// The tree of the start-up disk is read without the volumes mounted inside it.
    @Test
    internal func theStartUpDiskLeavesOutTheVolumesMountedInIt() async throws {
        let box = try Sandbox()
        let local = TestBench(plugins: [], fileSystems: [LocalFileSystem()], left: box.root, right: box.root)
        let controller = DirectoryTreeWindowController(
            kernel: local.kernel,
            cache: TreeCache(directory: nil),
            hiddenScanLimit: Self.longLimit
        ) {
            // No search is made: nothing to sound.
        }
        controller.present = presenter.present
        let tree = CoveragePlacesTreeParts(controller: controller)
        defer { tree.controller.close() }
        tree.controller.show(for: box.root, showHidden: false)
        // The first levels are read (and the folders mounted inside left out) before Esc.
        #expect(await spin { tree.count > 40 })
        #expect(tree.escape())
    }
}
