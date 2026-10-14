import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// A file system whose `watch` and `places` say on which thread they were called, and whose
/// `watch` can be made to wait like a share that has stopped answering. Everything else is a
/// memory file system's.
final class WatchedFileSystem: FileSystemProvider {
    let inner: MemoryFileSystem
    private let condition = NSCondition()
    private var holds = false
    private var watchCalls: [(path: String, onMain: Bool)] = []
    private var placeCalls: [Bool] = []
    private var living = 0
    private var ended = 0
    private var handlers: [String: ([URL]) -> Void] = [:]

    init(scheme: String = "watched") { inner = MemoryFileSystem(scheme: scheme) }

    func url(_ path: String) -> URL { inner.url(path) }

    private final class Token {
        let onEnd: () -> Void
        init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }
        deinit { onEnd() }
    }

    /// While true, `watch` does not come back.
    var holdsWatches: Bool {
        get {
            condition.lock()
            defer { condition.unlock() }
            return holds
        }
        set {
            condition.lock()
            holds = newValue
            condition.broadcast()
            condition.unlock()
        }
    }

    var watches: [(path: String, onMain: Bool)] {
        condition.lock()
        defer { condition.unlock() }
        return watchCalls
    }
    var placesAskedOnMain: [Bool] {
        condition.lock()
        defer { condition.unlock() }
        return placeCalls
    }
    /// Watches that were handed out and not let go of yet, and those that were let go of.
    var livingWatches: Int {
        condition.lock()
        defer { condition.unlock() }
        return living
    }
    var endedWatches: Int {
        condition.lock()
        defer { condition.unlock() }
        return ended
    }

    /// Reports a change of a watched folder, as the file system would: on the main thread.
    func reportChange(of path: String) {
        condition.lock()
        let handler = handlers[path]
        condition.unlock()
        handler?([url(path)])
    }

    func watch(_ directories: [URL], onChange: @escaping ([URL]) -> Void) -> AnyObject? {
        condition.lock()
        for directory in directories { watchCalls.append((directory.path, Thread.isMainThread)) }
        while holds { condition.wait() }
        living += 1
        for directory in directories { handlers[directory.path] = onChange }
        condition.unlock()
        return Token { [weak self] in
            guard let self else { return }
            condition.lock()
            living -= 1
            ended += 1
            condition.unlock()
        }
    }

    func places() -> [Place] {
        condition.lock()
        placeCalls.append(Thread.isMainThread)
        condition.unlock()
        return [Place(name: "Watched", url: url("/"), kind: .externalDisk)]
    }

    var scheme: String { inner.scheme }
    var capabilities: FileSystemCapabilities { inner.capabilities }
    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try inner.list(directory, showHidden: showHidden)
    }
    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool) throws
    {
        try inner.list(directory, showHidden: showHidden, cancellation: cancellation, receive: receive)
    }
    func volume(of url: URL) -> VolumeInfo? { inner.volume(of: url) }
    func item(at url: URL) -> FileItem? { inner.item(at: url) }
    func parent(of directory: URL) -> URL? { inner.parent(of: directory) }
    func read(_ url: URL) throws -> any FileReader { try inner.read(url) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func write(_ url: URL) throws -> any FileWriter { try inner.write(url) }
    func remove(_ url: URL) throws { try inner.remove(url) }
    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try inner.move(source, to: destination, replacing: replacing)
    }
    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try inner.copy(source, to: destination, progress: progress)
    }
}

