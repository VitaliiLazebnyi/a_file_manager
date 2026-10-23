import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The Directory Tree window: opening, reading, the cache, other roots, keys and quick search,
/// a scan that goes on without the window, and the result.
@MainActor
@Suite(.serialized)
internal struct CoveragePlacesTreeWindow {
    /// How long a scan goes on without its window when the test does not set a limit: longer
    /// than any test.
    internal static let longLimit: TimeInterval = 900

    /// The folders of the tree file system the tests read.
    internal let folders = CoveragePlacesFolders(["/A/a1/deep", "/A/a2", "/B/b1", "/Inner/x", "/Home/h", "/.hidden/in"])
    /// A second file system, for a root of another kind.
    internal let memory = MemoryFileSystem()
    /// The kernel with both file systems; the left panel shows `/A`, the right one `mem:/M`.
    internal let bench: TestBench
    /// How often a search found nothing: the window's sound, counted instead of played.
    internal let beeps = Shared(0)
    /// The windows the tree was asked to show: none is put on screen.
    internal let presenter = StabilityPresenter()

    /// The root of the tree file system.
    internal var root: URL { folders.url("/") }

    /// The kernel with the tree file system and the memory one.
    internal init() {
        _ = NSApplication.shared
        memory.addDirectory("/M/m1")
        bench = TestBench(plugins: [], fileSystems: [folders, memory], left: folders.url("/A"), right: memory.url("/M"))
    }

    /// A tree window on `cache` whose scans go on without it for `hiddenScanLimit` seconds; not
    /// shown yet.
    internal func window(cache: TreeCache, hiddenScanLimit: TimeInterval) -> CoveragePlacesTreeParts {
        let controller = DirectoryTreeWindowController(
            kernel: bench.kernel,
            cache: cache,
            hiddenScanLimit: hiddenScanLimit
        ) { [beeps] in
            beeps.modify { $0 += 1 }
        }
        controller.present = presenter.present
        return CoveragePlacesTreeParts(controller: controller)
    }

    /// A tree window on `cache` whose scans outlast every test; not shown yet.
    internal func window(cache: TreeCache) -> CoveragePlacesTreeParts {
        window(cache: cache, hiddenScanLimit: Self.longLimit)
    }

    /// Lets the main thread work until `condition` holds; false on a hang.
    internal func spin(_ condition: () -> Bool) async -> Bool {
        await RunLoopWait.until(condition)
    }

    /// Opens the window on `path` and waits until the tree is read.
    internal func opened(_ path: String, cache: TreeCache, showHidden: Bool) async -> CoveragePlacesTreeParts {
        let tree = window(cache: cache)
        tree.controller.show(for: folders.url(path), showHidden: showHidden)
        #expect(presenter.isOpen(tree.window))
        #expect(await spin { tree.isIdle })
        return tree
    }

    /// Opens the window on `path` with an empty cache, hidden folders left out, and waits until
    /// the tree is read.
    internal func opened(_ path: String) async -> CoveragePlacesTreeParts {
        await opened(path, cache: TreeCache(directory: nil), showHidden: false)
    }

