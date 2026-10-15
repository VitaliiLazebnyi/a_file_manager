import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// Long lists change in the background and are only taken over on the main thread, through
/// the real program (review 2, S001, S018, S039; kernel requests 1 and 2).
@MainActor
@Suite(.serialized)
internal struct PanelLongListTests {
    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// Files called `f000000.txt`, `f000001.dat` and on, in `folder` of `script`.
    private func files(_ count: Int, in folder: String, of script: ScriptedFileSystem) -> [FileItem] {
        (0..<count)
            .map {
                script.item(named: String(format: "f%06d.%@", $0, $0.isMultiple(of: 2) ? "txt" : "dat"), in: folder)
            }
    }

    /// A folder of `count` files on a scripted file system, already listed in the left panel.
    private func startInALongFolder(_ script: ScriptedFileSystem, count: Int) async -> PanelProgram.Running {
        script.inner.addDirectory("/long")
        script.batches = [files(count, in: "/long", of: script)]
        let app = await program.start(plugins: program.standardPlugins, fileSystems: [script])
        app.left.show(script.url("/long"))
        await PanelWait.until {
            app.left.model.directory.path == "/long" && app.left.model.isComplete && !app.left.isLoading
        }
        return app
    }

    /// A long folder is entered at once and arrives whole, in order, from the background.
    @Test
    internal func aLongFolderIsEnteredAtOnceAndArrivesWholeFromTheBackground() async {
        let script = ScriptedFileSystem()
        let count = PanelViewController.backgroundSortThreshold + 5_000
        let app = await startInALongFolder(script, count: count)
        defer { app.stop() }
        let model = app.left.model
        #expect(model.items.count == count && model.isComplete && !model.isOpening && !app.left.isLoading)
        #expect(model.totals.totalFiles == count && app.left.statusLineText.contains("\(count) file(s)"))
        #expect(
            model.items.first?.name == "f000000.txt" && model.items.last?.name == String(format: "f%06d.dat", count - 1)
        )
    }

    /// Filtering a long list, and reading it again, never asks the filter on the main thread; the
    /// marks of what stays shown are kept; a reading that changes nothing announces nothing.
    @Test
    internal func filteringAndReadingALongListAgainNeverAsksTheFilterOnTheMainThread() async {
        let script = ScriptedFileSystem()
        let count = PanelViewController.backgroundSortThreshold + 2_000
        let app = await startInALongFolder(script, count: count)
        defer { app.stop() }
        let model = app.left.model
        let probe = PanelFilterProbe()
        let filter = PanelFilter(title: "*.txt") { item in
            probe.note()
            return item.name.hasSuffix(".txt")
        }
        let marked = ["f000002.txt", "f000004.txt"]
        model.setSelected(true, names: marked)
        #expect(!app.left.setFilter(filter, of: model, narrowing: false))
        #expect(await PanelWait.until { model.items.count == count / 2 })
        #expect(probe.onMain == 0 && probe.elsewhere >= count)
        #expect(model.filter?.title == "*.txt" && model.selectedNames.sorted() == marked)
        // The folder changes and is read again, quietly: compared, filtered and marked in the background.
        probe.reset()
        var fresh = script.batches[0]
        fresh.removeAll { $0.name == "f000004.txt" }
        fresh.append(script.item(named: "zz-new.txt", in: "/long"))
        script.batches = [fresh]
        var reloaded = false
        app.left.reload(focus: nil, quietly: true) { reloaded = true }
        #expect(await PanelWait.until { reloaded })
        #expect(model.items.count == count / 2 && model.items.last?.name == "zz-new.txt")
        #expect(model.row(ofName: "f000004.txt") == nil && model.selectedNames == ["f000002.txt"])
        #expect(probe.onMain == 0 && probe.elsewhere >= count && model.isComplete && !app.left.isLoading)
        // Read again with nothing changed: nothing is announced, and nothing filtered here.
        probe.reset()
        var contents = 0
        let before = model.onChange
        model.onChange = { change in
            if change == .contents {
                contents += 1
            }
            before?(change)
        }
        reloaded = false
        await PanelWait.until { !app.left.hasPendingReread }
        app.left.reload(focus: nil, quietly: false) { reloaded = true }
        #expect(await PanelWait.until { reloaded })
        #expect(contents == 0 && probe.onMain == 0 && model.selectedNames == ["f000002.txt"])
    }

    /// Pieces of a long folder that arrive under a filter are filtered in the background; what
    /// the first, short piece costs the main thread is bounded by that piece.
    @Test
    internal func piecesOfALongFolderThatArriveUnderAFilterAreFilteredInTheBackground() async {
        let script = ScriptedFileSystem()
        script.inner.addDirectory("/long")
        script.inner.addDirectory("/small")
        let count = PanelViewController.backgroundSortThreshold + 4_000
        let all = files(count, in: "/long", of: script)
        // A first piece of two batches, then the rest only when the test lets it come.
        script.batches = [Array(all[..<600]), Array(all[600..<1_000]), Array(all[1_000...])]
        script.batchesAt = ["/small": [[script.item(named: "s.txt", in: "/small")]]]
        script.pauseBeforeSecondBatch = 0.3
        script.holdBefore = 2
        let app = await program.start(plugins: program.standardPlugins, fileSystems: [script])
        defer { app.stop() }
        app.left.show(script.url("/small"))
        await program.settle(app)
        let model = app.left.model
        let probe = PanelFilterProbe()
        model.setFilter(
            PanelFilter(title: "*.txt") { item in
                probe.note()
                return item.name.hasSuffix(".txt")
            }
        )
        probe.reset()
        app.left.show(script.url("/long"))
        #expect(await PanelWait.until { model.directory.path == "/long" && model.items.count == 500 })
        #expect(!model.isComplete && app.left.isLoading && probe.onMain <= 1_000)
        probe.reset()
        model.setSelected(true, names: ["f000010.txt"])
        script.open()
        #expect(await PanelWait.until { model.isComplete && !app.left.isLoading })
        #expect(model.items.count == count / 2 && model.selectedNames == ["f000010.txt"])
        #expect(probe.onMain == 0 && probe.elsewhere >= count)
    }

    /// A filter whose result is overtaken by another order is worked out again and lands.
    @Test
    internal func aFilterThatIsOvertakenByAnotherOrderIsWorkedOutAgainAndLands() async {
        let script = ScriptedFileSystem()
        let count = PanelViewController.backgroundSortThreshold + 1_000
        let app = await startInALongFolder(script, count: count)
        defer { app.stop() }
        let model = app.left.model
        #expect(!app.left.setFilter(PanelFilter.mask("*.dat"), of: model, narrowing: false))
        model.setSort(ListOrder(key: .name, descending: true))
        #expect(await PanelWait.until { model.items.count == count / 2 && app.left.filterJobs.isEmpty })
        #expect(model.filter?.title == "*.dat" && model.sort.descending)
        #expect(model.items.first?.name == String(format: "f%06d.dat", count - 1))
    }

    /// A long list takes calculated sizes from the background, into the list and the figures.
    @Test
    internal func aLongListTakesCalculatedSizesFromTheBackground() async {
        let script = ScriptedFileSystem()
        script.inner.addDirectory("/long")
        let count = PanelViewController.backgroundSortThreshold + 100
        script.batches = [
            [script.item(named: "sub", in: "/long", isDirectory: true)] + files(count, in: "/long", of: script)
        ]
        script.batchesAt = [
            "/long/sub": [[FileItem(url: script.url("/long/sub/in.bin"), name: "in.bin", stat: .init(size: 7))]]
        ]
        let app = await program.start(plugins: program.standardPlugins, fileSystems: [script])
        defer { app.stop() }
        app.left.show(script.url("/long"))
        await PanelWait.until {
            app.left.model.isComplete && !app.left.isLoading && app.left.model.directory.path == "/long"
        }
        let model = app.left.model
        app.cursor(app.left, on: "sub")
        #expect(model.cursorItem?.name == "sub" && model.items.count == count + 1)
        app.left.toggleSelectionWithSize()
        #expect(await PanelWait.until { model.cursorItem?.computedSize != nil })
        #expect(model.selectedNames == ["sub"] && model.items.count == count + 1)
        #expect(model.totals.selectedBytes == model.cursorItem?.computedSize && model.totals.selectedFolders == 1)
        #expect(model.listedItems.first { $0.name == "sub" }?.computedSize == model.cursorItem?.computedSize)
    }

    /// A drag of very many marked items starts from the marks, as one pasteboard item, and the
    /// items are gathered behind; a handful of marks is listed at once.
    @Test
    internal func aDragOfVeryManyMarkedItemsStartsFromTheMarksAndGathersTheItemsBehind() async throws {
        let script = ScriptedFileSystem()
        let count = PanelDrop.itemsWrittenSingly + 1_500
        let app = await startInALongFolder(script, count: count)
        defer {
            app.stop()
            PanelDrop.endDrag()
            PanelDrop.endSession(nil)
        }
        let model = app.left.model
        model.selectAll()
        model.toggleSelection(row: 2)
        #expect(model.selectionCount == count - 1 && app.left.dragPayload(fromRow: 2)?.count == 1)
        let written = app.left.draggingItems(forRow: 5)
        let payload = try #require(PanelDrop.current)
        #expect(written.count == 1 && payload.count == count - 1 && payload.isWrittenLazily)
        let session = DropSession(sequence: 41, payload: payload)
        #expect(await PanelWait.until { payload.isReady && session.places != nil })
        #expect(session.sources.count == count - 1 && session.sources.first?.lastPathComponent == "f000000.txt")
        #expect(!session.sources.contains { $0.lastPathComponent == "f000001.dat" })
        #expect(
            session.isPointless(.move, into: script.url("/long"))
                && !session.isPointless(.copy, into: script.url("/elsewhere"))
        )
        model.clearSelection()
        model.setSelected(true, rows: 1...3)
        let few = app.left.dragPayload(fromRow: 2)
        #expect(few?.isReady == true && few?.isWrittenLazily == false)
        #expect(few?.items.map(\.name) == ["f000000.txt", "f000001.dat", "f000002.txt"])
    }
}