/// A value several threads write and read.
final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func change(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

/// What review round 2 asked of the window shell, through the real program: nothing waits on
/// the main thread, a folder that is merely read again disturbs nobody, and a job or a share
/// that does not answer holds up only itself.
extension Application {
    func start(with extra: any FileSystemProvider) async -> Running {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, ui: ui)
        kernel.fileSystems.register(memory)
        kernel.fileSystems.register(extra)
        kernel.load(StandardPlugins.make(pasteboard: .withUniqueName(), launchesApplications: false))
        let running = Running(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await settle(running)
        return running
    }

    /// Waits until nothing is read, nothing waits to be read again and no job runs.
    func rest(_ app: Running) async {
        await wait {
            !app.shell.panelCoordinator.isLoading && !app.left.hasPendingReread && !app.right.hasPendingReread
                && !app.kernel.jobs.isBusy
        }
    }

    // MARK: Watching (S010, S032)

    @Test func watchingIsSetUpOffTheMainThreadAndNeverTwiceForAFolderThatHasNotAnswered() async {
        let watched = WatchedFileSystem()
        watched.inner.addFile("/w/a.txt")
        watched.holdsWatches = true
        let app = await start(with: watched)
        defer {
            watched.holdsWatches = false
            app.stop()
        }
        app.left.show(watched.url("/w"))
        await settle(app)
        // The folder is on screen although its file system has not come back from `watch`.
        #expect(app.names(app.left) == ["a.txt"])
        let asked = await wait { watched.watches.count == 1 }
        #expect(asked && watched.watches.allSatisfy { $0.path == "/w" && !$0.onMain })
        // Leaving and coming back while that call is still out starts no second one.
        app.left.show(box.url("A"))
        await settle(app)
        app.left.show(watched.url("/w"))
        await settle(app)
        app.left.show(box.url("A"))
        await settle(app)
        #expect(watched.watches.count == 1 && watched.livingWatches == 0)
        // The call comes back for a folder nobody shows any more: the watch is let go of.
        watched.holdsWatches = false
        let dropped = await wait { watched.endedWatches == 1 }
        #expect(dropped && watched.livingWatches == 0)
        // A watch that is wanted is kept, and what it reports reads the folder again.
        app.left.show(watched.url("/w"))
        await settle(app)
        let kept = await wait { watched.livingWatches == 1 }
        #expect(kept && watched.watches.count == 2 && watched.watches.allSatisfy { !$0.onMain })
        await rest(app)
        watched.inner.addFile("/w/b.txt")
        watched.reportChange(of: "/w")
        let seen = await wait { app.names(app.left) == ["a.txt", "b.txt"] }
        #expect(seen)
        // The other panel's folder kept its own watch all along: one folder, one call.
        #expect(Set(watched.watches.map(\.path)) == ["/w"])
    }

    @Test func placesAreAskedForOffTheMainThread() async {
        let watched = WatchedFileSystem()
        let app = await start(with: watched)
        defer { app.stop() }
        let places = app.shell.panelCoordinator.places
        let complete = await wait { places.isComplete }
        #expect(complete && places.all.contains { $0.name == "Watched" } && places.all.contains { $0.name == "Memory" })
        #expect(!watched.placesAskedOnMain.isEmpty && watched.placesAskedOnMain.allSatisfy { !$0 })
        // The drive bar and the volume list show what the store knows, without asking themselves.
        let asked = watched.placesAskedOnMain.count
        app.shell.mainWindow.driveBar.rebuild()
        #expect(app.shell.mainWindow.driveBar.places.map(\.name) == places.all.map(\.name))
        #expect(app.shell.panelCoordinator.placesForVolumeList(of: app.left).map(\.name) == places.all.map(\.name))
        let again = await wait { watched.placesAskedOnMain.count > asked }
        #expect(again && watched.placesAskedOnMain.allSatisfy { !$0 })
    }

    // MARK: Reading again (S009, S022, S025 – S029, S063, S064)

    @Test func aFolderThatIsMerelyReadAgainIsNotAnnouncedAsANewPlace() async throws {
        let app = await start()
        defer { app.stop() }
        await rest(app)
        var places = 0
        let subscription = app.kernel.panelEvents.subscribe { event, _ in if event == .locationChanged { places += 1 } }
        defer { _ = subscription }
        // The program is activated, another program touches the folder, a plugin asks for a refresh.
        app.shell.panelCoordinator.reloadChangedPanels()
        await rest(app)
        try box.file("A/extra.txt")
        var read = false
        app.left.reload(focus: nil, quietly: false) { read = true }
        _ = await wait { read }
        await rest(app)
        #expect(app.names(app.left).contains("extra.txt") && places == 0)
        // Going somewhere is announced, once.
        app.left.show(box.url("A/docs"))
        await settle(app)
        #expect(places == 1 && app.left.model.directory.lastPathComponent == "docs")
        // And so is a location that a second reading of the same folder overtook the first to.
        memory.addFile("/slow/a.txt")
        memory.listStartDelay = 1
        app.left.show(memory.url("/slow"))
        _ = await wait { app.left.model.isOpening }
        app.left.show(memory.url("/slow"))
        await settle(app)
        #expect(app.left.model.directory.path == "/slow" && places == 2)
    }

    @Test func manyReportedChangesAreOneReadingAfterAPause() async {
        memory.addFile("/busy/a.txt")
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/busy"))
        await rest(app)
        let before = memory.listRequests(for: "/busy")
        for _ in 0..<200 { app.shell.panelCoordinator.reloadChangedPanels(showing: [memory.url("/busy")]) }
        await rest(app)
        // However the two hundred reports fell around the pause: one reading, or one that began
        // at once and one that made up for the rest.
        let readings = memory.listRequests(for: "/busy") - before
        #expect(readings >= 1 && readings <= 2)
    }

    @Test func whoWaitsForAReloadThatWasPutOffIsToldWhenTheFolderHasBeenRead() async {
        memory.addFile("/slow/a.txt")
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/slow"))
        await rest(app)
        memory.listStartDelay = 0.2
        let before = memory.listRequests(for: "/slow")
        var told: [String] = []
        app.left.reload(focus: nil, quietly: false) { told.append("loud") }
        app.left.reload(focus: nil, quietly: true) {
            told.append("quiet after \(self.memory.listRequests(for: "/slow") - before)")
        }
        #expect(told.isEmpty)
        let all = await wait { told.count == 2 }
        // The quiet one was turned away while the folder was read, and made up for afterwards.
        #expect(all && told == ["loud", "quiet after 2"])
    }

    @Test func readingTheFolderAgainDoesNotThrowOverANavigationThatIsUnderWay() async {
        memory.addFile("/far/x.txt")
        memory.listStartDelay = 0.2
        let app = await start()
        defer { app.stop() }
        var shown: Bool?
        var reloaded = false
        app.left.show(memory.url("/far"), focus: nil, history: .record) { shown = $0 }
        app.left.reload(focus: nil, quietly: false) { reloaded = true }
        let done = await wait { shown != nil && reloaded }
        #expect(done && shown == true && app.left.model.directory.path == "/far" && app.names(app.left) == ["x.txt"])
        #expect(!app.left.hasPendingReread)
    }

    @Test func aFolderThatWasEnteredEmptyAndLeftAgainIsNotInTheHistory() async {
        memory.addFile("/p1/a.txt")
        memory.addFile("/p2/b.txt")
        memory.stallsListings = true
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/p1"))
        let first = await wait { app.left.model.isOpening && app.left.model.directory.path == "/p1" }
        app.left.show(memory.url("/p2"))
        let second = await wait { app.left.model.isOpening && app.left.model.directory.path == "/p2" }
        memory.releaseStalls()
        await settle(app)
        #expect(first && second && app.names(app.left) == ["b.txt"])
        // Back leads to where the panel really was, not to the folder that never showed anything.
        #expect(app.left.model.backLocation?.lastPathComponent == "A" && app.left.model.forwardLocation == nil)
    }

    @Test func theCompletionOfAReadingWhoseTabIsClosedHearsOfIt() async {
        memory.addFile("/stuck/a.txt")
        let app = await start()
        defer {
            memory.releaseStalls()
            app.stop()
        }
        app.commands.perform(.newTab)
        await settle(app)
        memory.stallsListings = true
        var result: Bool?
        app.left.show(memory.url("/stuck"), focus: nil, history: .record) { result = $0 }
        #expect(app.left.isLoading && app.left.tabs.tabs.count == 2)
        app.commands.perform(.closeTab)
        let told = await wait { result != nil }
        #expect(told && result == false && app.left.tabs.tabs.count == 1)
    }

    // MARK: The in-place editor (S020, S021)

    @Test func theNameEditorStaysWhileItsItemIsInTheList() async throws {
        let app = await start()
        defer { app.stop() }
        await rest(app)
        app.cursor(app.left, on: "one.txt")
        app.left.beginRename()
        #expect(app.left.isRenaming && app.left.renamingRow == app.left.model.row(ofName: "one.txt"))
        // A refresh after an operation: the list changes around the item.
        try box.file("A/a-first.txt")
        try box.file("A/zz-last.txt")
        var read = false
        app.left.reload(focus: nil, quietly: false) { read = true }
        _ = await wait { read }
        #expect(app.names(app.left).contains("a-first.txt"))
        #expect(app.left.isRenaming && app.left.renamingRow == app.left.model.row(ofName: "one.txt"))
        // Another order: the editor follows its item.
        let before = app.left.renamingRow
        app.left.model.setSort(ListOrder(key: app.left.model.sort.key, descending: !app.left.model.sort.descending))
        #expect(
            app.left.isRenaming && app.left.renamingRow == app.left.model.row(ofName: "one.txt")
                && app.left.renamingRow != before)
        // The item is gone: so is the editor.
        try FileManager.default.removeItem(at: box.url("A/one.txt"))
        read = false
        app.left.reload(focus: nil, quietly: false) { read = true }
        _ = await wait { read }
        #expect(!app.left.isRenaming && app.left.renamingRow == nil && !app.names(app.left).contains("one.txt"))
    }

    // MARK: Finding by typing (S012, S019, S049)

    @Test func typingFindsAFileInALongListWithoutLookingThroughItOnTheMainThread() async {
        for index in 0..<25_000 { memory.addFile(String(format: "/long/f%05d.txt", index)) }
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/long"))
        await settle(app)
        #expect(app.left.model.items.count == 25_000 && !app.left.tableView.allowsTypeSelect)
        let start = app.left.model.cursor
        app.left.typeToFind("f", at: 1)
        // Nothing has moved yet: the list is looked through elsewhere.
        #expect(app.left.model.cursor == start)
        let first = await wait { app.left.model.cursorItem?.name == "f00000.txt" }
        app.left.typeToFind("2", at: 1.1)
        let found = await wait { app.left.model.cursorItem?.name == "f20000.txt" }
        #expect(first && found)
        // Only the search for the last key counts.
        app.left.typeToFind("4", at: 1.2)
        app.left.typeToFind("9", at: 1.3)
        let narrowed = await wait { app.left.model.cursorItem?.name == "f24900.txt" }
        #expect(narrowed)
        // No name starts with this: the cursor stays.
        app.left.typeToFind("zzz", at: 5)
        await wait(upTo: 0.3) { false }
        #expect(app.left.model.cursorItem?.name == "f24900.txt")
    }

    // MARK: Jobs (S005, S007, S016, S037, S046)

    @Test func aJobThatDoesNotStopCanBeLeftBehindAndTheQueueMovesOn() async {
        let app = await start()
        defer { app.stop() }
        let service = app.shell.jobService
        service.patience = 0.05
        let release = DispatchSemaphore(value: 0)
        let thread = Shared("")
        var log: [String] = []
        service.run(
            title: "Stuck",
            work: { _ -> String in
                thread.value = Thread.current.name ?? ""
                release.wait()
                return "late"
            }, completion: { log.append($0) })
        service.run(title: "Next", work: { _ in "next" }, completion: { log.append($0) })
        // Asked twice: the first time the user keeps waiting.
        ui.choiceAnswers = [1, 0]
        service.cancelCurrent()
        let free = await wait { !service.isBusy }
        #expect(free && log == ["next"] && service.abandonedCount == 1 && app.commands.isEnabled(.goToParent))
        #expect(ui.log.count == 2 && ui.log.allSatisfy { $0.hasPrefix("choose: “Stuck” does not stop.") })
        // Its own thread, not one of the system's shared pool.
        #expect(thread.value == "afm.job")
        // When the system lets it go at last, its completion still runs.
        release.signal()
        let back = await wait { log.count == 2 }
        #expect(back && log == ["next", "late"] && service.abandonedCount == 0 && !service.isBusy)
    }

    @Test func aJobThatDoesNotStopDoesNotKeepTheProgramFromQuitting() async {
        let app = await start()
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            app.stop()
        }
        app.kernel.jobs.run(title: "Stuck", work: { _ in release.wait() }, completion: { _ in })
        ui.choiceAnswers = [1, 0]
        var reply: Bool?
        app.shell.stopJobsToQuit(patience: 0.05) { reply = $0 }
        #expect(reply == nil)
        let answered = await wait { reply != nil }
        #expect(answered && reply == true && app.kernel.jobs.isBusy)
        #expect(ui.log.count == 2 && ui.log.allSatisfy { $0.hasPrefix("choose: An operation does not stop.") })
        // With nothing running, quitting asks nothing.
        var atOnce: Bool?
        release.signal()
        await settle(app)
        app.shell.stopJobsToQuit { atOnce = $0 }
        #expect(atOnce == true && ui.log.count == 2)
    }

    @Test func theServiceSaysItIsIdleBeforeTheLastCompletionRuns() async {
        let app = await start()
        defer { app.stop() }
        let service = app.shell.jobService
        var states: [String] = []
        let told = service.onBusyChanged
        service.onBusyChanged = {
            states.append("busy \(service.isBusy)")
            told?()
        }
        service.run(
            title: "One", work: { _ in 1 }, completion: { _ in states.append("first done, busy \(service.isBusy)") })
        service.run(
            title: "Two", work: { _ in 2 }, completion: { _ in states.append("second done, busy \(service.isBusy)") })
        await settle(app)
        _ = await wait { states.count == 4 }
        #expect(states == ["busy true", "first done, busy true", "busy false", "second done, busy false"])
        // A question from the main thread is answered there instead of waiting for itself.
        let sheet = ProgressSheet(title: "", cancellation: CancellationFlag())
        #expect(sheet.ask { 7 } == 7)
    }

    // MARK: Keys and menus (S004, S033, S034, S072)

    @Test func aKeyDoesNotBringTheWholeMenuBarUpToDate() async throws {
        let app = await start()
        defer { app.stop() }
        let menu = app.shell.makeMainMenu()
        let keys = try #require(MenuBuilder.keyAnswers(of: menu))
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        // A letter, an arrow and a Cmd key nothing is bound to: the plugins' menus are asked, and check no entry.
        for event in [
            key("a", 0), key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125),
            key("j", 38, [.command, .control, .option])
        ] {
            #expect(!menu.performKeyEquivalent(with: event))
        }
        #expect(keys.lookups > 0 && keys.validations == 0)
        // A key of a command: one entry is checked, whatever the menus hold.
        let lookups = keys.lookups
        _ = menu.performKeyEquivalent(with: key(String(UnicodeScalar(NSF5FunctionKey)!), 96))
        #expect(keys.lookups > lookups && keys.validations <= 2)
        // The same key on a keyboard that writes another script.
        #expect(MenuKeys.shortcuts(for: key("с", 8, .command)).contains(Shortcut(.character("c"), .command)))
    }

    @Test func theBarsRestAfterASlowCheck() async {
        let app = await start()
        defer { app.stop() }
        let window = app.shell.mainWindow!
        _ = await wait { !window.isValidationPending }
        window.validateBars()
        // Checked a moment ago and nothing changed: an event alone asks for no new check…
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window.window)
        #expect(!window.isValidationPending)
        // …a change does.
        window.scheduleValidation()
        #expect(window.isValidationPending)
    }

    // MARK: Drag and drop (S003, S053 – S055)

    @Test func aPanelsDragTypeIsOnlyBelievedFromThisProgramsOwnDrag() async {
        let app = await start()
        defer {
            PanelDrop.endDrag()
            app.stop()
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Another program writes the panel's type with a location on a server: not taken.
        let forged = NSPasteboardItem()
        forged.setString("sftp://evil.example/secret", forType: PanelDrop.itemType)
        pasteboard.clearContents()
        pasteboard.writeObjects([forged])
        #expect(PanelDrop.locations(on: pasteboard).isEmpty)
        // The program's own drag carries its ticket; the items stay inside the program.
        app.left.model.setSelected(true, rows: 2...3)
        let written = app.left.draggingItems(forRow: 3)
        pasteboard.clearContents()
        pasteboard.writeObjects(written)
        #expect(
            written.count == 2
                && PanelDrop.locations(on: pasteboard).map(\.lastPathComponent) == ["one.txt", "two.txt"])
        // Other programs get the files of the local disks as file URLs.
        let files =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(files?.map(\.lastPathComponent) == ["one.txt", "two.txt"])
        // When the drag is over, its ticket is worth nothing: what is still on the pasteboard
        // is read like any other program's, for its local files.
        PanelDrop.endDrag()
        #expect(
            PanelDrop.current == nil
                && PanelDrop.locations(on: pasteboard).map(\.lastPathComponent) == ["one.txt", "two.txt"])
        // Items of another file system are in the drag, but not for other programs.
        memory.addFile("/M/far.txt")
        app.right.show(memory.url("/M"))
        await settle(app)
        let remote = app.right.draggingItems(forRow: 1)
        pasteboard.clearContents()
        pasteboard.writeObjects(remote)
        #expect(PanelDrop.locations(on: pasteboard).map(\.absoluteString) == ["mem:///M/far.txt"])
        #expect(
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                .isEmpty)
        PanelDrop.endDrag()
        #expect(PanelDrop.locations(on: pasteboard).isEmpty)
    }
}

