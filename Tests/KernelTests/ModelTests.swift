import AFMKernel
import Foundation
import TestSupport
import Testing

@Suite struct Names {
    @Test func splitsNameAndExtension() {
        #expect(FileItem.split("report.txt") == ("report", "txt"))
        #expect(FileItem.split("archive.tar.gz") == ("archive.tar", "gz"))
        #expect(FileItem.split(".zshrc") == (".zshrc", ""))
        #expect(FileItem.split("no_extension") == ("no_extension", ""))
        #expect(FileItem.split("trailing.") == ("trailing.", ""))
    }

    @Test func fileMasks() {
        #expect(FileMask("*.txt").matches("Report.TXT"))
        #expect(!FileMask("*.txt").matches("report.md"))
        #expect(FileMask("*.txt;*.md").matches("report.md"))
        #expect(FileMask("report_??.*").matches("report_01.txt"))
        #expect(FileMask("*.*").matches("no_extension"))
    }

    @Test func locations() {
        let a = URL(fileURLWithPath: "/tmp/a")
        let slash = URL(fileURLWithPath: "/tmp/a/", isDirectory: true)
        #expect(a.isSameLocation(as: slash))
        #expect(URL(fileURLWithPath: "/tmp/a/b").isInside(a))
        #expect(!URL(fileURLWithPath: "/tmp/ab").isInside(a))
        #expect(!a.isInside(a))
        #expect(!a.isSameLocation(as: MemoryFileSystem().url("/tmp/a")))
    }

    @Test func buildingTheLocationOfAnEntryNeverAsksTheDisk() {
        // The plain Foundation call looks at the disk to decide about a trailing slash, which on
        // a network share is a trip to the server per file. This one works on the text alone:
        // the result is the same whether or not the name exists or is a folder.
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        #expect(URL(fileURLWithPath: "/", isDirectory: true).appending(name: "tmp").absoluteString == "file:///tmp")
        #expect(tmp.appending(name: "no-such-entry").absoluteString == "file:///tmp/no-such-entry")
        #expect(tmp.appending(name: "a/b c.txt").path == "/tmp/a/b c.txt")
        #expect(URL(fileURLWithPath: "/", isDirectory: true).appending(name: "tmp").isSameLocation(as: tmp))
        #expect(MemoryFileSystem().url("/work").appending(name: "x.txt").path == "/work/x.txt")
    }

    @Test func theSamePathOnTwoServersIsTwoPlaces() {
        let alpha = URL(string: "sftp://alpha/home/x.txt")!
        let beta = URL(string: "sftp://beta/home/x.txt")!
        #expect(!alpha.isSameLocation(as: beta))
        #expect(!URL(string: "sftp://alpha:22/home")!.isSameLocation(as: URL(string: "sftp://alpha:2222/home")!))
        #expect(alpha.isInside(URL(string: "sftp://alpha/home")!))
        #expect(!alpha.isInside(URL(string: "sftp://beta/home")!))
    }
}

