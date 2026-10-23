import AFMContracts
import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The Places plugin beyond the usual way: damaged stored data, quitting, a full list, the
/// Favorites, rows that lead nowhere, and settings that are not numbers.
@MainActor
@Suite
internal struct CoveragePlacesPlugin {
    /// The file system of the panels: `/A/one.txt`, `/B/two.txt` and the folder `/C`.
    internal let memory = MemoryFileSystem()
    /// The settings the plugin reads and writes.
    internal let settings = MemorySettings()
    /// The plugin, with its trees in memory and the Desktop as its one Favorite.
    internal let plugin = PlacesPlugin(keepsTreesOnDisk: false, favorites: [.item("Desktop", command: "cd mem:/C")])

    /// The hotlist as it is stored in the settings.
    internal var hotlist: Hotlist {
        settings.scoped(to: "places").value(Hotlist.self, forKey: PlacesPlugin.Keys.hotlist) ?? Hotlist()
    }

    /// The files and folders of the panels.
    internal init() {
        memory.addFile("/A/one.txt")
        memory.addFile("/B/two.txt")
        memory.addDirectory("/C")
    }

    /// A kernel with the plugin, the left panel on `left`, the right one on `/B`.
    internal func bench(left: String) -> TestBench {
        TestBench(
            plugins: [plugin],
            fileSystems: [memory],
            left: memory.url(left),
            right: memory.url("/B"),
            settings: settings
        )
    }

    /// The answer to a list that picks `row` with the first button.
    internal func pick(_ row: Int) -> ScriptedInteraction.FormAnswer {
        .values(["row": .index(row)], button: 0)
    }

    /// Stores `list` as the hotlist, as the plugin would.
    internal func store(_ list: Hotlist) {
        settings.scoped(to: "places").set(list, forKey: PlacesPlugin.Keys.hotlist)
    }

    /// The messages `bench` showed, in order.
    internal func informs(_ bench: TestBench) -> [String] { bench.interaction.log.filter { $0.hasPrefix("inform:") } }

    /// Damaged stored data is reported once for each message, after the start, not from a block of the main queue.
    @Test
    internal func damagedStoredDataIsReportedOncePerMessage() async {
        settings.set(Data("{broken".utf8) as Data?, forKey: "places.history.left")
        settings.set(Data("{broken".utf8) as Data?, forKey: "places.hotlist")
        let bench = bench(left: "/A")
        // The message waits for the main run loop: a question from a block of the main queue
        // would hold up the queue.
        #expect(informs(bench).isEmpty)
        #expect(await RunLoopWait.until { informs(bench).count == 1 })
        bench.commands.perform(.directoryHotlist)
        bench.commands.perform(.directoryHotlist)
        #expect(await RunLoopWait.until { informs(bench).count == 2 })
        await CoveragePlacesLoop.settle()
        #expect(
            informs(bench) == ["inform: Some saved data could not be read", "inform: Some saved data could not be read"]
        )
    }

    /// Quitting writes the history and the trees away from the main thread and then says it is done.
    @Test
    internal func quittingWritesTheHistoryAndTheTreesAwayFromTheMainThread() async {
        let bench = bench(left: "/A")
        bench.left.show(memory.url("/C"))
        bench.kernel.panelEvents.post(.locationChanged, from: bench.left)
        let done = Shared(false)
        plugin.prepareToQuit(cancellation: CancellationFlag()) { done.value = true }
        #expect(await RunLoopWait.until { done.value })
        plugin.stop()
        let stored = settings.scoped(to: "places").value(DirectoryHistory.self, forKey: "history.left")
        #expect(stored?.current == memory.url("/C"))
    }

    /// With saving switched off the history is not written when the plugin stops.
    @Test
    internal func withoutSavingTheHistoryIsNotWrittenOnQuit() {
        settings.set(false, forKey: PlacesPlugin.Keys.saveHistory)
        let bench = bench(left: "/A")
        bench.kernel.panelEvents.post(.locationChanged, from: bench.right)
        plugin.stop()
        #expect(settings.data(forKey: "places.history.right") == nil)
    }

    /// By default the trees are kept in the program's own folder of Application Support.
    @Test
    internal func treesGoToTheProgramsOwnFolderByDefault() {
        let usual = PlacesPlugin()
        _ = TestBench(plugins: [usual], fileSystems: [memory], left: memory.url("/A"), right: memory.url("/B"))
        let file = usual.treeCache.fileURL(for: memory.url("/"))
        #expect(file?.deletingLastPathComponent().path.hasSuffix("Application Support/Test/TreeCache") == true)
    }

    /// A full hotlist takes no further entry and says so.
    @Test
    internal func aFullListTakesNoMoreAndSaysSo() {
        store(Hotlist(entries: (0..<Hotlist.limit).map { .item("e\($0)", command: "cd mem:/e\($0)") }))
        let bench = bench(left: "/A")
        bench.commands.perform(.toggleHotlistEntry)
        #expect(informs(bench) == ["inform: The directory hotlist is full."] && hotlist.count == Hotlist.limit)
    }

    /// The root of a file system is added under its whole path, having no name of its own.
    @Test
    internal func theRootIsAddedUnderItsWholePath() {
        let bench = bench(left: "/")
        bench.commands.perform(.toggleHotlistEntry)
        let path = bench.kernel.fileSystems.displayPath(memory.url("/"))
        #expect(hotlist.entries == [.item(path, command: "cd " + path)])
    }

    /// Cancel in the Favorites leads back to the hotlist.
    @Test
    internal func cancelInTheFavoritesLeadsBackToTheList() {
        let bench = bench(left: "/A")
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

    /// An entry with a target but no command moves only the other panel.
    @Test
    internal func anEntryWithoutACommandOnlyMovesTheOtherPanel() {
        store(Hotlist(entries: [.item("Target only", command: "", target: "cd mem:/C")]))
        let bench = bench(left: "/A")
        bench.interaction.formAnswers = [pick(0)]
        bench.commands.perform(.directoryHotlist)
        #expect(bench.left.model.directory == memory.url("/A") && bench.right.model.directory == memory.url("/C"))
    }

    /// Picking the separator of the history list goes nowhere and shows the list again.
    @Test
    internal func theSeparatorOfTheHistoryLeadsNowhere() {
        let bench = bench(left: "/A")
        bench.interaction.formAnswers = [pick(1), .cancel]
        bench.commands.perform(.directoryHistory)
        #expect(bench.interaction.forms.count == 2 && bench.left.model.directory == memory.url("/A"))
    }

    /// A history length that is no number in the settings is read as the default.
    @Test
    internal func aMaximumThatIsNoNumberTakesTheDefault() {
        settings.set("lots", forKey: PlacesPlugin.Keys.historyShown)
        let bench = bench(left: "/A")
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

    /// The tree command opens one window and shows the same one again; the plugin stops its scan.
    @Test
    internal func theTreeCommandOpensOneWindowAndReusesIt() {
        _ = NSApplication.shared
        let bench = bench(left: "/A")
        let presenter = StabilityPresenter()
        plugin.present = presenter.present
        defer { presenter.closeAll() }
        bench.commands.perform(.directoryTree)
        let first = plugin.treeWindow
        bench.commands.perform(.directoryTree)
        #expect(first != nil && plugin.treeWindow === first && presenter.isOpen(first?.window))
        #expect(presenter.presented.count == 2)
        // A scan it started ends with the plugin.
        plugin.stop()
        #expect(!presenter.isOpen(first?.window))
    }
}