/// The parts review round 2 added or changed, by themselves.
@MainActor @Suite(.serialized) struct Review2ShellParts {
    init() {
        _ = NSApplication.shared
    }

    func wait(upTo seconds: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        return condition()
    }

    // MARK: Threads of the program's own (S069)

    @Test func aLaneRunsOneCallAtATimeAndAStuckLaneHoldsUpNoOther() async {
        let (stuck, other) = (URL(string: "lane://host/stuck")!, URL(string: "lane://host/other")!)
        let gate = DispatchSemaphore(value: 0)
        let log = Shared<[String]>([])
        Background.storage("test", at: stuck) {
            log.change { $0.append("first on main: \(Thread.isMainThread), thread \(Thread.current.name ?? "")") }
            gate.wait()
        }
        Background.storage("test", at: stuck) { log.change { $0.append("second") } }
        Background.storage("test", at: other) { log.change { $0.append("other") } }
        // Another purpose at the same place is another lane.
        Background.storage("test2", at: stuck) { log.change { $0.append("other purpose") } }
        let ran = await wait { log.value.count == 3 }
        #expect(ran && Set(log.value) == ["first on main: false, thread afm.test", "other", "other purpose"])
        #expect(Background.isBusy("test", at: stuck) && !Background.isBusy("test", at: other))
        gate.signal()
        let all = await wait { log.value.count == 4 && !Background.isBusy("test", at: stuck) }
        #expect(all && log.value.last == "second")
    }