@Suite struct Sorting {
    func item(_ name: String, folder: Bool = false, size: Int64 = 0, time: TimeInterval = 0) -> FileItem {
        FileItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            kind: .init(isDirectory: folder),
            stat: .init(size: size, modified: Date(timeIntervalSince1970: time))
        )
    }

    @Test func foldersFirstAndAlwaysByName() {
        let items = [
            item("b.txt", size: 1), item("zeta", folder: true), item("a.txt", size: 9), item("Alpha", folder: true)
        ]
        let sorted = Sorter.sort(items, by: ListOrder(key: .size, descending: true))
        #expect(sorted.map(\.name) == ["Alpha", "zeta", "a.txt", "b.txt"])
    }

    @Test func sortsByExtensionThenName() {
        let items = [item("b.txt"), item("a.txt"), item("c.md")]
        #expect(Sorter.sort(items, by: ListOrder(key: .ext)).map(\.name) == ["c.md", "a.txt", "b.txt"])
    }

    @Test func unsortedKeepsFilesInArrivalOrder() {
        let items = [item("b.txt"), item("z", folder: true), item("a.txt"), item("m", folder: true)]
        #expect(Sorter.sort(items, by: ListOrder(key: .unsorted)).map(\.name) == ["m", "z", "b.txt", "a.txt"])
    }

    @Test func headerClickReversesOrStartsInOwnDirection() {
        let byName = ListOrder()
        #expect(byName.clicked(.name) == ListOrder(key: .name, descending: true))
        #expect(byName.clicked(.date) == ListOrder(key: .date, descending: true))
        #expect(byName.clicked(.ext) == ListOrder(key: .ext, descending: false))
    }

    @Test func mergingABatchEqualsSortingEverything() {
        let order = ListOrder(key: .size, descending: true)
        let first = (0..<40).map { item("a\($0).txt", folder: $0 % 7 == 0, size: Int64($0 * 37 % 11)) }
        let second = (0..<25).map { item("b\($0).txt", folder: $0 % 5 == 0, size: Int64($0 * 13 % 11)) }
        let merged = Sorter.merge(Sorter.sort(first, by: order), with: Sorter.sort(second, by: order), by: order)
        #expect(merged.map(\.name) == Sorter.sort(first + second, by: order).map(\.name))
        #expect(Sorter.merge([], with: second, by: order).count == 25)
        #expect(Sorter.merge(first, with: [], by: order).count == 40)
    }

    @Test func aListCollectedInBatchesIsAlwaysSorted() {
        for order in [
            ListOrder(), ListOrder(key: .ext), ListOrder(key: .date, descending: true), ListOrder(key: .unsorted)
        ] {
            var list = SortedFileList(order: order)
            var all: [FileItem] = []
            for batch in 0..<6 {
                let items = (0..<30)
                    .map {
                        item(
                            "f\(($0 * 17 + batch * 5) % 97)-\(batch).\(["txt", "md"][$0 % 2])",
                            folder: $0 % 9 == 0,
                            size: Int64($0 % 4),
                            time: TimeInterval(($0 * 31 + batch) % 13)
                        )
                    }
                list.add(items)
                all += items
                #expect(list.items.map(\.name) == Sorter.sort(all, by: order).map(\.name))
            }
            #expect(list.count == 180)
        }
    }

    @Test func aLongListSortedOnAllCoresEqualsTheSimpleSort() {
        // Above the threshold the list is sorted in parallel runs and merged.
        let count = 60_000
        let items = (0..<count)
            .map { index in
                item(
                    "file\((index &* 7_919) % count)-\(index % 3).\(["txt", "md", "swift"][index % 3])",
                    folder: index % 97 == 0,
                    size: Int64((index &* 31) % 5_000),
                    time: TimeInterval((index &* 17) % 9_000)
                )
            }
        for order in [
            ListOrder(), ListOrder(key: .size, descending: true), ListOrder(key: .date), ListOrder(key: .unsorted)
        ] {
            let simple = items.sorted { Sorter.areInOrder($0, $1, by: order) }
            #expect(Sorter.sort(items, by: order).map(\.name) == simple.map(\.name))
        }
    }
}

/// The panel model, fed with listings from a file system that is not the local disk.
@MainActor @Suite struct Panel {
    let memory = MemoryFileSystem()
    let fileSystems = FileSystemRegistry()
    let panel: PanelModel

    init() throws {
        memory.addDirectory("/work/docs")
        memory.addDirectory("/work/bin")
        memory.addFile("/work/a.txt", String(repeating: "a", count: 2_048))
        memory.addFile("/work/b.md", String(repeating: "b", count: 1_024))
        memory.addFile("/work/.hidden")
        fileSystems.register(memory)
        panel = PanelModel(directory: memory.url("/work"))
        try show("/work")
    }

    func listing(_ path: String) throws -> Listing {
        try PanelLoader.load(memory.url(path), showHidden: panel.showHidden, fileSystems: fileSystems).listing
    }

    func show(_ path: String, focus: String? = nil, history: PanelModel.HistoryEffect = .record) throws {
        panel.show(try listing(path), focus: focus, history: history)
    }

    @Test func startsUnlistedAndTakesAListing() throws {
        let fresh = PanelModel(directory: memory.url("/work"))
        #expect(!fresh.isListed && fresh.items.isEmpty && fresh.rowCount == 0)
        fresh.show(try listing("/work"))
        #expect(fresh.isListed && fresh.isComplete && fresh.volume?.name == "Memory")
    }

    @Test func listsWithParentRowAndHidesDotFiles() throws {
        #expect(panel.hasParentRow)
        #expect(panel.item(atRow: 0) == nil)
        #expect(panel.items.map(\.name) == ["bin", "docs", "a.txt", "b.md"])
        panel.setShowHidden(true)
        panel.update(with: try listing("/work"))
        #expect(panel.items.map(\.name).contains(".hidden"))
    }

