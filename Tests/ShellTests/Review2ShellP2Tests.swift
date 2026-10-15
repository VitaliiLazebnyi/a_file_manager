import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// A plugin that has a say when the program quits: it can refuse, and it can take its time
/// finishing, until it is told or until the user does not want to wait.
private final class QuitTestPlugin: Plugin {
    let name = "QuitTest"
    var allowsQuit = true
    var asked = 0
    /// What `prepareToQuit` was handed, while it has not called its completion.
    private(set) var pending: (flag: CancellationFlag, completion: () -> Void)?
    private(set) var prepared = 0
    /// Finishes by itself as soon as it is told not to keep the user waiting.
    var givesUpWhenTold = true
    /// Finishes at once, like a plugin with nothing to write.
    var hasNothingToDo = false
    private var registration: AnyObject?

    func start(in _: Kernel) {}

    func shouldTerminate() -> Bool {
        asked += 1
        return allowsQuit
    }

    func prepareToQuit(cancellation: CancellationFlag, completion: @escaping @Sendable () -> Void) {
        prepared += 1
        guard !hasNothingToDo else {
            completion()
            return
        }
        pending = (cancellation, completion)
        if givesUpWhenTold {
            registration = cancellation.onCancel { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.finish() }
            }
        }
    }

    func finish() {
        let completion = pending?.completion
        pending = nil
        completion?()
    }
}

/// Whoever connects to servers, hearing which addresses the user typed.
private final class ConsentPlugin: Plugin, ServerConsentService {
    let name = "ConsentTest"
    var chosen: [URL] = []
    var ranLines: [String] = []

    func start(in kernel: Kernel) {
        kernel.services.register((any ServerConsentService).self, self)
        kernel.commands.register(
            Command(.runCommandLine, "Run Command Line"),
            parameterized: { [self] in ranLines.append($0.text ?? "?") }
        )
    }

    func userChose(_ location: URL) { chosen.append(location) }
}

/// A file system that says it connects to a server; otherwise a memory file system's.
private final class ServerFileSystem: FileSystemProvider {
    let inner = MemoryFileSystem(scheme: "srv")
    private let listed = Shared<[String]>([])
    /// The folders that were listed, in order.
    var listings: [String] { listed.value }
    var connectsToServer: Bool { true }
    var scheme: String { inner.scheme }
    var capabilities: FileSystemCapabilities { inner.capabilities }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        listed.change { $0.append(directory.path) }
        return try inner.list(directory, showHidden: showHidden)
    }
    func item(at url: URL) -> FileItem? { inner.item(at: url) }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader { try inner.read(url) }
    func createDirectory(at url: URL) throws { inner.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try inner.write(url) }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }
}

/// Counts on which threads a filter was asked.
private final class FilterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain = 0, elsewhere = 0

    func note() {
        lock.lock()
        if Thread.isMainThread { onMain += 1 } else { elsewhere += 1 }
        lock.unlock()
    }

    var counts: (onMain: Int, elsewhere: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (onMain, elsewhere)
    }
    func reset() {
        lock.lock()
        (onMain, elsewhere) = (0, 0)
        lock.unlock()
    }
}

/// The second pass of review round 2, through the real program: long lists change in the
/// background and are only taken over on the main thread, quitting asks the plugins and
/// waits for them where the user can see it, and a drag of very many marked items starts
/// without a pass over the list.
extension Application {
    fileprivate func start(plugins extra: [any Plugin], fileSystems: [any FileSystemProvider] = []) async -> Running {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, interaction: ui)
        kernel.fileSystems.register(memory)
        fileSystems.forEach(kernel.fileSystems.register)
        // Without the plugins that run command lines and hear of typed addresses where a
        // test brings its own.
        let replaced = extra.contains { $0 is ConsentPlugin } ? ["SystemToolsPlugin", "NetworkPlugin"] : []
        let standard = StandardPlugins.make(pasteboard: scratch.pasteboard, launchesApplications: false)
            .filter { !replaced.contains(String(describing: type(of: $0))) }
        kernel.load(standard + extra)
        let running = Running(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await settle(running)
        return running
    }

