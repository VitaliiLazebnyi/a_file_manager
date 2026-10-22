import AFMContracts
import AFMKernel
import AFMShell
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import PlacesPlugin

/// The Directory Tree window: opening, reading, the cache, other roots, keys and quick search,
/// a scan that goes on without the window, and the result.
@MainActor @Suite(.serialized) struct CoveragePlacesTreeWindow {
    let folders = CoveragePlacesFolders(["/A/a1/deep", "/A/a2", "/B/b1", "/Inner/x", "/Home/h", "/.hidden/in"])
    let memory = MemoryFileSystem()
    let bench: TestBench
    /// How often a search found nothing: the window's sound, counted instead of played.
    let beeps = Shared(0)
    /// The windows the tree was asked to show: none is put on screen.
    let presenter = StabilityPresenter()

    init() {
        _ = NSApplication.shared
        memory.addDirectory("/M/m1")
        bench = TestBench(plugins: [], fileSystems: [folders, memory], left: folders.url("/A"), right: memory.url("/M"))
    }

    func window(cache: TreeCache = TreeCache(directory: nil), hiddenScanLimit: TimeInterval = 900)
        -> CoveragePlacesTreeParts
    {
        let controller = DirectoryTreeWindowController(
            kernel: bench.kernel,
            cache: cache,
            hiddenScanLimit: hiddenScanLimit,
            beep: { [beeps] in beeps.modify { $0 += 1 } }
        )
        controller.present = presenter.present
        return CoveragePlacesTreeParts(controller: controller)
    }

    func spin(_ condition: () -> Bool) async -> Bool {
        await CoveragePlacesLoop.spin(until: condition)
    }

    /// Opens the window on `path` and waits until the tree is read.
    func opened(_ path: String, cache: TreeCache = TreeCache(directory: nil), showHidden: Bool = false) async
        -> CoveragePlacesTreeParts
    {
        let tree = window(cache: cache)
        tree.controller.show(for: folders.url(path), showHidden: showHidden)
        #expect(presenter.isOpen(tree.window))
        #expect(await spin { tree.isIdle })
        return tree
    }

    @Test func opensOnThePanelsFolderReadsTheTreeAndOffersEveryDisk() async {
        let cache = TreeCache(directory: nil)
        let tree = await opened("/A/a1", cache: cache)
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

    @Test func theSameTreeAgainOnlyMovesTheCursor() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        // Two in a row: the first answer comes too late and is dropped.
        tree.controller.show(for: folders.url("/A/a2"), showHidden: false)
        tree.controller.show(for: folders.url("/B"), showHidden: false)
        #expect(await spin { tree.selected == "B" })
        #expect(tree.status == "9 directories" && tree.path == "tree:/B")
        tree.controller.close()
    }

    @Test func aStoredTreeOpensWithoutReading() async {
        let cache = TreeCache(directory: nil)
        cache.store(["A", "A/a1", "Z"], unscanned: ["Z"], isComplete: false, for: folders.url("/"))
        let tree = await opened("/A/a2", cache: cache)
        defer { tree.controller.close() }
        // The folder the panel shows is added to what was stored.
        #expect(tree.rows == ["tree:/", "A", "a1", "a2", "Z"] && tree.selected == "a2")
        #expect(tree.status == "4 directories, incomplete: folders are read when opened, F2 reads the rest")
        tree.controller.close()
    }