    @Test func parentAndRootTargets() throws {
        #expect(panel.parentTarget?.location.path == "/" && panel.parentTarget?.focus == "work")
        try show("/work/docs")
        #expect(panel.rootTarget?.location.path == "/" && panel.rootTarget?.focus == "work")
        try show("/")
        #expect(!panel.hasParentRow && panel.parentTarget == nil && panel.rootTarget == nil)
        #expect(panel.item(atRow: 0)?.name == "work")
    }

    @Test func operandRule() {
        panel.moveCursor(to: 0)
        #expect(panel.cursorIsOnParentRow && !panel.hasOperands)
        #expect(panel.operands().isEmpty && panel.cursorFile == nil)
        panel.moveCursor(to: panel.row(ofName: "a.txt")!)
        #expect(panel.operands().map(\.name) == ["a.txt"] && panel.cursorFile?.name == "a.txt")
        panel.toggleSelection(row: panel.row(ofName: "b.md")!)
        panel.toggleSelection(row: panel.row(ofName: "bin")!)
        #expect(panel.operands().map(\.name) == ["bin", "b.md"])
        panel.toggleSelection(row: 0)
        #expect(panel.selection.count == 2)
        panel.moveCursor(to: panel.row(ofName: "docs")!)
        #expect(panel.cursorFile == nil)
        panel.moveCursor(to: 99)
        #expect(panel.cursor == panel.rowCount - 1)
    }

