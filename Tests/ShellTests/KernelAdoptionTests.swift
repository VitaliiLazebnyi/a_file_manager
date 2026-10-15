import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The panel's use of what the kernel offers, through the real program: cancellable listings,
/// filtering off the main thread, exact marks, per-location capabilities, and free space that
/// follows the server.
@MainActor
@Suite(.serialized)
internal struct KernelAdoptionTests {
    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// `count` files called `f00000.txt` and on, in `folder` of `fake`.
    private func names(_ count: Int, folder: String, using fake: ScriptedFileSystem) -> [FileItem] {
        (0..<count).map { fake.item(named: String(format: "f%05d.txt", $0), in: folder) }
    }

    /// Waits until the left panel shows `path` complete and reads nothing.
    private func shown(_ path: String, in app: PanelProgram.Running) async -> Bool {
        await PanelWait.until {
            app.left.model.directory.path == path && app.left.model.isComplete && !app.left.isLoading
        }
    }

    /// A listing that a server never ends is ended when the panel moves on: it was told to.
    @Test
    internal func aStalledListingIsEndedWhenThePanelMovesOn() async {
        let stuck = ScriptedFileSystem()
        stuck.holdBefore = 0
        defer { stuck.open() }
        let app = await program.start()
        defer { app.stop() }
        app.kernel.fileSystems.register(stuck)
        app.left.show(stuck.url("/stuck"))
        #expect(await PanelWait.until { stuck.listingsBegun == 1 })
        app.left.show(program.box.url("B"))
        #expect(await PanelWait.until { stuck.listingsEnded == 1 })
        #expect(
            await PanelWait.until {
                app.left.model.directory.lastPathComponent == "B" && app.names(app.left) == ["one.txt"]
            }
        )
    }

    /// A listing that a server never ends is ended when its tab is closed.
    @Test
    internal func aStalledListingIsEndedWhenItsTabIsClosed() async {
        let stuck = ScriptedFileSystem()
        stuck.holdBefore = 0
        defer { stuck.open() }
        let app = await program.start()
        defer { app.stop() }
        app.kernel.fileSystems.register(stuck)
        app.commands.perform(.newTab, .nothing)
        app.left.show(stuck.url("/stuck"))
        #expect(await PanelWait.until { stuck.listingsBegun == 1 })
        app.commands.perform(.closeTab, .index(app.left.tabs.activeIndex))
        #expect(await PanelWait.until { stuck.listingsEnded == 1 })
    }

    /// A last piece in another order is sorted in the background, and the end of the reading
    /// waits for it instead of finding the reading over and throwing the piece away.
    @Test
    internal func aLastPieceInAnotherOrderIsSortedInTheBackgroundAndKeepsTheEndBehindIt() async {
        let big = ScriptedFileSystem()
        let total = PanelViewController.backgroundSortThreshold + 500
        big.batches = [names(total, folder: "/big", using: big)]
        // Only a listing from a remote volume is remembered, which is how the test sees the reading end.
        big.volumeFigure = VolumeInfo(name: "Remote", isLocal: false)
        let app = await program.start()
        defer { app.stop() }
        app.kernel.fileSystems.register(big)
        let location = big.url("/big")
        let showHidden = app.left.model.showHidden
        app.left.show(location)
        // The reading is over on its thread, and its piece waits in the main queue; this thread
        // does not take it yet. The order is changed now, so the piece comes in the wrong one.
        #expect(Wait.until { app.kernel.listingCache.age(of: location, showHidden: showHidden) != nil })
        app.left.model.setSort(ListOrder(key: .name, descending: true))
        #expect(await shown("/big", in: app))
        #expect(app.left.model.items.count == total && app.left.model.sort == ListOrder(key: .name, descending: true))
        #expect(app.left.model.items.first?.name == String(format: "f%05d.txt", total - 1))
        #expect(app.left.model.items.last?.name == "f00000.txt")
    }

    /// A long list is filtered in the background; only the last text counts, and Esc takes away
    /// also a filter that is still being worked out.
    @Test
    internal func aLongListIsFilteredInTheBackgroundAndOnlyTheLastTextCounts() async {
        let big = ScriptedFileSystem()
        let total = PanelViewController.backgroundSortThreshold + 500
        let all = names(total, folder: "/big", using: big)
        big.batches = [all]
        let app = await program.start()
        defer { app.stop() }
        app.kernel.fileSystems.register(big)
        app.left.show(big.url("/big"))
        #expect(await shown("/big", in: app))
        app.left.showQuickFilter()
        app.left.quickFilterTyped("77")
        // Not done on this thread: the list is as it was until the answer comes.
        #expect(app.left.model.items.count == total && !app.left.filterJobs.isEmpty)
        #expect(await PanelWait.until { app.left.model.items.count != total })
        #expect(app.names(app.left) == all.map(\.name).filter { $0.contains("77") })
        // A text that is overtaken by the next one never shows.
        app.left.quickFilterTyped("99")
        app.left.quickFilterTyped("9")
        #expect(await PanelWait.until { app.left.filterJobs.isEmpty })
        #expect(app.names(app.left) == all.map(\.name).filter { $0.contains("9") })
        // Esc takes the filter away, also one that is still being worked out.
        app.left.quickFilterTyped("5")
        app.left.removeQuickFilter()
        await PanelWait.drainMainQueue()
        #expect(await PanelWait.until { app.left.model.items.count == total })
        #expect(app.left.quickFilterText == nil && app.left.model.filter == nil)
    }

    /// Text typed a moment before a tab switch belongs to the tab it was typed in.
    @Test
    internal func textTypedBeforeATabSwitchBelongsToTheTabItWasTypedIn() async {
        let app = await program.start()
        defer { app.stop() }
        let first = app.left.model
        app.left.showQuickFilter()
        // Still waiting for more keys when the tab is switched.
        app.left.quickFilterEdited("two")
        #expect(app.left.pendingQuickFilter != nil && first.items.count == 3)
        app.commands.perform(.newTab, .nothing)
        #expect(app.left.model !== first)
        #expect(first.items.map(\.name) == ["two.txt"] && app.left.pendingQuickFilter == nil)
        app.commands.perform(.activateTab, .index(0))
        #expect(app.left.model === first && app.left.quickFilterText == "two" && app.names(app.left) == ["two.txt"])
        #expect(app.left.quickFilterBar.text == "two")
        // Text typed into a tab that is closed before the list follows goes with the tab.
        app.commands.perform(.activateTab, .index(1))
        app.left.showQuickFilter()
        app.left.quickFilterEdited("one")
        app.commands.perform(.closeTab, .index(1))
        #expect(app.left.pendingQuickFilter == nil && app.left.model === first)
    }

    /// Of two names that read the same, only the marked one is drawn and counted as marked.
    @Test
    internal func onlyTheMarkedOfTwoNamesThatReadTheSameIsDrawnAndCountedAsMarked() async throws {
        program.memory.addFile("/twins/caf\u{E9}.txt")
        program.memory.addFile("/twins/cafe\u{301}.txt")
        let app = await program.start()
        defer { app.stop() }
        app.left.show(program.memory.url("/twins"))
        #expect(await shown("/twins", in: app))
        let model = app.left.model
        let rows = model.items.indices.map { $0 + (model.hasParentRow ? 1 : 0) }
        try #require(rows.count == 2)
        let nameColumn = try #require(
            app.left.tableView.tableColumns.first { $0.identifier.rawValue == FileListColumn.name.rawValue }
        )
        func drawnMarked(_ row: Int) -> Bool {
            let cell = app.left.tableView(app.left.tableView, viewFor: nameColumn, row: row) as? NSTableCellView
            let marked = app.left.nameColor(for: model.item(atRow: row), selected: true)
            return cell?.textField?.textColor == marked
                && marked != app.left.nameColor(for: model.item(atRow: row), selected: false)
        }
        model.toggleSelection(row: rows[0])
        #expect(model.selectionCount == 1 && model.isSelected(row: rows[0]) && !model.isSelected(row: rows[1]))
        #expect(drawnMarked(rows[0]) && !drawnMarked(rows[1]))
        #expect(model.operands().count == 1 && model.operands().first?.name == model.item(atRow: rows[0])?.name)
        // The drag of the unmarked twin carries itself, not the marked one.
        #expect(app.left.draggedItems(fromRow: rows[1]).map(\.name) == [try #require(model.item(atRow: rows[1])).name])
        #expect(app.left.draggedItems(fromRow: rows[0]).count == 1)
        PanelDrop.endDrag()
    }

    /// A drop is judged by the capabilities of the folder it goes to.
    @Test
    internal func aDropIsJudgedByTheCapabilitiesOfTheFolderItGoesTo() async {
        program.memory.capabilitiesAt = { $0.path.hasPrefix("/readonly") ? [] : [.write] }
        program.memory.addDirectory("/readonly")
        program.memory.addDirectory("/writable")
        program.memory.addFile("/writable/a.txt")
        let app = await program.start()
        defer { app.stop() }
        #expect(app.kernel.fileSystems.capabilities(for: program.memory.url("/readonly")).isEmpty)
        app.left.show(program.memory.url("/readonly"))
        #expect(await shown("/readonly", in: app))
        let source = program.box.url("B/one.txt")
        #expect(app.left.dropPlan(for: [source], row: -1, modifiers: [], allowed: .copy) == nil)
        app.left.show(program.memory.url("/writable"))
        #expect(await shown("/writable", in: app))
        #expect(
            app.left.dropPlan(for: [source], row: -1, modifiers: [], allowed: .copy)?.destination.path == "/writable"
        )
    }

    /// Free space follows the file system when it reports a new figure for the volume of a
    /// panel's folder; news of another volume is not for the panel.
    @Test
    internal func freeSpaceFollowsTheFileSystemWhenItReportsANewFigure() async {
        let share = ScriptedFileSystem()
        share.volumeFigure = VolumeInfo(name: "Share", freeBytes: 100, totalBytes: 1_000, isLocal: false)
        share.batches = [[share.item(named: "a.txt", in: "/share/sub")]]
        let app = await program.start()
        defer { app.stop() }
        app.kernel.fileSystems.register(share)
        app.left.show(share.url("/share/sub"))
        #expect(await shown("/share/sub", in: app))
        #expect(app.left.model.volume?.freeBytes == 100 && app.left.freeLabel.stringValue.hasSuffix("free"))
        let asked = share.volumeQuestions
        func report(root: String) {
            NotificationCenter.default.post(
                name: FileSystemRegistry.volumeInfoDidChange,
                object: share,
                userInfo: [FileSystemRegistry.volumeRootKey: share.url(root)]
            )
        }
        // Another volume's news is not for this panel; the right one's is, also from a higher root.
        share.volumeFigure = VolumeInfo(name: "Share", freeBytes: 40, totalBytes: 1_000, isLocal: false)
        report(root: "/elsewhere")
        report(root: "/share")
        #expect(await PanelWait.until { app.left.model.volume?.freeBytes == 40 })
        #expect(share.volumeQuestions == asked + 1)
        // The right panel shows the local folder B: news of the share leaves it alone.
        #expect(app.right.model.volume?.name != "Share")
        // News from no file system is no news.
        NotificationCenter.default.post(name: FileSystemRegistry.volumeInfoDidChange, object: nil)
    }
}