    /// A key press as AppKit hands it to the window.
    internal func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try CoveragePlacesLoop.key(characters, code: code, modifiers: modifiers)
    }

    /// The window opens on the panel's folder, reads the tree around it, and offers every disk
    /// of every file system as a root.
    @Test
    internal func opensOnThePanelsFolderReadsTheTreeAndOffersEveryDisk() async {
        let cache = TreeCache(directory: nil)
        let tree = await opened("/A/a1", cache: cache, showHidden: false)
        defer { tree.controller.close() }
        #expect(
            tree.popup?.itemTitles == [
                "Tree  (tree:/)", "Inner  (tree:/Inner)", "Home  (tree:/Home)", "Memory  (mem:/)"
            ]
        )
        #expect(tree.popup?.indexOfSelectedItem == 0)
        #expect(tree.status == "9 directories")
        #expect(tree.rows == ["tree:/", "A", "a1", "a2", "B", "Home", "Inner"])
        #expect(tree.selected == "a1" && tree.path == "tree:/A/a1")
        // The disk mounted inside is listed and not read; the home folder is read.
        let entry = cache.entry(for: folders.url("/"))
        #expect(entry?.paths.contains("Home/h") == true && entry?.unscanned == ["Inner"] && entry?.isComplete == true)
        tree.controller.close()
    }

    /// Showing the window again for a folder of the same tree only moves the cursor; of two
    /// such requests in a row the later one wins.
    @Test
    internal func theSameTreeAgainOnlyMovesTheCursor() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        // Two in a row: the first answer comes too late and is dropped.
        tree.controller.show(for: folders.url("/A/a2"), showHidden: false)
        tree.controller.show(for: folders.url("/B"), showHidden: false)
        #expect(await spin { tree.selected == "B" })
        #expect(tree.status == "9 directories" && tree.path == "tree:/B")
        tree.controller.close()
    }

    /// A tree in the cache is shown without reading, with the panel's folder added to it.
    @Test
    internal func aStoredTreeOpensWithoutReading() async {
        let cache = TreeCache(directory: nil)
        cache.store(["A", "A/a1", "Z"], for: folders.url("/"), unscanned: ["Z"], isComplete: false)
        let tree = await opened("/A/a2", cache: cache, showHidden: false)
        defer { tree.controller.close() }
        // The folder the panel shows is added to what was stored.
        #expect(tree.rows == ["tree:/", "A", "a1", "a2", "Z"] && tree.selected == "a2")
        #expect(tree.status == "4 directories, incomplete: folders are read when opened, F2 reads the rest")
        tree.controller.close()
    }

    /// A disk without a name is offered by its path; a root no file system reads leaves the tree
    /// on screen, and a location of no file system opens no window.
    @Test
    internal func aDiskWithoutANameIsOfferedByItsPathAndAnUnknownPlaceIsNotRead() async throws {
        folders.placeList = [Place(name: "", url: try #require(URL(string: "nowhere:///disk")), kind: .externalDisk)]
        let tree = await opened("/A")
        defer { tree.controller.close() }
        #expect(tree.popup?.itemTitles.prefix(2) == ["tree:/", "nowhere:///disk"])
        // A place of a file system nobody offers cannot be read; the tree on screen stays.
        tree.chooseRoot(1)
        #expect(await spin { tree.status == "This disk cannot be read." })
        #expect(tree.rows.first == "tree:/")
        // A location of no file system opens nothing.
        let other = window(cache: TreeCache(directory: nil))
        defer { other.controller.close() }
        other.controller.show(for: try #require(URL(string: "nowhere:///x")), showHidden: false)
        #expect(!presenter.isOpen(other.window))
        tree.controller.close()
    }

    /// Choosing another root reads its tree; choosing none changes nothing, and of two choices
    /// in a row only the last is read.
    @Test
    internal func anotherRootIsReadAndAnInvalidChoiceIsIgnored() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        tree.chooseRoot(-1)
        #expect(tree.rows.first == "tree:/")
        // Two choices in a row: only the last is read.
        tree.chooseRoot(1)
        tree.chooseRoot(3)
        #expect(await spin { tree.isIdle && tree.rows.first == "mem:/" })
        #expect(tree.rows == ["mem:/", "M"] && tree.selected == "mem:/" && tree.status == "2 directories")
        tree.controller.close()
    }

    /// With hidden folders shown the tree is read and cached apart from the tree without them.
    @Test
    internal func hiddenFoldersMakeATreeOfTheirOwn() async {
        let cache = TreeCache(directory: nil)
        let tree = await opened("/A", cache: cache, showHidden: true)
        defer { tree.controller.close() }
        #expect(
            tree.rows.contains(".hidden")
                && cache.entry(for: folders.url("/"), showHidden: true)?.paths.contains(".hidden/in") == true
        )
        #expect(cache.entry(for: folders.url("/"))?.paths == nil)
        tree.controller.close()
    }

    /// F2, Control-R in the list and the Rescan button read the tree again, whether the cursor
    /// is on a folder or nowhere; other keys go their usual way.
    @Test
    internal func rescanKeysReadTheTreeAgainWhereverTheFocusIs() async throws {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        guard let window = tree.window else {
            return
        }
        // Before a rescan: a folder appears, one goes away.
        folders.add("/A/a1/new")
        folders.remove("/B")
        window.keyDown(with: try key("\u{F705}", 120, []))
        #expect(!tree.isIdle)
        #expect(await spin { tree.isIdle })
        #expect(tree.rows == ["tree:/", "A", "a1", "a2", "Home", "Inner"] && tree.status == "8 directories")
        #expect(tree.selected == "a1")
        // Control-R in the list, and the button, with the cursor nowhere: from the root.
        tree.outline?.deselectAll(nil)
        try tree.press("r", code: 15, .control)
        #expect(await spin { tree.isIdle })
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.isIdle })
        // Other keys go their usual way.
        window.keyDown(with: try key("x", 7, []))
        tree.controller.close()
    }

    /// A window that has shown no tree has nothing to rescan and nothing for Esc to stop.
    @Test
    internal func aWindowWithoutATreeHasNothingToRescan() {
        let tree = window(cache: TreeCache(directory: nil))
        defer { tree.controller.close() }
        tree.click("F2 Rescan Tree")
        #expect(tree.status.isEmpty && tree.rows.isEmpty)
        #expect(!tree.escape())
    }

    /// When the folder under the cursor is gone in a rescan, the cursor goes elsewhere.
    @Test
    internal func theCursorsFolderGoneInARescanLeavesTheCursorElsewhere() async {
        let tree = await opened("/B")
        defer { tree.controller.close() }
        #expect(tree.selected == "B")
        folders.remove("/B")
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.isIdle })
        #expect(!tree.rows.contains("B") && tree.status == "7 directories")
    }
}