    /// A folder of `count` files on a scripted file system, already listed in the left panel.
    private func startInALongFolder(_ script: ScriptedFileSystem, count: Int) async -> Running {
        script.inner.addDirectory("/long")
        script.batches = [
            (0..<count)
                .map {
                    script.item(named: String(format: "f%06d.%@", $0, $0 % 2 == 0 ? "txt" : "dat"), in: "/long")
                }
        ]
        let app = await start(with: script)
        app.left.show(script.url("/long"))
        await wait(upTo: 60) {
            app.left.model.directory.path == "/long" && app.left.model.isComplete && !app.left.isLoading
        }
        return app
    }

    // MARK: Long lists change in the background (S001, S018, S039; kernel requests 1 and 2)

    @Test func aLongFolderIsEnteredAtOnceAndArrivesWholeFromTheBackground() async {
        let script = ScriptedFileSystem()
        let count = PanelViewController.backgroundSortThreshold + 5_000
        let app = await startInALongFolder(script, count: count)
        defer { app.stop() }
        let model = app.left.model
        #expect(model.items.count == count && model.isComplete && !model.isOpening && !app.left.isLoading)
        #expect(model.totals.totalFiles == count)
        #expect(app.left.statusLineText.contains("\(count) file(s)"))
        // The list is in order, as the reader sorted it.
        #expect(
            model.items.first?.name == "f000000.txt"
                && model.items.last?.name == String(format: "f%06d.dat", count - 1)
        )
    }

    @Test func filteringAndReadingALongListAgainNeverAsksTheFilterOnTheMainThread() async {
        let script = ScriptedFileSystem()
        let count = PanelViewController.backgroundSortThreshold + 2_000
        let app = await startInALongFolder(script, count: count)
        defer { app.stop() }
        let model = app.left.model
        let probe = FilterProbe()
        let filter = PanelFilter(title: "*.txt") { item in
            probe.note()
            return item.name.hasSuffix(".txt")
        }
        // Marked before the filter: the marks of what stays shown are kept.
        let marked = ["f000002.txt", "f000004.txt"]
        model.setSelected(true, names: marked)
        #expect(app.left.setFilter(filter, of: model) == false)
        let filtered = await wait(upTo: 60) { model.items.count == count / 2 }
        #expect(filtered && probe.counts.onMain == 0 && probe.counts.elsewhere >= count)
        #expect(model.filter?.title == "*.txt" && model.selectedNames.sorted() == marked)

        // The folder changes and is read again, quietly: the fresh list is compared, filtered
        // and the marks found again in the background.
        probe.reset()
        var fresh = script.batches[0]
        fresh.removeAll { $0.name == "f000004.txt" }
        fresh.append(script.item(named: "zz-new.txt", in: "/long"))
        script.batches = [fresh]
        var reloaded = false
        app.left.reload(focus: nil, quietly: true) { reloaded = true }
        let done = await wait(upTo: 60) { reloaded }
        #expect(done && model.items.count == count / 2 && model.items.last?.name == "zz-new.txt")
        #expect(model.row(ofName: "f000004.txt") == nil && model.selectedNames == ["f000002.txt"])
        #expect(probe.counts.onMain == 0 && probe.counts.elsewhere >= count)
        #expect(model.isComplete && !app.left.isLoading)

        // Read again with nothing changed: nothing is announced, and nothing filtered here.
        probe.reset()
        var contents = 0
        let before = model.onChange
        model.onChange = { change in
            if change == .contents { contents += 1 }
            before?(change)
        }
        reloaded = false
        await wait(upTo: 10) { !app.left.hasPendingReread }
        app.left.reload(focus: nil, quietly: false) { reloaded = true }
        let again = await wait(upTo: 60) { reloaded }
        #expect(again && contents == 0 && probe.counts.onMain == 0 && model.selectedNames == ["f000002.txt"])
    }

    @Test func piecesOfALongFolderThatArriveUnderAFilterAreFilteredInTheBackground() async {
        let script = ScriptedFileSystem()
        script.inner.addDirectory("/long")
        script.inner.addDirectory("/small")
        let count = PanelViewController.backgroundSortThreshold + 4_000
        let all = (0..<count)
            .map {
                script.item(named: String(format: "f%06d.%@", $0, $0 % 2 == 0 ? "txt" : "dat"), in: "/long")
            }
        // A first piece of two batches, then the rest only when the test lets it come.
        script.batches = [Array(all[..<600]), Array(all[600..<1_000]), Array(all[1_000...])]
        script.batchesAt = ["/small": [[script.item(named: "s.txt", in: "/small")]]]
        script.pauseBeforeSecondBatch = 0.3
        script.holdBefore = 2
        let app = await start(with: script)
        defer { app.stop() }
        app.left.show(script.url("/small"))
        await settle(app)
        let model = app.left.model
        let probe = FilterProbe()
        model.setFilter(
            PanelFilter(title: "*.txt") { item in
                probe.note()
                return item.name.hasSuffix(".txt")
            }
        )
        probe.reset()
        app.left.show(script.url("/long"))
        let first = await wait(upTo: 60) { model.directory.path == "/long" && model.items.count == 500 }
        #expect(first && !model.isComplete && app.left.isLoading)
        // What the first, short piece cost the main thread is bounded by that piece.
        #expect(probe.counts.onMain <= 1_000)
        probe.reset()
        model.setSelected(true, names: ["f000010.txt"])
        script.open()
        let whole = await wait(upTo: 60) { model.isComplete && !app.left.isLoading }
        #expect(whole && model.items.count == count / 2 && model.selectedNames == ["f000010.txt"])
        #expect(probe.counts.onMain == 0 && probe.counts.elsewhere >= count)
    }

    @Test func aFilterThatIsOvertakenByAnotherOrderIsWorkedOutAgainAndLands() async {
        let script = ScriptedFileSystem()
        let count = PanelViewController.backgroundSortThreshold + 1_000
        let app = await startInALongFolder(script, count: count)
        defer { app.stop() }
        let model = app.left.model
        #expect(app.left.setFilter(PanelFilter.mask("*.dat"), of: model) == false)
        // The order changes while the filter is being worked out: its result is for a list
        // that is gone, and it is worked out again, not applied and not dropped.
        model.setSort(ListOrder(key: .name, descending: true))
        let landed = await wait(upTo: 60) { model.items.count == count / 2 && app.left.filterJobs.isEmpty }
        #expect(landed && model.filter?.title == "*.dat" && model.sort.descending)
        #expect(model.items.first?.name == String(format: "f%06d.dat", count - 1))
    }

    @Test func aQuickFilterComesBackWithTheFolderWhenTheNextOneCannotBeRead() async {
        memory.addFile("/here/alpha.txt")
        memory.addFile("/here/beta.txt")
        memory.addDirectory("/here/locked")
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/here"))
        await settle(app)
        app.left.showQuickFilter()
        app.left.quickFilterTyped("a")
        #expect(app.names(app.left) == ["alpha.txt", "beta.txt"])
        app.left.quickFilterTyped("al")
        #expect(app.names(app.left) == ["alpha.txt"] && app.left.quickFilterText == "al")
        // The folder that is entered answers late, and with an error: the panel has entered
        // it empty by then (which takes the quick filter away) and goes back.
        memory.unreadable = ["/here/locked"]
        memory.listStartDelay = 1.5
        app.left.show(memory.url("/here/locked"))
        let entered = await wait(upTo: 1.4) { app.left.model.isOpening }
        await wait(upTo: 30) { !app.left.isLoading }
        memory.listStartDelay = 0
        #expect(app.left.model.directory.path == "/here")
        // Where the panel had entered the folder, the filter was gone meanwhile and is back,
        // text and list; on a machine too busy to see that, it never left.
        if entered { #expect(app.left.quickFilterText == "al") }
        #expect(app.names(app.left) == ["alpha.txt"] && app.left.quickFilterText == "al")
        #expect(app.left.model.filter?.title == "⏷ al")
        // Esc still takes it away.
        app.left.removeQuickFilter()
        #expect(app.names(app.left) == ["locked", "alpha.txt", "beta.txt"] && app.left.model.filter == nil)
    }

    // MARK: Dragging very many marked items (S055, F002; shell request 1)

    @Test func aDragOfVeryManyMarkedItemsStartsFromTheMarksAndGathersTheItemsBehind() async {
        let script = ScriptedFileSystem()
        let count = PanelDrop.itemsWrittenSingly + 1_500
        let app = await startInALongFolder(script, count: count)
        defer {
            app.stop()
            PanelDrop.endDrag()
            PanelDrop.endSession()
        }
        let model = app.left.model
        model.selectAll()
        model.toggleSelection(row: 2)
        #expect(model.selectionCount == count - 1)
        // An unmarked row drags itself.
        #expect(app.left.dragPayload(fromRow: 2)?.count == 1)
        // A marked row drags the marks: one pasteboard item, whatever their number.
        let written = app.left.draggingItems(forRow: 5)
        #expect(written.count == 1)
        let payload = PanelDrop.current
        #expect(payload?.count == count - 1 && payload?.isWrittenLazily == true)
        // The session of the drag takes the sources when they have been put together.
        let session = DropSession(sequence: 41, payload: payload!)
        let ready = await wait(upTo: 60) { payload?.isReady == true && session.isReady }
        #expect(ready && session.sources.count == count - 1)
        #expect(
            session.sources.first?.lastPathComponent == "f000000.txt"
                && !session.sources.contains { $0.lastPathComponent == "f000001.dat" }
        )
        #expect(
            session.isPointless(.move, into: script.url("/long"))
                && !session.isPointless(.copy, into: script.url("/elsewhere"))
        )

        // A drop that comes before the background has got there is not turned away.
        PanelDrop.endDrag()
        let hasty = PanelDrop.Payload(marked: model.operandsSnapshot())
        let early = DropSession(sequence: 42, payload: hasty)
        early.finishNow()
        #expect(early.isReady && early.sources.count == count - 1 && hasty.items.count == count - 1)
        // A handful of marks is listed at once and written item by item.
        model.clearSelection()
        model.setSelected(true, rows: 1...3)
        let few = app.left.dragPayload(fromRow: 2)
        #expect(
            few?.isReady == true && few?.isWrittenLazily == false
                && few?.items.map(\.name) == ["f000000.txt", "f000001.dat", "f000002.txt"]
        )
    }

    // MARK: Quitting (tools 1, archives 1, fileops 6, shell 6)

    @Test func aPluginCanCallTheQuitOffBeforeAnythingIsStopped() async {
        let plugin = QuitTestPlugin()
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        plugin.allowsQuit = false
        #expect(app.shell.mayQuit() == false && plugin.asked == 1 && plugin.prepared == 0)
        plugin.allowsQuit = true
        #expect(app.shell.mayQuit() == true && plugin.asked == 2)
    }

    @Test func quittingWaitsForThePluginsAndShowsThatItDoes() async {
        let plugin = QuitTestPlugin()
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        var reply: Bool?
        app.shell.finishToQuit(patience: 30, progressDelay: 0.05) { reply = $0 }
        let asked = await wait { plugin.pending != nil }
        #expect(asked && reply == nil && plugin.prepared == 1)
        // After a moment the user is told; nothing has been decided.
        let due = await wait { app.shell.quitProgress?.isDue == true }
        #expect(due && reply == nil && plugin.pending?.flag.isCancelled == false)
        #expect(app.shell.quitProgress?.text == QuitProgress.waitingText)
        weak let progress = app.shell.quitProgress
        // The plugin is done: the program quits, and the notice is gone.
        plugin.finish()
        let answered = await wait { reply != nil }
        #expect(answered && reply == true && app.shell.quitProgress == nil)
        #expect(progress == nil)
    }

    @Test func quitNowTellsThePluginsNotToKeepTheUserWaiting() async {
        let plugin = QuitTestPlugin()
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        var reply: Bool?
        app.shell.finishToQuit(patience: 30, progressDelay: 0.01) { reply = $0 }
        _ = await wait { plugin.pending != nil && app.shell.quitProgress?.isDue == true }
        let flag = plugin.pending?.flag
        app.shell.quitProgress?.pressQuitNow()
        #expect(flag?.isCancelled == true)
        let answered = await wait { reply != nil }
        #expect(answered && reply == true && plugin.pending == nil)
    }

    @Test func aPluginThatDoesNotEvenGiveUpIsNotWaitedForForEver() async {
        let plugin = QuitTestPlugin()
        plugin.givesUpWhenTold = false
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        var reply: Bool?
        app.shell.finishToQuit(patience: 0.1, progressDelay: 0.01) { reply = $0 }
        _ = await wait { plugin.pending != nil && app.shell.quitProgress != nil }
        // Waiting alone ends nothing.
        await wait(upTo: 0.4) { false }
        #expect(reply == nil)
        app.shell.quitProgress?.pressQuitNow()
        #expect(app.shell.quitProgress?.isStopping == true && app.shell.quitProgress?.text == QuitProgress.stoppingText)
        let answered = await wait { reply != nil }
        #expect(answered && reply == true && plugin.pending?.flag.isCancelled == true)
        // The plugin's late answer changes nothing.
        plugin.finish()
        await wait(upTo: 0.1) { false }
        #expect(reply == true)
    }

    @Test func notQuittingAfterAllLeavesTheProgramInUse() async {
        let plugin = QuitTestPlugin()
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        var replies: [Bool] = []
        app.shell.finishToQuit(patience: 30, progressDelay: 0.01) { replies.append($0) }
        _ = await wait { plugin.pending != nil && app.shell.quitProgress != nil }
        // While the quit is under way, a second request is turned away.
        #expect(app.shell.mayQuit() == false)
        let flag = plugin.pending?.flag
        app.shell.quitProgress?.pressDontQuit()
        #expect(replies == [false] && app.shell.quitProgress == nil && flag?.isCancelled == false)
        // The plugin goes on writing and finishes; nobody quits.
        plugin.finish()
        await wait(upTo: 0.2) { false }
        #expect(replies == [false] && !app.shell.jobService.isQuitting)
        // Jobs run again, and the program can be quit again.
        var ran = false
        app.kernel.jobs.run(title: "After", work: { _ in 1 }, completion: { _ in ran = true })
        await wait { ran }
        #expect(ran && app.shell.mayQuit())
        plugin.hasNothingToDo = true
        app.shell.finishToQuit(patience: 30, progressDelay: 5) { replies.append($0) }
        let quit = await wait { replies.count == 2 }
        #expect(quit && replies == [false, true] && app.shell.quitProgress == nil)
    }

    @Test func quittingStopsTheJobsFirstAndThenLetsThePluginsFinish() async {
        let plugin = QuitTestPlugin()
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        let stopped = Shared(false)
        app.kernel.jobs.run(
            title: "Long",
            work: { monitor in
                while !monitor.cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
                stopped.value = true
            },
            completion: { _ in }
        )
        var order: [String] = []
        app.shell.finishToQuit(patience: 30, progressDelay: 5) { order.append("reply \($0)") }
        let prepared = await wait { plugin.pending != nil }
        // The plugins are asked to finish only when no job runs any more.
        #expect(prepared && stopped.value && !app.kernel.jobs.isBusy && order.isEmpty)
        plugin.finish()
        let answered = await wait { !order.isEmpty }
        #expect(answered && order == ["reply true"])
    }

    // MARK: Start-up (config-b: restored tabs)

    @Test func aTabOnAServerIsNotTheOneInFrontWhenTheProgramStarts() async {
        let server = ServerFileSystem()
        server.inner.addFile("/pub/a.txt")
        let remote = PanelTabState(location: server.inner.url("/pub"))
        // The left panel was left on the server with a local tab behind; the right one has
        // nothing but the server.
        settings.set(PanelTabs.State(tabs: [remote, .init(location: box.url("A"))], active: 0), forKey: "left.tabs")
        settings.set(PanelTabs.State(tabs: [remote], active: 0), forKey: "right.tabs")
        let app = await start(plugins: [], fileSystems: [server])
        defer { app.stop() }
        #expect(
            app.left.tabs.count == 2 && app.left.tabs.activeIndex == 1
                && app.left.model.directory.lastPathComponent == "A"
        )
        #expect(
            app.right.tabs.count == 2 && app.right.tabs.activeIndex == 0
                && app.right.model.directory.lastPathComponent == "home"
        )
        #expect(app.names(app.right) == ["welcome.txt"])
        // Nobody asked the server anything, and the tabs kept their places.
        #expect(server.listings.isEmpty && app.right.tabs.tabs[1].directory.path == "/pub")
        // Going to the tab is the user's own doing, and connects.
        app.right.focus()
        app.commands.perform(.activateTab, .index(1))
        let read = await wait { app.right.model.isComplete && !app.right.isLoading }
        // (Once at least: a folder whose watch took long to set up is read once more.)
        #expect(
            read && app.names(app.right) == ["a.txt"] && !server.listings.isEmpty
                && server.listings.allSatisfy { $0 == "/pub" }
        )
    }

    @Test func aLongListTakesCalculatedSizesFromTheBackground() async {
        let script = ScriptedFileSystem()
        script.inner.addDirectory("/long")
        let count = PanelViewController.backgroundSortThreshold + 100
        script.batches = [
            [script.item(named: "sub", in: "/long", isDirectory: true)]
                + (0..<count).map { script.item(named: String(format: "f%06d.txt", $0), in: "/long") }
        ]
        script.batchesAt = [
            "/long/sub": [[FileItem(url: script.url("/long/sub/in.bin"), name: "in.bin", stat: .init(size: 7))]]
        ]
        let app = await start(with: script)
        defer { app.stop() }
        app.left.show(script.url("/long"))
        await wait(upTo: 60) {
            app.left.model.isComplete && !app.left.isLoading && app.left.model.directory.path == "/long"
        }
        let model = app.left.model
        app.cursor(app.left, on: "sub")
        #expect(model.cursorItem?.name == "sub" && model.items.count == count + 1)
        app.left.toggleSelectionWithSize()
        let sized = await wait(upTo: 60) { model.cursorItem?.computedSize != nil }
        #expect(sized && model.selectedNames == ["sub"] && model.items.count == count + 1)
        // The size is in the list and in the figures of the status line.
        #expect(model.totals.selectedBytes == model.cursorItem?.computedSize && model.totals.selectedFolders == 1)
        #expect(model.listedItems.first { $0.name == "sub" }?.computedSize == model.cursorItem?.computedSize)
    }

    // MARK: The command line (C053, network request 4)

    @Test func aLineThatBeginsWithABlankIsRunAndNotRemembered() async {
        let plugin = ConsentPlugin()
        let app = await start(plugins: [plugin])
        defer { app.stop() }
        let line = app.shell.mainWindow.commandLine
        line.text = "echo one"
        #expect(line.execute() && plugin.ranLines == ["echo one"] && line.history.entries == ["echo one"])
        // Whoever runs the line sees the blank, so that it can keep to the same rule.
        line.text = " curl -u me:secret host"
        #expect(line.execute() && plugin.ranLines.last == " curl -u me:secret host")
        #expect(line.history.entries == ["echo one"] && line.field.objectValues.count == 1)
        #expect(CommandLineHistory(settings: settings).entries == ["echo one"])
        // Switched off, nothing is remembered and what was goes.
        settings.set(false, forKey: CommandLineHistory.recordKey)
        line.text = "echo two"
        #expect(line.execute() && plugin.ranLines.last == "echo two")
        #expect(line.history.entries.isEmpty && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
        #expect(line.field.objectValues.isEmpty)
        settings.set(true, forKey: CommandLineHistory.recordKey)
        line.text = "echo three"
        #expect(line.execute() && line.history.entries == ["echo three"])
    }

    @Test func anAddressTypedOnTheCommandLineIsTheUsersOwnChoice() async {
        let plugin = ConsentPlugin()
        let server = ServerFileSystem()
        server.inner.addFile("/pub/a.txt")
        let app = await start(plugins: [plugin], fileSystems: [server])
        defer { app.stop() }
        let line = app.shell.mainWindow.commandLine
        // A local folder is nobody's business.
        line.text = "cd " + box.url("B").path
        #expect(line.execute() && plugin.chosen.isEmpty)
        await settle(app)
        line.text = "cd srv://host/pub"
        #expect(line.execute())
        #expect(plugin.chosen.map(\.absoluteString) == ["srv://host/pub"])
        await settle(app)
        // A location that was not typed (a panel command, a restored tab) is not reported.
        app.left.show(server.inner.url("/"))
        await settle(app)
        #expect(plugin.chosen.count == 1)
    }
}