    @Test func selectionCommandsAndTotals() {
        #expect(
            panel.totals
                == PanelModel.Totals(
                    selectedBytes: 0,
                    totalBytes: 3_072,
                    selectedFiles: 0,
                    totalFiles: 2,
                    selectedFolders: 0,
                    totalFolders: 2
                )
        )
        panel.selectAll()
        #expect(
            panel.totals.selectedBytes == 3_072 && panel.totals.selectedFiles == 2 && panel.totals.selectedFolders == 2
        )
        panel.select(mask: "*.txt", select: false)
        #expect(panel.selection == ["bin", "docs", "b.md"])
        panel.invertSelection()
        #expect(panel.selection == ["a.txt"])
        panel.saveSelection()
        panel.clearSelection()
        panel.restoreSelection()
        #expect(panel.selection == ["a.txt"])
        panel.setSelected(true, rows: 1...2)
        #expect(panel.selection == ["a.txt", "bin", "docs"])
        panel.setComputedSize(4_096, forName: "docs")
        #expect(panel.totals.totalBytes == 3_072 + 4_096 && panel.totals.selectedBytes == 2_048 + 4_096)
    }

    @Test func historyGoesBackAndForward() throws {
        try show("/work/docs")
        #expect(panel.items.isEmpty)
        let parent = try #require(panel.parentTarget)
        panel.show(try listing("/work"), focus: parent.focus)
        #expect(panel.cursorItem?.name == "docs")
        #expect(panel.backLocation?.lastPathComponent == "docs" && panel.forwardLocation == nil)
        try show("/work/docs", history: .step(-1))
        #expect(panel.backLocation?.lastPathComponent == "work" && panel.forwardLocation?.lastPathComponent == "work")
        try show("/work", history: .step(-1))
        #expect(panel.backLocation == nil && panel.forwardLocation?.lastPathComponent == "docs")
        // A new place drops what lay ahead.
        try show("/work/bin")
        #expect(panel.forwardLocation == nil && panel.backLocation?.lastPathComponent == "work")
        // A reload changes nothing in the history.
        try show("/work/bin", history: .keep)
        #expect(panel.backLocation?.lastPathComponent == "work")
    }

    @Test func updateKeepsCursorSelectionAndFolderSizes() throws {
        panel.moveCursor(to: panel.row(ofName: "b.md")!)
        panel.toggleSelection(row: panel.row(ofName: "a.txt")!)
        panel.setComputedSize(4_096, forName: "docs")
        #expect(!panel.update(with: try listing("/work")))
        memory.addFile("/work/0-new.txt")
        #expect(panel.update(with: try listing("/work")))
        #expect(panel.cursorItem?.name == "b.md")
        #expect(panel.selection == ["a.txt"])
        #expect(panel.items.first { $0.name == "docs" }?.computedSize == 4_096)
        #expect(panel.update(with: try listing("/work"), focus: "0-new.txt"))
        #expect(panel.cursorItem?.name == "0-new.txt")
    }

    @Test func aVanishedCursorItemLeavesTheCursorInPlace() throws {
        panel.moveCursor(to: panel.row(ofName: "a.txt")!)
        memory.removeTree("/work/a.txt")
        panel.update(with: try listing("/work"))
        #expect(panel.cursorItem?.name == "b.md")
    }

    @Test func aFolderIsEnteredBeforeItHasBeenRead() throws {
        panel.moveCursor(to: panel.row(ofName: "a.txt")!)
        panel.toggleSelection(row: panel.cursor)
        let before = panel.snapshot()
        panel.open(memory.url("/work/docs"), parent: memory.url("/work"), root: memory.url("/"))
        // The panel is in the folder at once: its path, no entries yet, and the way back.
        #expect(panel.directory.path == "/work/docs" && panel.isOpening && !panel.isComplete && !panel.isListed)
        #expect(panel.items.isEmpty && panel.rowCount == 1 && panel.cursorIsOnParentRow && panel.selection.isEmpty)
        #expect(panel.parentTarget?.location.path == "/work" && panel.parentTarget?.focus == "docs")
        #expect(panel.backLocation?.path == "/work" && !panel.hasOperands)

        // The entries arrive; the visit is in the history once, not twice.
        memory.addFile("/work/docs/in.txt")
        panel.show(try listing("/work/docs"), history: .record, complete: false)
        #expect(!panel.isOpening && panel.isListed && panel.items.map(\.name) == ["in.txt"])
        panel.finishLoading()
        #expect(panel.isComplete && panel.backLocation?.path == "/work" && panel.forwardLocation == nil)
        try show("/work", history: .step(-1))
        #expect(panel.backLocation == nil && panel.forwardLocation?.path == "/work/docs")
        _ = before
    }

    @Test func aFolderThatCannotBeReadIsLeftAgain() throws {
        try show("/work/bin")
        try show("/work", history: .step(-1))
        panel.moveCursor(to: panel.row(ofName: "a.txt")!)
        panel.toggleSelection(row: panel.cursor)
        let before = panel.snapshot()
        panel.open(memory.url("/work/locked"), parent: memory.url("/work"), root: memory.url("/"))
        #expect(panel.forwardLocation == nil)
        panel.restore(before)
        // Everything is as it was: folder, entries, cursor, selection and the history on both sides.
        #expect(panel.directory.path == "/work" && panel.isListed && panel.isComplete && !panel.isOpening)
        #expect(panel.items.map(\.name) == ["bin", "docs", "a.txt", "b.md"])
        #expect(panel.cursorItem?.name == "a.txt" && panel.selection == ["a.txt"])
        #expect(panel.forwardLocation?.path == "/work/bin" && panel.backLocation == nil)
    }

    @Test func openingTheLocationOfAFileEndsInItsFolder() throws {
        panel.open(memory.url("/work/a.txt"), parent: memory.url("/work"), root: memory.url("/"))
        let result = try PanelLoader.load(memory.url("/work/a.txt"), showHidden: false, fileSystems: fileSystems)
        try show("/work/bin")
        panel.open(memory.url("/work/a.txt"), parent: memory.url("/work"), root: memory.url("/"))
        panel.show(result.listing, focus: result.focus)
        #expect(panel.directory.path == "/work" && panel.cursorItem?.name == "a.txt")
        // The history holds the folder, not the file.
        #expect(panel.backLocation?.path == "/work/bin")
        try show("/work/bin", history: .step(-1))
        #expect(panel.forwardLocation?.path == "/work")
    }

    @Test func everyChangeIsAnnounced() throws {
        var changes: [PanelModel.Change] = []
        panel.onChange = { changes.append($0) }
        panel.moveCursor(to: 2)
        panel.toggleSelection(row: 2)
        panel.selectAll()
        panel.setSort(ListOrder(key: .size))
        try show("/work/docs")
        panel.cursor = 0
        #expect(changes == [.cursor, .selection, .selection, .contents, .contents])
    }

    /// The entries of /work by name, to hand over in a chosen order.
    func entries() throws -> [String: FileItem] {
        Dictionary(uniqueKeysWithValues: try listing("/work").items.map { ($0.name, $0) })
    }

    func piece(_ items: [FileItem]) -> Listing {
        Listing(directory: memory.url("/work"), items: items, parent: memory.url("/"), root: memory.url("/"))
    }

    @Test func aDirectoryCanArriveInPieces() throws {
        let entry = try entries()
        var soFar = SortedFileList(order: panel.sort)
        soFar.add([entry["docs"]!, entry["b.md"]!])
        panel.show(piece(soFar.items), focus: "a.txt", complete: false, presorted: soFar.order)
        #expect(!panel.isComplete && panel.items.map(\.name) == ["docs", "b.md"])
        panel.toggleSelection(row: panel.row(ofName: "b.md")!)
        panel.moveCursor(to: panel.row(ofName: "b.md")!)

        // The list grows in sorted order; the item that was asked for gets the cursor when it arrives.
        soFar.add([entry["bin"]!])
        panel.extend(to: soFar.items, sortedBy: soFar.order)
        #expect(panel.items.map(\.name) == ["bin", "docs", "b.md"] && panel.cursorItem?.name == "b.md")
        soFar.add([entry["a.txt"]!])
        panel.extend(to: soFar.items, sortedBy: soFar.order)
        #expect(panel.items.map(\.name) == ["bin", "docs", "a.txt", "b.md"])
        #expect(panel.cursorItem?.name == "a.txt")
        #expect(panel.selection == ["b.md"])
        panel.finishLoading()
        #expect(panel.isComplete)
    }

    @Test func theCursorStaysOnItsItemWhileADirectoryGrows() throws {
        let entry = try entries()
        panel.show(piece([entry["b.md"]!]), complete: false)
        panel.moveCursor(to: panel.row(ofName: "b.md")!)
        panel.extend(to: Sorter.sort(Array(entry.values), by: panel.sort), sortedBy: panel.sort)
        #expect(panel.cursorItem?.name == "b.md" && panel.cursor == 4)
        // On [..] it stays on [..].
        panel.moveCursor(to: 0)
        let more = Array(entry.values) + [FileItem(url: memory.url("/work/0.txt"), name: "0.txt")]
        panel.extend(to: Sorter.sort(more, by: panel.sort), sortedBy: panel.sort)
        #expect(panel.cursorIsOnParentRow && panel.items.count == 5)
    }

    @Test func aChangedSortOrderIsRespectedWhileADirectoryGrows() throws {
        let entry = try entries()
        let byName = ListOrder()
        panel.show(piece([entry["a.txt"]!]), complete: false, presorted: byName)
        panel.setSort(ListOrder(key: .size, descending: true))
        // The background still delivers by name; the panel puts it into its own order.
        panel.extend(
            to: Sorter.sort([entry["a.txt"]!, entry["b.md"]!, entry["docs"]!], by: byName),
            sortedBy: byName
        )
        #expect(panel.items.map(\.name) == ["docs", "a.txt", "b.md"])
    }
}

