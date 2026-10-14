import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// The real kernel, the standard plugins and the real window shell, started without showing
/// anything and driven through commands and key presses. The parts have their own tests; these
/// check that they work together, including everything that happens across threads.
@MainActor @Suite(.serialized) struct Application {
    let box: Sandbox
    let memory = MemoryFileSystem()
    let ui = ScriptedInteraction()
    let settings = MemorySettings()
    let scratch = ScratchPasteboard()

    init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "2")
        try box.file("A/docs/in.txt", "inside")
        try box.file("B/one.txt", "old")
        try box.file("home/welcome.txt")
        func state(_ folder: String) -> PanelTabs.State {
            PanelTabs.State(tabs: [.init(location: box.url(folder))], active: 0)
        }
        settings.set(state("A"), forKey: "left.tabs")
        settings.set(state("B"), forKey: "right.tabs")
    }

    /// Waits, with the main thread free to work, until `condition` holds. (Spinning the run
    /// loop from inside a test would not do: the main queue is not drained re-entrantly.)
    @discardableResult
    func wait(upTo seconds: TimeInterval = 60, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// A started program, and what the tests reach into.
    @MainActor final class Running {
        let kernel: Kernel
        let shell: Shell
        var left: PanelViewController { shell.panelCoordinator.leftPanel }
        var right: PanelViewController { shell.panelCoordinator.rightPanel }
        var commands: CommandRegistry { kernel.commands }

        init(kernel: Kernel, shell: Shell) {
            self.kernel = kernel
            self.shell = shell
        }

        /// Ends watching and reading, so a finished test leaves nothing running.
        func stop() {
            shell.shutDown()
            kernel.shutdown()
        }

        func names(_ panel: PanelViewController) -> [String] { panel.model.items.map(\.name) }
        func cursor(_ panel: PanelViewController, on name: String) {
            panel.model.row(ofName: name).map(panel.model.moveCursor(to:))
        }
    }

    func start() async -> Running {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, ui: ui)
        kernel.fileSystems.register(memory)
        kernel.load(StandardPlugins.make(pasteboard: scratch.pasteboard, launchesApplications: false))
        let running = Running(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await settle(running)
        return running
    }

    /// Waits until nothing is being read and no job is running.
    func settle(_ app: Running) async {
        await wait { !app.shell.panelCoordinator.isLoading && !app.kernel.jobs.isBusy }
    }

    func press(
        _ app: Running,
        _ keyCode: UInt16,
        _ flags: NSEvent.ModifierFlags = [],
        in panel: PanelViewController? = nil
    ) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
        return (panel ?? app.shell.panelCoordinator.sourcePanel).handleKey(event)
    }

    // MARK: Start-up and structure

    @Test func startsWithThePanelsOfTheLastSession() async {
        let app = await start()
        defer { app.stop() }
        #expect(app.names(app.left) == ["docs", "one.txt", "two.txt"] && app.names(app.right) == ["one.txt"])
        #expect(app.kernel.panels.source === app.left && app.left.isActive && !app.right.isActive)
        #expect(app.left.tableView.numberOfRows == 4)
        #expect(
            app.kernel.plugins.count >= 21
                && Array(app.kernel.fileSystems.all.map(\.scheme).prefix(2)) == ["mem", "file"]
        )
    }

    @Test func aFolderThatIsGoneIsReplacedAtStartUp() async {
        settings.set(PanelTabs.State(tabs: [.init(location: box.url("vanished"))], active: 0), forKey: "left.tabs")
        let app = await start()
        defer { app.stop() }
        #expect(app.left.model.directory.lastPathComponent == "home" && app.names(app.left) == ["welcome.txt"])
        #expect(ui.log.isEmpty)
    }

    @Test func menusKeysAndFunctionBarComeFromThePlugins() async {
        let app = await start()
        defer { app.stop() }
        let menu = app.shell.makeMainMenu()
        let titles = menu.items.map(\.title)
        #expect(titles.first == "A File Manager" && titles.contains("Window"))
        #expect(
            titles.filter(["Files", "Edit", "Mark", "Commands", "Show"].contains) == [
                "Files", "Edit", "Mark", "Commands", "Show"
            ]
        )
        let menuCommands = menu.items.flatMap { $0.submenu?.items ?? [] }.compactMap(MenuBuilder.command(of:))
        #expect(Set(menuCommands).count == menuCommands.count)
        let contributed =
            app.kernel.menus.menus.flatMap(\.items).compactMap { $0 }
            + app.kernel.menus.contextMenu(onItem: true).compactMap { $0 }
        #expect(contributed.allSatisfy { app.commands[$0] != nil })
        #expect(app.kernel.keyClashes.isEmpty)
        #expect(
            app.shell.mainWindow.functionKeyTitles == [
                "F3 View", "F4 Edit", "F5 Copy", "F6 Move", "F7 NewFolder", "F8 Delete", "⌘Q Exit"
            ]
        )
        let copyItem = MenuBuilder.item(app.commands[.copy]!, keys: app.kernel.keyBindings)
        #expect(app.shell.mainWindow.validateMenuItem(copyItem) == false)
        app.cursor(app.left, on: "one.txt")
        #expect(app.shell.mainWindow.validateMenuItem(copyItem) == true)
        // The context menu on an item and on empty space.
        let onItem = app.left.contextMenu(forRow: 2)?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        #expect(
            onItem.starts(with: ["Open", "View", "Edit", "Open Folder in New Tab", "Copy…"]) && onItem.contains("Paste")
        )
        let onSpace = app.left.contextMenu(forRow: -1)?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        #expect(onSpace.first == "Paste" && !onSpace.contains("Open"))
    }

    @Test func theUsersKeyBindingsChangeMenuAndFunctionBar() async {
        settings.set(["cm_Copy": ["f9"], "cm_List": ["f5"]], forKey: KeyBindings.settingsKey)
        let app = await start()
        defer { app.stop() }
        #expect(
            app.shell.mainWindow.functionKeyTitles == [
                "F4 Edit", "F5 View", "F6 Move", "F7 NewFolder", "F8 Delete", "F9 Copy", "⌘Q Exit"
            ]
        )
        let copyItem = MenuBuilder.item(app.commands[.copy]!, keys: app.kernel.keyBindings)
        #expect(copyItem.keyEquivalent == String(UnicodeScalar(UInt32(NSF9FunctionKey))!))
        // F9 (key code 101) now copies: with the cursor on a file the prompt appears.
        app.cursor(app.left, on: "two.txt")
        ui.promptAnswers = [.cancel]
        #expect(press(app, 101))
        #expect(ui.log == ["prompt: Copy \"two.txt\" to [\(box.url("B").path)/two.txt]"])
    }

    // MARK: Keys

    @Test func cursorAndMarkingKeys() async {
        let app = await start()
        defer { app.stop() }
        #expect(press(app, 124) && app.left.model.cursorItem?.name == "two.txt")  // →
        #expect(press(app, 123) && app.left.model.cursorItem?.name == "docs")  // ←
        #expect(press(app, 115) && app.left.model.cursorIsOnParentRow)  // Home
        #expect(press(app, 119) && app.left.model.cursorItem?.name == "two.txt")  // End
        #expect(press(app, 116) && app.left.model.cursor == 0)  // Page Up
        #expect(app.left.tableView.selectedRow == 0)
        #expect(press(app, 125, .shift) && app.left.model.selection.isEmpty)  // Shift+↓ on [..]
        #expect(
            press(app, 125, .shift) && app.left.model.selection == ["docs"]
                && app.left.model.cursorItem?.name == "one.txt"
        )
        #expect(press(app, 126, .shift) && app.left.model.selection == ["docs", "one.txt"])  // Shift+↑
        #expect(press(app, 114) && app.left.model.selection == ["one.txt"])  // Insert on docs
        // A letter is bound to nothing: it goes on to the table, which finds files by typing.
        #expect(!press(app, 0))
        // Tab makes the other panel the source.
        #expect(press(app, 48) && app.kernel.panels.source === app.right && app.right.isActive)
        #expect(press(app, 48) && app.kernel.panels.source === app.left)
    }

    @Test func spaceSelectsAFolderAndCalculatesItsSize() async throws {
        try box.file("A/docs/deep/big.bin", String(repeating: "x", count: 5_000))
        let app = await start()
        defer { app.stop() }
        app.cursor(app.left, on: "docs")
        #expect(press(app, 49) && app.left.model.selection == ["docs"])
        let reached1 = await wait { app.left.model.cursorItem?.computedSize == 5_006 }
        #expect(reached1)
        #expect(app.left.model.totals.selectedBytes == 5_006)
    }

    @Test func aClickOnAColumnHeaderSorts() async {
        let app = await start()
        defer { app.stop() }
        let sizeColumn = app.left.tableView.tableColumns[2]
        let nameColumn = app.left.tableView.tableColumns[0]
        app.left.tableView(app.left.tableView, didClick: sizeColumn)
        #expect(app.left.model.sort == ListOrder(key: .size, descending: true))
        app.left.tableView(app.left.tableView, didClick: sizeColumn)
        #expect(app.left.model.sort == ListOrder(key: .size, descending: false))
        // A click in the other panel sorts that panel, which becomes the source.
        app.right.tableView(app.right.tableView, didClick: nameColumn)
        #expect(
            app.kernel.panels.source === app.right && app.right.model.sort == ListOrder(key: .name, descending: true)
        )
        #expect(app.left.model.sort.key == .size)
    }

    // MARK: Working with files

    @Test func copyMoveRenameAndDelete() async {
        let app = await start()
        defer { app.stop() }
        app.cursor(app.left, on: "one.txt")
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [0]
        app.commands.perform(.copy)
        #expect(app.kernel.jobs.isBusy && !app.commands.isEnabled(.delete))
        await settle(app)
        #expect(ui.log.contains("prompt: Copy \"one.txt\" to [\(box.url("B").path)/one.txt]"))
        #expect(box.read("B/one.txt") == "new")

        app.commands.perform(.selectAll)
        ui.promptAnswers = [.accept]
        ui.choiceAnswers = [1]
        app.commands.perform(.copy)
        await settle(app)
        #expect(box.read("B/docs/in.txt") == "inside" && box.exists("B/two.txt"))
        #expect(app.left.model.selection.isEmpty && app.names(app.right) == ["docs", "one.txt", "two.txt"])
        #expect(namesOnDisk("B") == ["docs", "one.txt", "two.txt"])

        app.cursor(app.left, on: "two.txt")
        app.commands.perform(.renameOnly, .text("renamed.txt"))
        await settle(app)
        #expect(
            box.exists("A/renamed.txt") && !box.exists("A/two.txt") && app.left.model.cursorItem?.name == "renamed.txt"
        )
        ui.promptAnswers = [.accept]
        app.commands.perform(.renameMove)
        await settle(app)
        #expect(
            box.exists("B/renamed.txt") && !box.exists("A/renamed.txt") && app.names(app.right).contains("renamed.txt")
        )

        ui.promptAnswers = [.text("made/inner")]
        app.commands.perform(.makeDirectory)
        await settle(app)
        #expect(box.exists("A/made/inner") && app.left.model.cursorItem?.name == "made")
        ui.choiceAnswers = [0, 0]
        app.commands.perform(.deleteDirectly)
        await settle(app)
        #expect(!box.exists("A/made") && !app.names(app.left).contains("made"))
        app.cursor(app.left, on: "one.txt")
        ui.choiceAnswers = [1]
        app.commands.perform(.deleteDirectly)
        await settle(app)
        #expect(box.exists("A/one.txt"))
    }

    func namesOnDisk(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: box.url(folder).path)) ?? []).sorted()
    }

    @Test func navigationAndFolderTabs() async {
        let app = await start()
        defer { app.stop() }
        app.cursor(app.left, on: "docs")
        app.commands.perform(.open)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs" && app.names(app.left) == ["in.txt"])
        app.commands.perform(.goToParent)
        await settle(app)
        #expect(app.left.model.cursorItem?.name == "docs")
        app.commands.perform(.goBack)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs")
        app.commands.perform(.changeDirectory, .location(box.url("B/one.txt")))
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "B" && app.left.model.cursorItem?.name == "one.txt")
        app.commands.perform(.goBack)
        await settle(app)
        app.commands.perform(.goToParent)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A")

        app.commands.perform(.newTab)
        #expect(app.left.tabs.count == 2 && app.left.tabs.activeIndex == 1)
        app.cursor(app.left, on: "docs")
        app.commands.perform(.openInNewTab)
        #expect(app.left.tabs.count == 3 && app.left.tabs.activeIndex == 1 && !app.left.tabs.tabs[2].isListed)
        app.commands.perform(.nextTab)
        await settle(app)
        // The background tab is read when it is shown for the first time.
        #expect(app.left.model.directory.lastPathComponent == "docs" && app.names(app.left) == ["in.txt"])
        #expect(app.left.tableView.numberOfRows == 2)
        app.commands.perform(.closeTab)
        app.commands.perform(.closeTab)
        await settle(app)
        #expect(
            app.left.tabs.count == 1 && app.left.model.directory.lastPathComponent == "A"
                && !app.commands.isEnabled(.closeTab)
        )
        app.shell.saveState()
        #expect(settings.value(PanelTabs.State.self, forKey: "left.tabs")?.tabs.count == 1)
    }

    @Test func aFailedNavigationLeavesThePanelAndTellsTheUser() async {
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.changeDirectory, .location(box.url("nowhere")))
        await settle(app)
        // The alert is raised after the code that found the error has returned.
        _ = await wait(upTo: 2) { !ui.log.isEmpty }
        #expect(app.left.model.directory.lastPathComponent == "A" && ui.log == ["inform: The folder cannot be read!"])
    }

    // MARK: Changes from outside

    @Test func changesMadeByOtherProgramsAppearByThemselves() async throws {
        let app = await start()
        defer { app.stop() }
        try box.file("A/from-outside.txt", "x")
        let reached2 = await wait { app.names(app.left).contains("from-outside.txt") }
        #expect(reached2)
        // The other panel, which shows another folder, is left alone.
        #expect(app.names(app.right) == ["one.txt"])
    }

    @Test func aFolderThatVanishesIsLeftForItsParent() async throws {
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.changeDirectory, .location(box.url("A/docs")))
        await settle(app)
        try FileManager.default.removeItem(at: box.url("A/docs"))
        app.commands.perform(.reread)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A" && app.names(app.left) == ["one.txt", "two.txt"])
    }

    // MARK: Large and slow directories

    @Test func aSlowDirectoryIsShownWhileItIsStillArriving() async {
        let count = 3_000
        // The listing is held after its second batch until the test says go; no timing decides
        // whether it is still arriving when the checks are made.
        let slow = ScriptedFileSystem()
        let arriving = (0..<count).map { String(format: "file%04d.txt", ($0 * 7_919) % count) } + ["zz-folder"]
        slow.batches = stride(from: 0, to: arriving.count, by: 250)
            .map { start in
                arriving[start..<min(start + 250, arriving.count)]
                    .map {
                        slow.item(named: $0, in: "/slow", isDirectory: $0 == "zz-folder")
                    }
            }
        slow.holdBefore = 2
        slow.pauseBeforeSecondBatch = 0.25
        defer { slow.open() }
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(slow)
        app.left.show(slow.url("/slow"))

        // After a moment the panel shows what has arrived, and says that more is coming.
        let reached3 = await wait { app.left.model.directory.path == "/slow" && !app.left.model.items.isEmpty }
        #expect(reached3)
        #expect(!app.left.model.isComplete && app.left.isLoading && app.left.model.items.count < count)
        #expect(app.left.tableView.numberOfRows == app.left.model.rowCount)
        // What is there can be used: the cursor moves, an item is marked; "all" has to wait.
        #expect(press(app, 124) && app.left.model.cursorItem != nil)
        let underCursor = app.left.model.cursorItem!.name
        #expect(press(app, 49) && app.left.model.selection == [underCursor])
        #expect(!app.commands.isEnabled(.selectAll) && app.commands.isEnabled(.copy))

        // The rest arrives without disturbing the cursor or the selection.
        let partial = app.left.model.items.count
        slow.open()
        let reached4 = await wait { app.left.model.items.count > partial }
        #expect(reached4)
        #expect(app.left.model.cursorItem?.name == underCursor && app.left.model.selection == [underCursor])
        await settle(app)
        #expect(app.left.model.isComplete && app.left.model.items.count == count + 1 && !app.left.isLoading)
        #expect(app.left.model.cursorItem?.name == underCursor && app.left.model.selection == [underCursor])
        // Everything is in order, the folder first.
        let names = app.names(app.left)
        #expect(
            names.first == "zz-folder"
                && Array(names.dropFirst()) == (0..<count).map { String(format: "file%04d.txt", $0) }
        )
        #expect(app.commands.isEnabled(.selectAll))
    }

    @Test func aFolderOnASlowServerIsEnteredAtOnce() async {
        // The server says nothing until the test lets it.
        let late = ScriptedFileSystem()
        late.batches = [(0..<10).map { late.item(named: "file\($0).txt", in: "/late") }]
        late.holdBefore = 0
        defer { late.open() }
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(late)
        app.commands.perform(.changeDirectory, .location(late.url("/late")))
        // The server has not said anything yet, but the panel is in the folder: its path is
        // shown, the list is empty apart from [..], and a wheel turns in the status line.
        let entered = await wait { app.left.model.directory.path == "/late" }
        #expect(entered && app.left.model.isOpening && app.left.model.items.isEmpty)
        #expect(app.left.tableView.numberOfRows == 1 && app.left.showsActivity)
        #expect(app.left.statusLineText == "Reading \(app.kernel.fileSystems.displayPath(late.url("/late")))…")
        // Commands that need the entries wait; the way back is open.
        #expect(
            !app.commands.isEnabled(.copy) && !app.commands.isEnabled(.selectAll) && app.commands.isEnabled(.goToParent)
        )
        #expect(app.left.model.backLocation?.lastPathComponent == "A")

        late.open()
        await settle(app)
        #expect(app.names(app.left).count == 10 && app.left.model.isComplete && !app.left.showsActivity)
        #expect(app.left.statusLineText == "0 k / 0 k in 0 / 10 file(s)")
        #expect(app.left.model.backLocation?.lastPathComponent == "A" && app.left.model.forwardLocation == nil)
    }

    @Test func leavingAFolderThatIsStillBeingOpened() async {
        let late = ScriptedFileSystem()
        late.batches = [[late.item(named: "file.txt", in: "/late")]]
        late.batchesAt["/"] = [[late.item(named: "late", in: "", isDirectory: true)]]
        late.holdBefore = 0
        defer { late.open() }
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(late)
        app.left.show(late.url("/late"))
        let entered = await wait { app.left.model.isOpening }
        #expect(entered)
        // Backspace: up again, without waiting for the answer about this folder.
        app.commands.perform(.goToParent)
        await settle(app)
        #expect(
            app.left.model.directory.path == "/" && app.left.model.cursorItem?.name == "late" && !app.left.showsActivity
        )
        // The abandoned reading is ended, and the answer it might have given changes nothing.
        #expect(await wait(upTo: 60) { late.listingsBegun == 2 && late.listingsEnded == 2 })
        late.open()
        #expect(app.left.model.directory.path == "/" && app.left.model.isComplete)
    }

    @Test func aSlowFolderThatCannotBeReadIsLeftAgain() async {
        // The server does not answer until the test lets it, and then says no.
        let locked = ScriptedFileSystem()
        locked.holdBefore = 0
        locked.failure = CocoaError(.fileReadNoPermission)
        defer { locked.open() }
        let app = await start()
        defer { app.stop() }
        app.kernel.fileSystems.register(locked)
        app.cursor(app.left, on: "one.txt")
        app.left.show(locked.url("/locked"))
        let entered = await wait { app.left.model.directory.path == "/locked" && app.left.model.isOpening }
        #expect(entered)
        locked.open()
        await settle(app)
        _ = await wait(upTo: 2) { !ui.log.isEmpty }
        // Back in the folder it came from, with the cursor where it was, and the user is told.
        #expect(
            app.left.model.directory.lastPathComponent == "A" && app.names(app.left) == ["docs", "one.txt", "two.txt"]
        )
        #expect(app.left.model.cursorItem?.name == "one.txt" && app.left.model.isComplete && !app.left.showsActivity)
        #expect(app.left.model.forwardLocation == nil && ui.log == ["inform: The folder cannot be read!"])
        #expect(app.left.tableView.numberOfRows == 4)
    }

    @Test func anOrdinaryFolderAppearsWholeWithoutAnEmptyMoment() async {
        let app = await start()
        defer { app.stop() }
        var sawEmpty = false
        app.left.model.onChange = { [weak panel = app.left] _ in
            if panel?.model.isOpening == true { sawEmpty = true }
        }
        app.cursor(app.left, on: "docs")
        app.commands.perform(.open)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs" && !sawEmpty)
    }

    @Test func goingElsewhereStopsASlowListing() async {
        for index in 0..<2_000 { memory.addFile("/slow/file\(index).txt") }
        memory.addFile("/quick/only.txt")
        memory.listBatchSize = 100
        // Slow enough that the folder is "arriving" for most of a minute: the test has to see
        // it in that state, and under the thread sanitizer a listing of 2 s was over, or had
        // not begun, whenever the test got to look within the 10 s it used to wait.
        memory.listBatchDelay = 2
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/slow"))
        let reached5 = await wait(upTo: 600) { app.left.model.directory.path == "/slow" && !app.left.model.isComplete }
        #expect(reached5)
        app.left.show(memory.url("/quick"))
        await wait(upTo: 600) { app.left.model.directory.path == "/quick" && app.left.model.isComplete }
        await settle(app)
        #expect(
            app.left.model.directory.path == "/quick" && app.names(app.left) == ["only.txt"]
                && app.left.model.isComplete
        )
        // Nothing of the abandoned listing arrives later (its next piece would have been due within 2 s).
        await wait(upTo: 3) { false }
        #expect(app.names(app.left) == ["only.txt"])
    }

    // MARK: Jobs

    @Test func jobsRunOneAfterAnotherAndBlockChangingCommands() async {
        let app = await start()
        defer { app.stop() }
        app.cursor(app.left, on: "one.txt")
        var log: [String] = []
        app.kernel.jobs.run(
            title: "First",
            work: { _ -> String in
                Thread.sleep(forTimeInterval: 0.2)
                return "first on main: \(Thread.isMainThread)"
            },
            completion: { log.append($0) }
        )
        app.kernel.jobs.run(title: "Second", work: { _ in "second" }, completion: { log.append($0) })
        #expect(app.kernel.jobs.isBusy && log.isEmpty)
        // Commands that change files or panels wait; viewing and moving the cursor do not.
        #expect(!app.commands.isEnabled(.copy) && !app.commands.isEnabled(.goToParent))
        #expect(app.commands.isEnabled(.view) && app.commands.isEnabled(.cursorToLastEntry))
        await settle(app)
        #expect(log == ["first on main: false", "second"])
        #expect(app.commands.isEnabled(.copy))
    }

    @Test func cancellingEverythingStopsRunningAndWaitingJobs() async {
        let app = await start()
        defer { app.stop() }
        var log: [String] = []
        func job(_ name: String) {
            app.kernel.jobs.run(
                title: name,
                work: { monitor -> String in
                    for _ in 0..<200 where !monitor.cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                    return monitor.cancellation.isCancelled ? "\(name) cancelled" : "\(name) finished"
                },
                completion: { log.append($0) }
            )
        }
        job("first")
        job("second")
        var idle = false
        app.shell.jobService.cancelAll { idle = true }
        #expect(!idle)
        let reached6 = await wait(upTo: 600) { idle }
        #expect(reached6)
        #expect(log == ["first cancelled", "second cancelled"] && !app.kernel.jobs.isBusy)
        var immediately = false
        app.shell.jobService.cancelAll { immediately = true }
        #expect(immediately)
    }

    @Test func aJobCanAskTheUserFromItsOwnThread() async {
        let app = await start()
        defer { app.stop() }
        ui.choiceAnswers = [1]
        var answer = -1
        app.kernel.jobs.run(
            title: "Asking",
            work: { monitor in
                monitor.ask { ui.choose("Really?", detail: "", buttons: ["Yes", "No"], style: .warning) }
            },
            completion: { answer = $0 }
        )
        await settle(app)
        #expect(answer == 1 && ui.log == ["choose: Really? / "])
        // The same from a plugin that has no job at hand.
        ui.choiceAnswers = [0]
        // Changed on the main thread, where the test reads it.
        nonisolated(unsafe) var viaKernel = -1
        DispatchQueue.global()
            .async {
                let result = app.kernel.askUser {
                    $0.choose("Password?", detail: "", buttons: ["OK", "Cancel"], style: .information)
                }
                DispatchQueue.main.async { viaKernel = result }
            }
        let reached7 = await wait { viaKernel == 0 }
        #expect(reached7)
    }
}