/// The parts of the second pass that need no running program.
@MainActor @Suite struct Review2ShellP2Parts {
    init() {
        _ = NSApplication.shared
    }

    private func keys(_ alert: NSAlert) -> [String] { alert.buttons.map(\.keyEquivalent) }

    // MARK: The button Return presses (F055, N030; fileops 5, network 3, kernel 4)

    @Test func returnNeverAnswersACriticalQuestionWithYes() {
        let ui = AlertInteraction()
        // An ordinary question: Return is the first button, Esc the last.
        #expect(AlertInteraction.defaultButton(for: .warning, of: ["Replace", "Skip", "Cancel"]) == 0)
        let ordinary = ui.makeQuestion(
            "Replace?",
            detail: "",
            buttons: ["Replace", "Skip", "Cancel"],
            style: .warning,
            defaultButton: AlertInteraction.defaultButton(for: .warning, of: ["Replace", "Skip", "Cancel"])
        )
        #expect(keys(ordinary) == ["\r", "", "\u{1b}"])
        // A critical one: Return is the last button, the one that changes nothing.
        #expect(AlertInteraction.defaultButton(for: .critical, of: ["Yes", "No"]) == 1)
        let critical = ui.makeQuestion(
            "Permanently delete?",
            detail: "",
            buttons: ["Yes", "No"],
            style: .critical,
            defaultButton: AlertInteraction.defaultButton(for: .critical, of: ["Yes", "No"])
        )
        #expect(keys(critical) == ["", "\r"] && critical.alertStyle == .critical)
        // A critical message with one button is still answered with Return.
        #expect(
            AlertInteraction.defaultButton(for: .critical, of: ["OK"]) == 0
                && AlertInteraction.defaultButton(for: .critical, of: []) == nil
        )
    }

    @Test func theCallerSaysWhichButtonReturnPressesOrThatNoneDoes() {
        let ui = AlertInteraction()
        let middle = ui.makeQuestion(
            "Overwrite?",
            detail: "",
            buttons: ["Overwrite", "Skip", "Cancel"],
            style: .warning,
            defaultButton: 1
        )
        #expect(keys(middle) == ["", "\r", "\u{1b}"])
        // No default at all: Return presses nothing, Esc still the last, and the keyboard
        // starts on the button that changes nothing.
        let none = ui.makeQuestion(
            "Trust the new certificate?",
            detail: "",
            buttons: ["Trust", "Cancel"],
            style: .critical,
            defaultButton: nil
        )
        #expect(keys(none) == ["", "\u{1b}"] && none.window.initialFirstResponder === none.buttons.last)
        // A button titled like one the system gives a key of its own gets none here.
        let titled = ui.makeQuestion(
            "Close?",
            detail: "",
            buttons: ["Cancel", "Don't Save", "Save"],
            style: .warning,
            defaultButton: 2
        )
        #expect(keys(titled) == ["", "", "\r"] && titled.buttons.allSatisfy { $0.keyEquivalentModifierMask.isEmpty })
        // An index that is no button is no default.
        #expect(
            keys(ui.makeQuestion("?", detail: "", buttons: ["A", "B"], style: .information, defaultButton: 7)) == [
                "", "\u{1b}"
            ]
        )
        // Names in a question cannot write lines of their own, in the buttons either.
        let named = ui.makeQuestion(
            "Delete a\u{202E}txt.exe?",
            detail: "",
            buttons: ["Delete\u{0007}", "Keep"],
            style: .warning,
            defaultButton: 1
        )
        #expect(named.messageText == "Delete a\u{FFFD}txt.exe?" && named.buttons[0].title == "Delete\u{2407}")
    }

    // MARK: Large settings (find 6, kernel 5)

    private func makeStore() throws -> (store: UserDefaultsSettings, defaults: UserDefaults, folder: URL, suite: String)
    {
        let suite = "afm-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        return (UserDefaultsSettings(defaults: defaults, largeFolder: folder), defaults, folder, suite)
    }

    @Test func largeValuesAreKeptInFilesOfTheirOwnAndWrittenInTheBackground() throws {
        let (store, defaults, folder, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let big = Data(repeating: 0x41, count: 3_000_000)
        store.setLarge(big, forKey: "multiRename.undo")
        // Readable at once, whether or not the file is there yet.
        #expect(store.largeData(forKey: "multiRename.undo") == big)
        #expect(store.waitForWrites(atMost: 60))
        let file = try #require(store.largeFile(forKey: "multiRename.undo"))
        #expect((try? Data(contentsOf: file)) == big && defaults.object(forKey: "multiRename.undo") == nil)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
            .intValue
        #expect(mode == 0o600)
        // Another store (the next start) finds it; small values are where they were.
        let next = UserDefaultsSettings(defaults: defaults, largeFolder: folder)
        #expect(next.largeData(forKey: "multiRename.undo") == big && next.data(forKey: "multiRename.undo") == nil)
        store.set(Data("small".utf8) as Data?, forKey: "plain")
        #expect(
            store.data(forKey: "plain") == Data("small".utf8) && store.largeData(forKey: "plain") == Data("small".utf8)
        )
        // Set many times in a row, the last value is the one in the file.
        for index in 0..<50 { store.setLarge(Data("v\(index)".utf8), forKey: "multiRename.undo") }
        #expect(store.waitForWrites(atMost: 60) && (try? Data(contentsOf: file)) == Data("v49".utf8))
        // Taken away, the file goes.
        store.setLarge(nil, forKey: "multiRename.undo")
        #expect(store.largeData(forKey: "multiRename.undo") == nil && store.waitForWrites(atMost: 60))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aLargeValueThatWasKeptWithTheRestIsFoundAndMoved() throws {
        let (store, defaults, folder, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        defaults.set(Data("old".utf8), forKey: "history")
        #expect(store.largeData(forKey: "history") == Data("old".utf8))
        store.setLarge(Data("new".utf8), forKey: "history")
        #expect(store.waitForWrites(atMost: 60) && defaults.object(forKey: "history") == nil)
        #expect(
            UserDefaultsSettings(defaults: defaults, largeFolder: folder).largeData(forKey: "history")
                == Data("new".utf8)
        )
    }

    @Test func noKeyNamesAFileOutsideTheFolder() throws {
        let (store, defaults, folder, suite) = try makeStore()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        for key in [
            "../../escape", "/etc/passwd", "..", ".", "a/b", ".hidden", "with space", "é",
            String(repeating: "x", count: 1_000)
        ] {
            let file = try #require(store.largeFile(forKey: key))
            #expect(file.deletingLastPathComponent().path == folder.path)
            let name = file.lastPathComponent
            #expect(!name.contains("/") && !name.hasPrefix(".") && name.utf8.count <= 255 && name.hasSuffix(".data"))
        }
        #expect(store.largeFile(forKey: "a/b") != store.largeFile(forKey: "a%2Fb"))
        // A store without a folder keeps large values with the rest.
        let plain = UserDefaultsSettings(defaults: defaults, largeFolder: nil)
        #expect(plain.largeFolder == nil && plain.largeFile(forKey: "k") == nil)
        plain.setLarge(Data("x".utf8), forKey: "k")
        #expect(defaults.data(forKey: "k") == Data("x".utf8) && plain.largeData(forKey: "k") == Data("x".utf8))
    }

    // MARK: The command line's history (C053)

    @Test func theHistoryKeepsNoLineThatBeginsWithABlankAndNothingWhenSwitchedOff() {
        let settings = MemorySettings()
        let history = CommandLineHistory(settings: settings)
        history.add("ls -l")
        history.add(" export TOKEN=secret")
        history.add("\tmysql -psecret")
        history.add("ls -l  ")
        #expect(
            history.entries == ["ls -l"] && CommandLineHistory.isPrivate(" x") && !CommandLineHistory.isPrivate("x ")
        )
        #expect(history.isRecording)
        settings.set(false, forKey: CommandLineHistory.recordKey)
        history.add("pwd")
        #expect(history.entries.isEmpty && settings.data(forKey: CommandLineHistory.settingsKey) == nil)
        // What an earlier session remembered goes as soon as the history is looked at.
        settings.set(["old line"], forKey: CommandLineHistory.settingsKey)
        #expect(
            CommandLineHistory(settings: settings).entries.isEmpty
                && settings.data(forKey: CommandLineHistory.settingsKey) == nil
        )
    }

    // MARK: Threads (kernel request 1)

    @Test func theLanesRunOnTheKernelsThreadsForCallsThatBlock() async {
        let seen = Shared<[String]>([])
        let location = URL(string: "lane-p2://host/a")!
        for _ in 0..<3 {
            Background.storage("p2", at: location) {
                seen.change { $0.append("\(Thread.current.name ?? "") main: \(Thread.isMainThread)") }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while seen.value.count < 3, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        // While it works for a lane the thread bears the lane's name; it is the kernel's, and
        // goes back to it under the kernel's name.
        #expect(seen.value == Array(repeating: "afm.p2 main: false", count: 3))
        let after = Shared("")
        BlockingCalls.run { after.value = Thread.current.name ?? "" }
        while after.value.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(after.value == "AFM.Blocking")
    }

    @Test func aColumnIsToldWhenThePanelHasLeftTheFolder() async {
        let flags = Shared<[CancellationFlag]>([])
        let gate = DispatchSemaphore(value: 0)
        let column = ContentColumn(
            id: "slow",
            title: "Slow",
            cancellableValue: { item, flag in
                flags.change { $0.append(flag) }
                gate.wait()
                return item.name
            }
        )
        let store = ColumnValueStore()
        store.reset(folder: URL(string: "cols://host/a")!)
        _ = store.text(of: column, for: FileItem(url: URL(string: "cols://host/a/x")!, name: "x"))
        let deadline = Date().addingTimeInterval(30)
        while flags.value.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(flags.value.count == 1 && flags.value.first?.isCancelled == false)
        store.reset(folder: URL(string: "cols://host/b")!)
        #expect(flags.value.first?.isCancelled == true)
        gate.signal()
    }
}