@MainActor @Suite struct Tabs {
    let memory = MemoryFileSystem()
    let fileSystems = FileSystemRegistry()
    let tabs: PanelTabs

    init() throws {
        memory.addFile("/A/one.txt")
        memory.addDirectory("/B")
        fileSystems.register(memory)
        let model = PanelModel(directory: memory.url("/A"))
        model.show(try PanelLoader.load(memory.url("/A"), showHidden: false, fileSystems: fileSystems).listing)
        tabs = PanelTabs(model)
    }

    @Test func newTabCopiesTheActiveTab() {
        var changes = 0
        tabs.onChange = { changes += 1 }
        tabs.active.setSort(ListOrder(key: .size, descending: true))
        tabs.openTab()
        #expect(tabs.count == 2 && tabs.activeIndex == 1 && changes == 1)
        #expect(tabs.active.directory.isSameLocation(as: memory.url("/A")))
        #expect(tabs.active.sort == ListOrder(key: .size, descending: true))
        #expect(tabs.active.isListed && tabs.active.items.map(\.name) == ["one.txt"])
    }

    @Test func aTabForAnotherFolderIsReadWhenItIsShown() {
        let tab = tabs.openTab(showing: memory.url("/B"), activate: false)
        #expect(tabs.activeIndex == 0 && tabs.title(at: 1) == "B")
        #expect(!tab.isListed && tab.items.isEmpty)
    }

    @Test func tabsKeepTheirOwnSelection() {
        tabs.active.selectAll()
        tabs.openTab()
        #expect(tabs.active.selection.isEmpty)
        tabs.activateNeighbour(1)
        #expect(tabs.activeIndex == 0)
        #expect(tabs.active.selection == ["one.txt"])
    }

    @Test func closingTabs() {
        #expect(!tabs.closeTab(at: 0))
        tabs.openTab()
        tabs.openTab()
        #expect(tabs.closeTab(at: 2))
        #expect(tabs.activeIndex == 1)
        #expect(tabs.closeTab(at: 0))
        #expect(tabs.activeIndex == 0)
        #expect(tabs.count == 1)
    }

