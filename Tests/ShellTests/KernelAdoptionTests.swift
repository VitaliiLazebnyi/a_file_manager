import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// The panel's use of what the kernel offers: cancellable listings, filtering off the main
/// thread, exact marks, per-location capabilities, and free space that follows the server.
extension Application {
    private func names(_ count: Int, folder: String, using fake: ScriptedFileSystem) -> [FileItem] {
        (0..<count).map { fake.item(named: String(format: "f%05d.txt", $0), in: folder) }
    }

    /// The names of `items` that contain `text`, in order.
    private func matching(_ text: String, in items: [FileItem]) -> [String] {
        items.map(\.name).filter { $0.contains(text) }
    }

    /// Waits on this thread, which keeps the main queue from running.
    private func blockUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return condition()
    }

    // MARK: Cancellable listings

    @Test func aStalledListingIsEndedWhenThePanelMovesOn() async {
        let stuck = ScriptedFileSystem()
        stuck.holdBefore = 0
        defer { stuck.open() }
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(stuck)
        app.left.show(stuck.url("/stuck"))
        #expect(await wait { stuck.listingsBegun == 1 })
        app.left.show(box.url("B"))
        // The server never answers; the read ends because it was told to, not because it was let go.
        #expect(await wait(upTo: 60) { stuck.listingsEnded == 1 })
        #expect(await wait { app.left.model.directory.lastPathComponent == "B" && app.names(app.left) == ["one.txt"] })
    }

    @Test func aStalledListingIsEndedWhenItsTabIsClosed() async {
        let stuck = ScriptedFileSystem()
        stuck.holdBefore = 0
        defer { stuck.open() }
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(stuck)
        app.commands.perform(.newTab)
        app.left.show(stuck.url("/stuck"))
        #expect(await wait { stuck.listingsBegun == 1 })
        app.commands.perform(.closeTab, .index(app.left.tabs.activeIndex))
        #expect(await wait(upTo: 60) { stuck.listingsEnded == 1 })
    }

    // MARK: Pieces

    @Test func aLastPieceInAnotherOrderIsSortedInTheBackgroundAndKeepsTheEndBehindIt() async {
        let big = ScriptedFileSystem()
        let total = PanelViewController.backgroundSortThreshold + 500
        big.batches = [names(total, folder: "/big", using: big)]
        // Only a listing from a remote volume is remembered, which is how the test sees the reading end.
        big.volumeFigure = VolumeInfo(name: "Remote", isLocal: false)
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(big)
        let location = big.url("/big")
        let showHidden = app.left.model.showHidden
        app.left.show(location)
        // The reading is over on its thread, and its piece waits in the main queue; this thread
        // does not take it yet. The order is changed now, so the piece comes in the wrong one.
        #expect(blockUntil { app.kernel.listingCache.age(of: location, showHidden: showHidden) != nil })
        app.left.model.setSort(ListOrder(key: .name, descending: true))
        // The end of the reading waits for the piece that is sorted again; if it did not, the
        // piece would find the reading over and be thrown away.
        #expect(
            await wait { app.left.model.directory.path == "/big" && app.left.model.isComplete && !app.left.isLoading })
        #expect(app.left.model.items.count == total && app.left.model.sort == ListOrder(key: .name, descending: true))
        #expect(
            app.left.model.items.first?.name == String(format: "f%05d.txt", total - 1)
                && app.left.model.items.last?.name == "f00000.txt")
    }

    // MARK: Quick filter

    @Test func aLongListIsFilteredInTheBackgroundAndOnlyTheLastTextCounts() async {
        let big = ScriptedFileSystem()
        let total = PanelViewController.backgroundSortThreshold + 500
        let all = names(total, folder: "/big", using: big)
        big.batches = [all]
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(big)
        app.left.show(big.url("/big"))
        #expect(
            await wait { app.left.model.directory.path == "/big" && app.left.model.isComplete && !app.left.isLoading })
        app.left.showQuickFilter()
        app.left.quickFilterTyped("77")
        // Not done on this thread: the list is as it was until the answer comes.
        #expect(app.left.model.items.count == total && !app.left.filterJobs.isEmpty)
        #expect(await wait { app.left.model.items.count != total })
        #expect(app.names(app.left) == matching("77", in: all))
        // A text that is overtaken by the next one never shows.
        app.left.quickFilterTyped("99")
        app.left.quickFilterTyped("9")
        #expect(await wait { app.left.filterJobs.isEmpty })
        #expect(app.names(app.left) == matching("9", in: all))
        // Esc takes the filter away, also one that is still being worked out.
        app.left.quickFilterTyped("5")
        app.left.removeQuickFilter()
        await withCheckedContinuation { done in
            DispatchQueue.global().async { DispatchQueue.main.async { done.resume() } }
        }
        #expect(await wait { app.left.model.items.count == total })
        #expect(app.left.quickFilterText == nil && app.left.model.filter == nil)
    }

    @Test func textTypedBeforeATabSwitchBelongsToTheTabItWasTypedIn() async {
        let app = await start()
        defer { app.stop() }
        let first = app.left.model
        app.left.showQuickFilter()
        // Still waiting for more keys when the tab is switched.
        app.left.quickFilterEdited("two")
        #expect(app.left.pendingQuickFilter != nil && first.items.count == 3)
        app.commands.perform(.newTab)
        #expect(app.left.model !== first)
        #expect(first.items.map(\.name) == ["two.txt"] && app.left.pendingQuickFilter == nil)
        app.commands.perform(.activateTab, .index(0))
        #expect(app.left.model === first && app.left.quickFilterText == "two" && app.names(app.left) == ["two.txt"])
        #expect(app.left.quickFilterBar.text == "two")
    }

    // MARK: Marks

    @Test func onlyTheMarkedOfTwoNamesThatReadTheSameIsDrawnAndCountedAsMarked() async {
        let composed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        memory.addFile("/twins/" + composed)
        memory.addFile("/twins/" + decomposed)
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/twins"))
        #expect(
            await wait { app.left.model.directory.path == "/twins" && app.left.model.isComplete && !app.left.isLoading }
        )
        let model = app.left.model
        let rows = model.items.indices.map { $0 + (model.hasParentRow ? 1 : 0) }
        #expect(rows.count == 2)
        let nameColumn = app.left.tableView.tableColumns.first {
            $0.identifier.rawValue == FileListColumn.name.rawValue
        }!
        func drawnMarked(_ row: Int) -> Bool {
            let cell = app.left.tableView(app.left.tableView, viewFor: nameColumn, row: row) as? NSTableCellView
            return cell?.textField?.textColor == app.left.nameColor(for: model.item(atRow: row), selected: true)
                && app.left.nameColor(for: model.item(atRow: row), selected: true)
                    != app.left.nameColor(for: model.item(atRow: row), selected: false)
        }
        model.toggleSelection(row: rows[0])
        #expect(model.selectionCount == 1)
        #expect(model.isSelected(row: rows[0]) && !model.isSelected(row: rows[1]))
        #expect(drawnMarked(rows[0]) && !drawnMarked(rows[1]))
        #expect(model.operands().count == 1 && model.operands().first?.name == model.item(atRow: rows[0])?.name)
        // The drag of the unmarked twin carries itself, not the marked one.
        #expect(app.left.draggedItems(fromRow: rows[1]).map(\.name) == [model.item(atRow: rows[1])!.name])
        #expect(app.left.draggedItems(fromRow: rows[0]).count == 1)
    }

    // MARK: Per-location capabilities

    @Test func aDropIsJudgedByTheCapabilitiesOfTheFolderItGoesTo() async {
        memory.capabilitiesAt = { $0.path.hasPrefix("/readonly") ? [] : [.write] }
        memory.addDirectory("/readonly")
        memory.addDirectory("/writable")
        memory.addFile("/writable/a.txt")
        let app = await start()
        defer { app.stop() }
        #expect(app.kernel.fileSystems.capabilities(for: memory.url("/readonly")) == [])
        app.left.show(memory.url("/readonly"))
        #expect(
            await wait {
                app.left.model.directory.path == "/readonly" && app.left.model.isComplete && !app.left.isLoading
            })
        let source = box.url("B/one.txt")
        #expect(app.left.dropPlan(for: [source], row: -1, modifiers: [], allowed: .copy) == nil)
        app.left.show(memory.url("/writable"))
        #expect(
            await wait {
                app.left.model.directory.path == "/writable" && app.left.model.isComplete && !app.left.isLoading
            })
        #expect(
            app.left.dropPlan(for: [source], row: -1, modifiers: [], allowed: .copy)?.destination.path == "/writable")
    }

    // MARK: Free space

    @Test func freeSpaceFollowsTheFileSystemWhenItReportsANewFigure() async {
        let share = ScriptedFileSystem()
        share.volumeFigure = VolumeInfo(name: "Share", freeBytes: 100, totalBytes: 1000, isLocal: false)
        share.batches = [[share.item(named: "a.txt", in: "/share/sub")]]
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(share)
        app.left.show(share.url("/share/sub"))
        #expect(
            await wait {
                app.left.model.directory.path == "/share/sub" && app.left.model.isComplete && !app.left.isLoading
            })
        #expect(app.left.model.volume?.freeBytes == 100)
        let asked = share.volumeQuestions
        func report(root: String) {
            NotificationCenter.default.post(
                name: FileSystemRegistry.volumeInfoDidChange, object: share,
                userInfo: [FileSystemRegistry.volumeRootKey: share.url(root)])
        }
        // Another volume's news is not for this panel; the right one's is, also from a higher root.
        share.volumeFigure = VolumeInfo(name: "Share", freeBytes: 40, totalBytes: 1000, isLocal: false)
        report(root: "/elsewhere")
        report(root: "/share")
        #expect(await wait { app.left.model.volume?.freeBytes == 40 })
        #expect(share.volumeQuestions == asked + 1)
        // The right panel shows the local folder B: news of the share leaves it alone.
        #expect(app.right.model.volume?.name != "Share")
    }
}