    func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        CoveragePlacesLoop.key(characters, code: code, modifiers: modifiers)
    }

    @Test func aDiskWithoutANameIsOfferedByItsPathAndAnUnknownPlaceIsNotRead() async throws {
        folders.placeList = [Place(name: "", url: try #require(URL(string: "nowhere:///disk")), kind: .externalDisk)]
        let tree = await opened("/A")
        defer { tree.controller.close() }
        #expect(tree.popup?.itemTitles.prefix(2) == ["tree:/", "nowhere:///disk"])
        // A place of a file system nobody offers cannot be read; the tree on screen stays.
        tree.chooseRoot(1)
        #expect(await spin { tree.status == "This disk cannot be read." })
        #expect(tree.rows.first == "tree:/")
        // A location of no file system opens nothing.
        let other = window()
        defer { other.controller.close() }
        other.controller.show(for: try #require(URL(string: "nowhere:///x")), showHidden: false)
        #expect(!presenter.isOpen(other.window))
        tree.controller.close()
    }

    @Test func anotherRootIsReadAndAnInvalidChoiceIsIgnored() async {
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

    @Test func hiddenFoldersMakeATreeOfTheirOwn() async {
        let cache = TreeCache(directory: nil)
        let tree = await opened("/A", cache: cache, showHidden: true)
        defer { tree.controller.close() }
        #expect(
            tree.rows.contains(".hidden")
                && cache.paths(for: folders.url("/"), showHidden: true)?.contains(".hidden/in") == true
        )
        #expect(cache.paths(for: folders.url("/")) == nil)
        tree.controller.close()
    }

    @Test func rescanKeysReadTheTreeAgainWhereverTheFocusIs() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        guard let window = tree.window else {
            return
        }
        // Before a rescan: a folder appears, one goes away.
        folders.add("/A/a1/new")
        folders.remove("/B")
        window.keyDown(with: key("\u{F705}", 120))
        #expect(!tree.isIdle)
        #expect(await spin { tree.isIdle })
        #expect(tree.rows == ["tree:/", "A", "a1", "a2", "Home", "Inner"] && tree.status == "8 directories")
        #expect(tree.selected == "a1")
        // Control-R in the list, and the button, with the cursor nowhere: from the root.
        tree.outline?.deselectAll(nil)
        tree.press("r", code: 15, .control)
        #expect(await spin { tree.isIdle })
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.isIdle })
        // Other keys go their usual way.
        window.keyDown(with: key("x", 7))
        tree.controller.close()
    }

    @Test func aWindowWithoutATreeHasNothingToRescan() {
        let tree = window()
        defer { tree.controller.close() }
        tree.click("F2 Rescan Tree")
        #expect(tree.status.isEmpty && tree.rows.isEmpty)
        #expect(!tree.escape())
    }

    var root: URL { folders.url("/") }

    @Test func escStopsAScanWhoseLateResultsAreDropped() async {
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

    @Test func aClosedWindowsScanGoesOnUntilItsLimit() async {
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

    @Test func aScanThatEndsWithoutTheWindowLeavesTheTreeToTheCache() async {
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

    @Test func aLimitThatEndsAfterTheWindowCameBackDoesNothing() async {
        folders.hold("/B")
        let tree = window(hiddenScanLimit: 0.05)
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

    @Test func quittingEndsAScanWithoutAWindow() async {
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

    @Test func anotherRootWhileReadingReplacesTheScan() async {
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

    /// A window on a stored tree whose folder B was not read.
    func partial() async -> CoveragePlacesTreeParts {
        let cache = TreeCache(directory: nil)
        cache.store(["A", "A/a1", "B"], unscanned: ["B"], isComplete: false, for: root)
        return await opened("/A", cache: cache)
    }

    func expand(_ title: String, in tree: CoveragePlacesTreeParts) {
        guard let outline = tree.outline, let item = outline.item(atRow: tree.row(titled: title)) else {
            Issue.record("no row titled \(title)")
            return
        }
        outline.collapseItem(item)
        outline.expandItem(item, expandChildren: true)
    }

    @Test func aFolderOpenedBeforeItWasReadIsReadThenAndOnce() async {
        let tree = await partial()
        defer { tree.controller.close() }
        #expect(tree.rows == ["tree:/", "A", "B"])
        folders.hold("/B")
        expand("B", in: tree)
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        folders.release("/B")
        #expect(await spin { tree.rows.contains("b1") })
        #expect(tree.rows == ["tree:/", "A", "B", "b1"] && tree.status.hasPrefix("4 directories, incomplete"))
        // Read now: opening it again reads nothing.
        expand("B", in: tree)
        expand("A", in: tree)
        tree.controller.close()
    }

    @Test func aFolderReadForAnotherTreeIsDropped() async {
        let tree = await partial()
        defer { tree.controller.close() }
        folders.hold("/B")
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        tree.chooseRoot(3)
        #expect(await spin { tree.isIdle && tree.rows.first == "mem:/" })
        folders.release("/B")
        await CoveragePlacesLoop.settle()
        #expect(tree.rows == ["mem:/", "M"])
        tree.controller.close()
    }

    @Test func aFolderTheRescanReadFirstIsNotReadAgain() async {
        let tree = await partial()
        defer { tree.controller.close() }
        folders.hold("/B")
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.status == "9 directories" })
        folders.release("/B")
        await CoveragePlacesLoop.settle()
        #expect(tree.rows.filter { $0 == "b1" }.count == 1)
        tree.controller.close()
    }

    @Test func aFolderReadWhileTheWindowIsAwayFindsNoTree() async {
        let tree = await partial()
        defer { tree.controller.close() }
        folders.hold("/B")
        expand("B", in: tree)
        #expect(await spin { folders.isWaiting("/B") })
        // The stored tree is let go with the window; the folder's answer finds no tree.
        tree.controller.close()
        #expect(tree.rows.isEmpty)
        folders.release("/B")
        #expect(await spin { tree.status.isEmpty })
    }

    @Test func aFolderOpenedWhileTheScanRunsIsReadOnItsOwn() async {
        folders.hold("/A")
        let tree = window()
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/Home"), showHidden: false)
        #expect(await spin { folders.isWaiting("/A") && tree.rows.contains("B") })
        expand("B", in: tree)
        #expect(await spin { tree.rows.contains("b1") })
        #expect(tree.status.hasPrefix("Reading directories"))
        folders.release("/A")
        #expect(await spin { tree.isIdle })
        tree.controller.close()
    }

    @Test func typingFindsAFolderAndStepsThroughTheMatches() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        tree.type("a2")
        #expect(tree.selected == "a2" && tree.path == "tree:/A/a2")
        tree.type("zz")
        #expect(beeps.value == 1 && tree.selected == "a2")
        tree.type("")
        #expect(beeps.value == 1)
        // Typing in the list fills the field.
        tree.press("h", code: 4)
        #expect(tree.searchField?.stringValue == "h" && tree.selected == "Home")
        tree.press("\u{7F}", code: 51)
        #expect(tree.searchField?.stringValue.isEmpty == true && tree.selected == "Home")
        tree.type("a")
        #expect(tree.selected == "A")
        tree.press("\u{F701}", code: 125, .control)
        #expect(tree.selected == "a1")
        tree.press("\r", code: 36, .control)
        #expect(tree.selected == "a2")
        tree.press("\u{F700}", code: 126, .control)
        #expect(tree.selected == "a1")
        // A key that types nothing goes to the list: left goes to the folder above.
        tree.press("\u{F702}", code: 123)
        #expect(tree.searchField?.stringValue == "a" && tree.selected == "A")
        tree.press("\u{F701}", code: 125, .control)
        tree.press("\r", code: 36)
        #expect(!presenter.isOpen(tree.window) && bench.left.model.directory == folders.url("/A/a1"))
    }

    @Test func keysInTheSearchFieldStepAndGo() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        guard let field = tree.searchField else {
            return
        }
        tree.type("a")
        // Without a key press behind it (no event is being handled here) a command is the field's own.
        #expect(
            !tree.controller.control(
                field,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
        )
        let other = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        #expect(!tree.controller.handleFieldKey(other))
        #expect(!tree.controller.handleFieldKey(key("b", 11)))
        #expect(tree.controller.handleFieldKey(key("\u{F701}", 125, .control)) && tree.selected == "a2")
        #expect(tree.controller.handleFieldKey(key("\u{F700}", 126)) && tree.selected == "a1")
        #expect(tree.controller.handleFieldKey(key("\u{3}", 76)))
        #expect(!presenter.isOpen(tree.window) && bench.left.model.directory == folders.url("/A/a1"))
    }

    @Test func theButtonsGoOrCancelAndAJobKeepsThePanelWhereItIs() async {
        let tree = await opened("/A/a1")
        defer { tree.controller.close() }
        tree.outline?.deselectAll(nil)
        tree.click("Go")
        #expect(presenter.isOpen(tree.window))
        tree.click("Cancel")
        #expect(!presenter.isOpen(tree.window) && bench.left.model.directory == folders.url("/A"))
        tree.controller.show(for: folders.url("/A/a2"), showHidden: false)
        #expect(await spin { tree.selected == "a2" })
        var rejected = 0
        bench.commands.onRejected = { rejected += 1 }
        let parts = Shared(tree)
        bench.jobService.run(
            title: "Busy",
            work: { monitor in monitor.ask { parts.value.click("Go") } },
            completion: { _ in }
        )
        // (A window that was closed and is not put on screen again tells of no second close.)
        #expect(rejected == 1 && presenter.presented.count == 2 && bench.left.model.directory == folders.url("/A"))
    }

    @Test func aSearchOfAHugeTreeGoesOnInTurnsAndANewOneEndsIt() async {
        let cache = TreeCache(directory: nil)
        cache.store(["A"] + (0..<200_000).map { "p\($0)" }, for: root)
        let tree = await opened("/A", cache: cache)
        defer { tree.controller.close() }
        tree.type("zzz")
        tree.type("yyy")
        #expect(await spin { beeps.value == 1 })
        tree.type("p199998")
        #expect(await spin { tree.selected == "p199998" })
        await CoveragePlacesLoop.settle()
        #expect(beeps.value == 1)
    }

    @Test func aFolderOfManySubfoldersIsLinkedInTurns() async {
        folders.add("/W")
        folders.addMany(30_000, below: "/W")
        let cache = TreeCache(directory: nil)
        let tree = await opened("/W", cache: cache)
        defer { tree.controller.close() }
        #expect(cache.paths(for: root)?.count == 30_010)
        expand("W", in: tree)
        #expect(tree.rows.count > 30_000)
        // Read again: the folders known to be empty lose their triangles where they are on screen.
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.isIdle })
        #expect(tree.rows.count > 30_000 && tree.selected == "W")
    }

    @Test func escWhileManyFoldersWaitDropsTheRest() async {
        folders.add("/W")
        folders.addMany(300_000, below: "/W")
        let tree = window()
        defer { tree.controller.close() }
        tree.controller.show(for: folders.url("/W"), showHidden: false)
        // The big folder is being linked, a part in each turn of the main thread.
        #expect(await spin { tree.status.hasPrefix("Reading directories:") && tree.count > 50_000 })
        #expect(tree.escape())
        // What waited is dropped: the tree stays as it was when Esc came.
        #expect(await spin { tree.status.hasSuffix("F2 reads the rest") })
        #expect(tree.count < 300_000)
    }

    @Test func theStartUpDiskLeavesOutTheVolumesMountedInIt() async throws {
        let box = try Sandbox()
        let local = TestBench(plugins: [], fileSystems: [LocalFileSystem()], left: box.root, right: box.root)
        let controller = DirectoryTreeWindowController(kernel: local.kernel, cache: TreeCache(directory: nil)) {}
        controller.present = presenter.present
        let tree = CoveragePlacesTreeParts(controller: controller)
        defer { tree.controller.close() }
        tree.controller.show(for: box.root, showHidden: false)
        // The first levels are read (and the folders mounted inside left out) before Esc.
        #expect(await spin { tree.count > 40 })
        #expect(tree.escape())
    }

    @Test func theCursorsFolderGoneInARescanLeavesTheCursorElsewhere() async {
        let tree = await opened("/B")
        defer { tree.controller.close() }
        #expect(tree.selected == "B")
        folders.remove("/B")
        tree.click("F2 Rescan Tree")
        #expect(await spin { tree.isIdle })
        #expect(!tree.rows.contains("B") && tree.status == "7 directories")
    }
}
