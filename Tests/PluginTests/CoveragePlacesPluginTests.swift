import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The Places plugin beyond the usual way: damaged stored data, quitting, a full list, the
/// Favorites, rows that lead nowhere, and settings that are not numbers.
@MainActor @Suite struct CoveragePlacesPlugin {
    let memory = MemoryFileSystem()
    let settings = MemorySettings()
    let plugin = PlacesPlugin(keepsTreesOnDisk: false, favorites: [.item("Desktop", command: "cd mem:/C")])

    init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/two.txt")
        memory.addDirectory("/C")
    }

    func bench(left: String = "/A") -> TestBench {
        TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url(left),
            right: memory.url("/B"),
            settings: settings
        )
    }

    func pick(_ row: Int, button: Int = 0) -> ScriptedInteraction.FormAnswer {
        .values(["row": .index(row)], button: button)
    }

    func store(_ list: Hotlist) {
        settings.scoped(to: "places").set(list, forKey: PlacesPlugin.Keys.hotlist)
    }

    var hotlist: Hotlist {
        settings.scoped(to: "places").value(Hotlist.self, forKey: PlacesPlugin.Keys.hotlist) ?? Hotlist()
    }

    func informs(_ bench: TestBench) -> [String] { bench.interaction.log.filter { $0.hasPrefix("inform:") } }

    @Test func damagedStoredDataIsReportedOncePerMessage() async {
        settings.set(Data("{broken".utf8) as Data?, forKey: "places.history.left")
        settings.set(Data("{broken".utf8) as Data?, forKey: "places.hotlist")
        let bench = bench()
        // The message waits for the main run loop: a question from a block of the main queue
        // would hold up the queue.
        #expect(informs(bench).isEmpty)
        #expect(await CoveragePlacesLoop.spin { informs(bench).count == 1 })
        bench.commands.perform(.directoryHotlist)
        bench.commands.perform(.directoryHotlist)
        #expect(await CoveragePlacesLoop.spin { informs(bench).count == 2 })
        await CoveragePlacesLoop.settle()
        #expect(
            informs(bench) == ["inform: Some saved data could not be read", "inform: Some saved data could not be read"]
        )
    }

    @Test func quittingWritesTheHistoryAndTheTreesAwayFromTheMainThread() async {
        let bench = bench()
        bench.left.show(memory.url("/C"))
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        let done = Shared(false)
        plugin.prepareToQuit(cancellation: CancellationFlag()) { done.value = true }
        #expect(await CoveragePlacesLoop.spin { done.value })
        plugin.stop()
        let stored = settings.scoped(to: "places").value(DirectoryHistory.self, forKey: "history.left")
        #expect(stored?.current == memory.url("/C"))
    }

    @Test func withoutSavingTheHistoryIsNotWrittenOnQuit() {
        settings.set(false, forKey: PlacesPlugin.Keys.saveHistory)
        let bench = bench()
        bench.kernel.panelEvents.post(.locationChanged, from: bench.right)
        plugin.stop()
        #expect(settings.data(forKey: "places.history.right") == nil)
    }

    @Test func treesGoToTheProgramsOwnFolderByDefault() {
        let plugin = PlacesPlugin()
        _ = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
        let file = plugin.treeCache.fileURL(for: memory.url("/"))
        #expect(file?.deletingLastPathComponent().path.hasSuffix("Application Support/Test/TreeCache") == true)
    }

    @Test func aFullListTakesNoMoreAndSaysSo() {
        store(Hotlist(entries: (0..<Hotlist.limit).map { .item("e\($0)", command: "cd mem:/e\($0)") }))
        let bench = bench()
        bench.commands.perform(.toggleHotlistEntry)
        #expect(informs(bench) == ["inform: The directory hotlist is full."] && hotlist.count == Hotlist.limit)
    }

    @Test func theRootIsAddedUnderItsWholePath() {
        let bench = bench(left: "/")
        bench.commands.perform(.toggleHotlistEntry)
        let path = bench.kernel.fileSystems.displayPath(memory.url("/"))
        #expect(hotlist.entries == [.item(path, command: "cd " + path)])
    }

    @Test func cancelInTheFavoritesLeadsBackToTheList() {
        let bench = bench()
        bench.interaction.formAnswers = [pick(0), .cancel, pick(1)]
        bench.commands.perform(.directoryHotlist)
        #expect(
            bench.interaction.log == [
                "form: Directory Hotlist", "form: Directory Hotlist › Favorites", "form: Directory Hotlist"
            ]
        )
        // The second form added the current directory.
        #expect(hotlist.entries == [.item("A", command: "cd mem:/A")])
    }

    @Test func anEntryWithoutACommandOnlyMovesTheOtherPanel() {
        store(Hotlist(entries: [.item("Target only", command: "", target: "cd mem:/C")]))
        let bench = bench()
        bench.interaction.formAnswers = [pick(0)]
        bench.commands.perform(.directoryHotlist)
        #expect(bench.left.model.directory == memory.url("/A") && bench.right.model.directory == memory.url("/C"))
    }

    @Test func theSeparatorOfTheHistoryLeadsNowhere() {
        let bench = bench()
        bench.interaction.formAnswers = [pick(1), .cancel]
        bench.commands.perform(.directoryHistory)
        #expect(bench.interaction.forms.count == 2 && bench.left.model.directory == memory.url("/A"))
    }

    @Test func aMaximumThatIsNoNumberTakesTheDefault() {
        settings.set("lots", forKey: PlacesPlugin.Keys.historyShown)
        let bench = bench()
        for path in ["/B", "/C", "/A"] {
            bench.left.show(memory.url(path))
            bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        }
        bench.interaction.formAnswers = [.cancel]
        bench.commands.perform(.directoryHistoryUnthinned)
        bench.commands.perform(.directoryHistory)
        guard case .list(let rows, _)? = bench.interaction.forms.last?.first?.kind else {
            Issue.record("no list shown")
            return
        }
        // Passed through quickly: only the current folder stays under thinning, but the
        // frequently used folders list them all.
        #expect(rows.count == 5 && rows.first == "➤ mem:/A")
    }
}