    @Test func stateRoundTrip() {
        tabs.openTab(showing: memory.url("/B"))
        tabs.active.setSort(ListOrder(key: .date, descending: true))
        tabs.active.setShowHidden(true)
        let settings = MemorySettings()
        settings.set(tabs.state, forKey: "left.tabs")
        let restored = PanelTabs(
            restoring: settings.value(PanelTabs.State.self, forKey: "left.tabs"),
            fallback: memory.url("/")
        )
        #expect(restored.count == 2 && restored.activeIndex == 1)
        #expect(restored.active.directory.isSameLocation(as: memory.url("/B")))
        #expect(restored.active.sort == ListOrder(key: .date, descending: true))
        #expect(restored.active.showHidden && !restored.active.isListed)
        #expect(
            PanelTabs(restoring: nil, fallback: memory.url("/A")).active.directory.isSameLocation(as: memory.url("/A"))
        )
    }
}

/// Reading what a panel is asked to show.
@Suite struct Loading {
    let memory = MemoryFileSystem()
    let fileSystems = FileSystemRegistry()

    init() {
        memory.addFile("/work/docs/report.txt")
        memory.addFile("/work/a.txt")
        memory.addFile("/work/b.txt")
        memory.addFile("/work/c.txt")
        fileSystems.register(memory)
    }

    @Test func aFileLeadsToItsFolder() throws {
        let result = try PanelLoader.load(
            memory.url("/work/docs/report.txt"),
            showHidden: false,
            fileSystems: fileSystems
        )
        #expect(result.listing.directory.path == "/work/docs" && result.focus == "report.txt")
        #expect(result.listing.parent?.path == "/work" && result.listing.root.path == "/")
    }

    @Test func aMissingFolderFailsUnlessClimbing() throws {
        #expect(throws: (any Error).self) {
            try PanelLoader.load(memory.url("/work/gone/deeper"), showHidden: false, fileSystems: fileSystems)
        }
        let climbed = try PanelLoader.load(
            memory.url("/work/gone/deeper"),
            showHidden: false,
            fileSystems: fileSystems,
            climbing: true
        )
        #expect(climbed.listing.directory.path == "/work")
        #expect(throws: FileSystemError.self) {
            try PanelLoader.load(URL(string: "ftp://nowhere/x")!, showHidden: false, fileSystems: fileSystems)
        }
    }

    @Test func aSlowDirectoryArrivesInBatches() throws {
        memory.listBatchSize = 2
        var batches: [PanelLoader.Batch] = []
        try PanelLoader.stream(memory.url("/work"), showHidden: false, fileSystems: fileSystems) {
            batches.append($0)
            return true
        }
        #expect(batches.map(\.listing.items.count) == [2, 2])
        #expect(batches.map(\.isFirst) == [true, false])
        #expect(batches.allSatisfy { $0.listing.directory.path == "/work" && $0.listing.parent?.path == "/" })
        // The whole listing is the batches put together.
        #expect(
            try PanelLoader.load(memory.url("/work"), showHidden: false, fileSystems: fileSystems).listing.items.count
                == 4
        )
    }

    @Test func streamingStopsWhenNoMoreIsWanted() throws {
        memory.listBatchSize = 1
        var count = 0
        try PanelLoader.stream(memory.url("/work"), showHidden: false, fileSystems: fileSystems) { _ in
            count += 1
            return count < 2
        }
        #expect(count == 2)
    }

    @Test func anEmptyDirectoryStillGivesOneBatch() throws {
        memory.addDirectory("/empty")
        var batches = 0
        try PanelLoader.stream(memory.url("/empty"), showHidden: false, fileSystems: fileSystems) { batch in
            batches += 1
            return batch.listing.items.isEmpty
        }
        #expect(batches == 1)
    }

    @Test func directorySizeIsAddedUpOverTheTree() {
        memory.addFile("/big/a/one.txt", String(repeating: "a", count: 100))
        memory.addFile("/big/a/deep/two.txt", String(repeating: "b", count: 50))
        memory.addFile("/big/b/three.txt", String(repeating: "c", count: 7))
        memory.addFile("/big/top.txt", String(repeating: "d", count: 3))
        #expect(memory.totalSize(of: memory.url("/big"), cancellation: CancellationFlag()) == 160)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        #expect(memory.totalSize(of: memory.url("/big"), cancellation: cancelled) == 0)
    }
}