    @Test func resultsComeBackThroughTheRunLoopAndInOrder() async {
        var got: [Int] = []
        for number in 0..<20 {
            Background.storage("order", at: URL(fileURLWithPath: "/order"), work: { number }, then: { got.append($0) })
        }
        var computed = 0
        Background.compute(work: { (0..<1_000).reduce(0, +) }, then: { computed = $0 })
        let done = await wait { got.count == 20 && computed != 0 }
        #expect(done && got == Array(0..<20) && computed == 499_500)
        // Something large is let go of elsewhere; the variable is empty at once.
        var list: [Int]? = Array(0..<100_000)
        Background.release(&list)
        #expect(list == nil)
    }

    @Test func dialogsComeOneAfterTheOtherAndNotFromInsideTheMainQueue() async {
        var log: [String] = []
        var queued = false
        MainLoop.dialog {
            log.append("first up")
            // A dialog runs the loop itself for a while; what was sent to the main queue meanwhile arrives.
            DispatchQueue.main.async { queued = true }
            let until = Date().addingTimeInterval(5)
            while !queued, Date() < until {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            log.append("first down, queue served: \(queued)")
        }
        MainLoop.dialog { log.append("second") }
        let done = await wait { log.count == 3 }
        #expect(done && log == ["first up", "first down, queue served: true", "second"])
    }

    // MARK: Keys of menus (S004, S033)

    @objc final class MenuTarget: NSObject, NSMenuItemValidation {
        var isOffered = true
        var validated = 0
        var senders: [NSMenuItem] = []
        func validateMenuItem(_: NSMenuItem) -> Bool {
            validated += 1
            return isOffered
        }
        @objc func run(_ sender: Any?) {
            if let item = sender as? NSMenuItem { senders.append(item) }
        }
    }

    @Test func theKeyOfAMenuEntryRunsThatEntryAndChecksNoOther() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), ui: ScriptedInteraction())
        var asked = 0
        kernel.commands.register(
            Command("test_Bound", "Bound", [.f(9), .cmd("j")]),
            enabled: {
                asked += 1
                return true
            }
        ) {}
        for index in 0..<40 {
            kernel.commands.register(
                Command(CommandID(rawValue: "test_Other\(index)"), "Other \(index)"),
                enabled: {
                    asked += 1
                    return true
                }
            ) {}
        }
        // A menu bar of one menu with a submenu; the entries send to an object of the test's,
        // which stands in for the window.
        let target = MenuTarget()
        let menu = NSMenu(title: "Commands")
        let inner = NSMenu(title: "More")
        let bar = NSMenu()
        for command in kernel.commands.all {
            let item = MenuBuilder.item(command, keys: kernel.keyBindings)
            (item.target, item.action) = (target, #selector(MenuTarget.run(_:)))
            (command.id == "test_Bound" ? inner : menu).addItem(item)
        }
        let undo = NSMenuItem(title: "Undo", action: #selector(MenuTarget.run(_:)), keyEquivalent: "z")
        undo.target = target
        menu.addItem(undo)
        for (holder, submenu) in [
            (NSMenuItem(title: "More", action: nil, keyEquivalent: ""), inner),
            (NSMenuItem(title: "Commands", action: nil, keyEquivalent: ""), menu)
        ] {
            holder.submenu = submenu
            (submenu === inner ? menu : bar).addItem(holder)
        }
        let keys = MenuKeys(kernel: kernel)
        keys.answer(for: menu)
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        // Keys nothing has: asked, and not one entry brought up to date.
        #expect(
            !bar.performKeyEquivalent(with: key("a", 0)) && !bar.performKeyEquivalent(with: key("k", 40, .command)))
        #expect(keys.lookups > 0 && target.validated == 0 && asked == 0 && target.senders.isEmpty)
        // The key of the entry in the submenu: that entry is checked and runs, with itself as the sender.
        #expect(bar.performKeyEquivalent(with: key(String(UnicodeScalar(NSF9FunctionKey)!), 101)))
        #expect(
            target.senders.map(\.title) == ["Bound"] && target.validated == 1 && keys.validations == 1 && asked == 0)
        // A standard entry by its own key, also on a keyboard that writes another script.
        #expect(
            bar.performKeyEquivalent(with: key("z", 6, .command))
                && bar.performKeyEquivalent(with: key("я", 6, .command)))
        #expect(target.senders.map(\.title) == ["Bound", "Undo", "Undo"])
        // Only the key the menu shows belongs to the menu; the command's other key is the list's.
        #expect(!bar.performKeyEquivalent(with: key("j", 38, .command)))
        #expect(target.validated == 3)
        // An entry that cannot be chosen now does not run. Each menu on the way to it is asked
        // and checks that one entry; nothing else is looked at.
        target.isOffered = false
        _ = bar.performKeyEquivalent(with: key(String(UnicodeScalar(NSF9FunctionKey)!), 101))
        #expect(
            target.senders.count == 3 && target.validated > 3 && target.validated <= 3 + 6
                && inner.items.first?.isEnabled == false)
        // When a menu is about to be shown, its own entries are brought up to date, and no other menu's.
        target.isOffered = true
        var before = target.validated
        keys.menuNeedsUpdate(inner)
        #expect(target.validated == before + 1 && inner.items.first?.isEnabled == true)
        before = target.validated
        keys.menuNeedsUpdate(menu)
        #expect(target.validated == before + 41 && menu.items.allSatisfy(\.isEnabled))
    }

    // MARK: Icons (S002, S017, S050, S051)

    @Test func ownIconsAreFetchedInTheBackgroundAndKept() async {
        let store = IconStore()
        let asked = Shared<[String]>([])
        let image = NSImage(size: NSSize(width: 16, height: 16))
        store.source = { path in
            asked.change { $0.append("\(path) on main: \(Thread.isMainThread)") }
            return image
        }
        var arrived: Set<String> = []
        let observer = NotificationCenter.default.addObserver(
            forName: IconStore.didArrive, object: store, queue: .main
        ) { note in
            arrived.formUnion(note.userInfo?[IconStore.pathsKey] as? Set<String> ?? [])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let date = Date(timeIntervalSince1970: 5)
        // Not there yet: the caller shows the icon of the type, and nothing was asked on this thread.
        #expect(
            store.icon(forPath: "/icons/a.app", modified: date) == nil
                && store.icon(forPath: "/icons/a.app", modified: date) == nil)
        let came = await wait { arrived == ["/icons/a.app"] }
        #expect(came && asked.value == ["/icons/a.app on main: false"])
        #expect(store.icon(forPath: "/icons/a.app", modified: date) === image && asked.value.count == 1)
        // A changed file is asked again.
        #expect(store.icon(forPath: "/icons/a.app", modified: Date(timeIntervalSince1970: 6)) == nil)
        _ = await wait { !store.isBusy }
        #expect(asked.value.count == 2)
    }

    @Test func aFullStoreLosesWhatWasNotUsedAndNeverEverything() {
        var cache = TwoGenerationCache<Int, String>(limit: 10)
        for number in 0..<100 {
            cache[number] = "v\(number)"
            // One entry is asked for all the time, like the icons on screen.
            #expect(cache[0] == "v0")
            #expect(cache.count <= 10)
        }
        #expect(cache[99] == "v99" && cache[50] == nil)
    }

    // MARK: Names on screen (S066)

    @Test func namesThatCouldMisleadAreShownWithEveryCharacterVisible() {
        #expect(
            DisplayText.clean("report.txt") == "report.txt"
                && DisplayText.clean("Übergrößen – 日本.txt") == "Übergrößen – 日本.txt")
        #expect(DisplayText.clean("invoice\u{202E}fdp.exe") == "invoice\u{FFFD}fdp.exe")
        #expect(DisplayText.clean("two\nlines\ttab\u{7}") == "two\u{240A}lines\u{2409}tab\u{2407}")
        #expect(DisplayText.clean("two\nlines \u{202E}x", keepingLines: true) == "two\nlines \u{FFFD}x")
        // One sign for one: positions in the text stay what they were.
        let name = "a\u{2066}b\u{85}c\u{200F}d"
        #expect(DisplayText.clean(name).utf16.count == name.utf16.count)
        let item = FileItem(
            url: URL(fileURLWithPath: "/x/evil\u{202E}txt.exe"), name: "evil\u{202E}txt.exe", isDirectory: false)
        #expect(
            FileListColumn.name.text(for: item) == "evil\u{FFFD}txt"
                && FileGridView.caption(for: item) == "evil\u{FFFD}txt.exe")
    }

    // MARK: Drag and drop (S003, S055)

    @Test func whereTheSourcesOfADragAreIsWorkedOutOnce() async {
        func file(_ path: String) -> URL { URL(fileURLWithPath: path) }
        let cases: [(sources: [URL], destination: URL)] = [
            ([file("/x/a/f.txt")], file("/x/a")), ([file("/x/a/f.txt")], file("/x/b")), ([file("/x/a")], file("/x/a")),
            ([file("/x/a")], file("/x/a/sub/deep")), ([file("/x/ab")], file("/x/a")),
            ([file("/x/a"), file("/y/b")], file("/x")),
            ([file("/a"), file("/b")], file("/")), ([file("/")], file("/x")),
            ([URL(string: "mem:///m/a")!], URL(string: "mem:///m")!),
            ([URL(string: "ftp://host/a/b")!], URL(string: "ftp://other/a")!), ([], file("/x"))
        ]
        for (sources, destination) in cases {
            for kind in [TransferKind.copy, .move] {
                #expect(
                    DragSources(sources).isPointless(kind, into: destination)
                        == PanelDrop.isPointless(kind, sources, into: destination),
                    "\(kind) \(sources.map(\.absoluteString)) into \(destination.absoluteString)")
            }
        }
        // A drag of very many items is looked at in the background; until then nothing is taken.
        let many = (0..<DropSession.backgroundThreshold).map { file("/big/f\($0)") }
        let session = DropSession(sequence: 1, sources: many)
        #expect(!session.isReady && session.isPointless(.copy, into: file("/elsewhere")))
        let ready = await wait { session.isReady }
        #expect(
            ready && !session.isPointless(.copy, into: file("/elsewhere"))
                && session.isPointless(.move, into: file("/big")))
    }

    @Test func aDragOfVeryManyItemsIsOneItemThatHandsOutItsFilesWhenAsked() {
        defer { PanelDrop.endDrag() }
        let items = (0...PanelDrop.itemsWrittenSingly).map {
            FileItem(url: URL(fileURLWithPath: "/many/f\($0)"), name: "f\($0)", isDirectory: false)
        }
        let written = PanelDrop.beginDrag(of: items)
        #expect(written.count == 1 && written[0].types.contains(.fileURL))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(written)
        PanelDrop.offerFileNames(on: pasteboard)
        #expect(PanelDrop.locations(on: pasteboard).count == items.count)
        #expect(pasteboard.string(forType: .fileURL) == "file:///many/f0")
        let paths = pasteboard.propertyList(forType: PanelDrop.fileNamesType) as? [String]
        #expect(paths?.count == items.count && paths?.first == "/many/f0")
        #expect(PanelDrop.beginDrag(of: []).isEmpty)
    }

    // MARK: Finding by typing (S012)

    @Test func theQuickComparisonOfNamesAgreesWithFoundation() {
        let names = [
            "Report.txt", "report_02.TXT", "re", "", "Résumé.doc", "re\u{301}sume", "ß-file", "ALPHA", "alpha beta",
            "über", "日本語", "a\u{308}b"
        ]
        for prefix in ["r", "RE", "rep", "report_02.txt", "a", "al", "alpha b", "ü", "é", "res", "日", "a", "ab", " "] {
            let matches = TypeSelect.matcher(for: prefix)
            for name in names {
                #expect(
                    matches(name) == (name.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil),
                    "\(prefix) in \(name)")
            }
        }
        let items = names.map { FileItem(url: URL(fileURLWithPath: "/x/" + $0), name: $0, isDirectory: false) }
        #expect(
            TypeSelect.row(matching: "al", in: items, from: 0) == 7
                && TypeSelect.row(matching: "a", in: items, from: 7) == 8)
        #expect(
            TypeSelect.row(matching: "zz", in: items, from: 3) == nil
                && TypeSelect.row(matching: "r", in: [FileItem](), from: 0) == nil)
        let cancelled = CancellationFlag()
        cancelled.cancel()
        let long = (0..<10_000).map {
            FileItem(url: URL(fileURLWithPath: "/x/n\($0)"), name: "n\($0)", isDirectory: false)
        }
        #expect(TypeSelect.row(matching: "zz", in: long, from: 0, cancellation: cancelled) == nil)
    }

    // MARK: Reading ahead (S008, S030, S067, S068)

    @Test func aFolderTheCacheCannotKeepIsNotReadAheadAgainAndAgain() async {
        var limits = ListingCache.Limits()
        limits.maxEntries = 30
        let cache = ListingCache(limits: limits)
        let server = MemoryFileSystem()
        server.isLocal = false
        for index in 0..<50 { server.addFile("/big/f\(index).txt") }
        server.addFile("/small/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: cache)
        defer { ahead.shutDown() }
        ahead.cursorRests(on: ReadAhead.Target(location: server.url("/big"), showHidden: false, order: ListOrder()))
        let read = await wait { server.listRequests(for: "/big") == 1 && !ahead.isReading && ahead.pausedCount == 1 }
        #expect(read && cache.folderCount == 0)
        // The cursor stays where it is for several rests' time: the folder is left alone.
        _ = await wait(upTo: ReadAhead.dwell * 4) { server.listRequests(for: "/big") > 1 }
        #expect(server.listRequests(for: "/big") == 1)
        // Going away and coming back does not read it either, for a long while.
        ahead.cursorRests(on: nil)
        ahead.cursorRests(on: ReadAhead.Target(location: server.url("/big"), showHidden: false, order: ListOrder()))
        _ = await wait(upTo: ReadAhead.dwell * 3) { server.listRequests(for: "/big") > 1 }
        #expect(server.listRequests(for: "/big") == 1)
        // A folder that fits is read once and remembered.
        ahead.cursorRests(on: ReadAhead.Target(location: server.url("/small"), showHidden: false, order: ListOrder()))
        let kept = await wait { cache.folderCount == 1 && !ahead.isReading }
        #expect(kept && server.listRequests(for: "/small") == 1 && ahead.pausedCount == 1)
    }

    @Test func aReadAheadThatIsTakenOverIsStoppedWhenNobodyWaitsForItAnyMore() async {
        let server = MemoryFileSystem()
        server.isLocal = false
        server.stallsListings = true
        server.addFile("/far/a.txt")
        let fileSystems = FileSystemRegistry()
        fileSystems.register(server)
        let ahead = ReadAhead(fileSystems: fileSystems, cache: ListingCache())
        defer {
            server.releaseStalls()
            ahead.shutDown()
        }
        let target = ReadAhead.Target(location: server.url("/far"), showHidden: false, order: ListOrder())
        ahead.cursorRests(on: target)
        let started = await wait { ahead.isReading && server.listRequests(for: "/far") == 1 }
        #expect(started)
        // Two panels take the reading over and the cursor moves on: the reading goes on for them.
        let (first, second) = (
            ahead.join(server.url("/far"), showHidden: false), ahead.join(server.url("/far"), showHidden: false)
        )
        var outcomes = 0
        first?.receive { _ in outcomes += 1 }
        second?.receive { _ in outcomes += 1 }
        ahead.cursorRests(on: nil)
        #expect(first != nil && second != nil && ahead.isReading)
        // One of them moves on: the other still waits.
        first?.leave()
        first?.leave()
        _ = await wait(upTo: 0.2) { !ahead.isReading }
        #expect(ahead.isReading)
        // The other leaves as well: nobody wants the reading, and it is told to stop.
        second?.leave()
        let stopped = await wait { !ahead.isReading }
        // Stopped, not failed: nothing is delivered, and the folder is not held against.
        #expect(stopped && outcomes == 0 && ahead.pausedCount == 0)
    }
}
