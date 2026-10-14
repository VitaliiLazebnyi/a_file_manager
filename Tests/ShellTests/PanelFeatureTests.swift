import AFMContracts
import AFMKernel
import AppKit
import StandardPlugins
import TestSupport
import Testing

@testable import AFMShell

/// The file panel on screen with the real kernel, the standard plugins and the real shell,
/// without showing a window: the three views, plugin columns, the quick filter, path bar,
/// tabs and drag and drop.
@MainActor @Suite(.serialized) struct PanelFeatures {
    let box: Sandbox
    let memory = MemoryFileSystem()
    let ui = ScriptedInteraction()
    let settings = MemorySettings()
    let probe = PanelStores.Probe()

    init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        try box.file("A/one.txt", "new")
        try box.file("A/two.txt", "2")
        try box.file("A/docs/in.txt", "inside")
        try box.file("B/fresh.txt", "fresh")
        try box.file("home/welcome.txt")
        memory.addFile("/M/remote.txt", "far")
        func state(_ folder: String) -> PanelTabs.State {
            PanelTabs.State(tabs: [.init(location: box.url(folder))], active: 0)
        }
        settings.set(state("A"), forKey: "left.tabs")
        settings.set(state("B"), forKey: "right.tabs")
    }

    /// Offers two columns, as a content plugin would; the first is slow.
    final class ColumnsPlugin: Plugin {
        let name = "Columns"
        let probe: PanelStores.Probe
        init(probe: PanelStores.Probe) { self.probe = probe }

        func start(in kernel: Kernel) {
            let probe = probe
            kernel.columns.register(
                ContentColumn(id: "upper", title: "Upper", width: 90) { item in
                    probe.enter()
                    Thread.sleep(forTimeInterval: 0.01)
                    probe.leave()
                    return item.name.uppercased()
                })
            kernel.columns.register(
                ContentColumn(id: "length", title: "Length", alignsRight: true) { "\($0.name.count)" })
        }
    }

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

        func stop() {
            shell.shutDown()
            kernel.shutdown()
        }

        func names(_ panel: PanelViewController) -> [String] { panel.model.items.map(\.name) }
        func cursor(_ panel: PanelViewController, on name: String) {
            panel.model.row(ofName: name).map(panel.model.moveCursor(to:))
        }

        /// Gives every view the size it has in the window.
        func layOut() {
            shell.mainWindow.window?.contentView?.layoutSubtreeIfNeeded()
            left.gridView.layOut()
            right.gridView.layOut()
        }
    }

    @discardableResult
    func wait(upTo seconds: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }

    func start() async -> Running {
        let kernel = Kernel(productName: StandardPlugins.productName, settings: settings, ui: ui)
        kernel.fileSystems.register(memory)
        kernel.load(CorePlugins.make() + [ColumnsPlugin(probe: probe)])
        let running = Running(kernel: kernel, shell: Shell(kernel: kernel, home: box.url("home")))
        await settle(running)
        return running
    }

    func settle(_ app: Running) async {
        await wait { !app.shell.panelCoordinator.isLoading && !app.kernel.jobs.isBusy }
    }

    func key(_ keyCode: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    func press(_ app: Running, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) -> Bool {
        app.shell.panelCoordinator.sourcePanel.handleKey(key(keyCode, "", flags))
    }

    /// Has a view draw itself into a bitmap, as it would on screen.
    func draw(_ view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else { return }
        view.cacheDisplay(in: view.visibleRect, to: bitmap)
    }

    // MARK: Views

    @Test func theViewOfEachPanelIsSwitchedAndRemembered() async {
        let app = await start()
        #expect(
            app.left.viewMode == .full && !app.left.showsGrid
                && app.left.tableView.enclosingScrollView?.isHidden == false)
        #expect(app.kernel.keyBindings.conflicts.isEmpty)
        // Ctrl+F1 (key code 122).
        #expect(press(app, 122, .control) && app.left.viewMode == .brief && app.commands.isChecked(.viewBrief))
        #expect(
            app.left.showsGrid && app.left.tableView.enclosingScrollView?.isHidden == true
                && app.left.gridView.enclosingScrollView?.isHidden == false)
        #expect(app.left.gridView.geometry.flow == .columns && app.left.gridView.geometry.count == 4)
        #expect(app.right.viewMode == .full && settings.value(PanelViewState.self, forKey: "left.view")?.mode == 1)
        #expect(
            press(app, 122, [.control, .shift]) && app.left.viewMode == .thumbnails
                && app.left.gridView.geometry.flow == .rows)
        #expect(app.left.gridView.geometry.cell == CGSize(width: 116, height: 136))
        app.stop()

        let again = await start()
        defer { again.stop() }
        #expect(
            again.left.viewMode == .thumbnails && again.right.viewMode == .full
                && again.left.gridView.geometry.count == 4)
        #expect(again.commands.isChecked(.viewThumbnails))
        // Ctrl+F2 (key code 120) brings the table back, with the list in it.
        #expect(press(again, 120, .control) && again.left.viewMode == .full && again.left.tableView.numberOfRows == 4)
        #expect(again.left.tableView.selectedRow == again.left.model.cursor)
    }

    @Test func cursorMarkingAndKeysWorkInTheBriefView() async throws {
        for index in 0..<90 { try box.file(String(format: "A/many/f%02d.txt", index)) }
        let app = await start()
        defer { app.stop() }
        app.left.show(box.url("A/many"))
        await settle(app)
        app.commands.perform(.viewBrief)
        app.layOut()
        let grid = app.left.gridView
        let perColumn = grid.geometry.perLine
        #expect(
            grid.geometry.count == 91 && perColumn > 5 && perColumn < 91
                && grid.frame.width >= grid.geometry.cell.width * 2)
        // → and ← step a column; ↓ and ↑, which are bound to nothing, a row.
        #expect(press(app, 124) && app.left.model.cursor == perColumn)
        grid.keyDown(with: key(125))
        #expect(app.left.model.cursor == perColumn + 1)
        #expect(press(app, 123) && app.left.model.cursor == 1)
        grid.keyDown(with: key(126))
        #expect(app.left.model.cursorIsOnParentRow)
        // The other keys are the ones of the Full view: End, Home, Page Down, Insert, Shift+↓, Space.
        #expect(press(app, 119) && app.left.model.cursor == 90 && press(app, 115) && app.left.model.cursor == 0)
        #expect(press(app, 121) && app.left.model.cursor == min(90, grid.geometry.pageSize))
        app.cursor(app.left, on: "f03.txt")
        #expect(press(app, 114) && press(app, 125, .shift) && app.left.model.selection == ["f03.txt", "f04.txt"])
        #expect(press(app, 49) && app.left.model.selection == ["f03.txt", "f04.txt", "f05.txt"])
        // Letters find a file by typing.
        grid.keyDown(with: key(3, "f"))
        grid.keyDown(with: key(18, "1"))
        grid.keyDown(with: key(23, "5"))
        #expect(app.left.model.cursorItem?.name == "f15.txt")
        // Clicks: Cmd toggles, Shift marks the range from the cursor.
        #expect(
            app.left.handleClick(row: 20, modifiers: .command) && app.left.model.selection.contains("f19.txt")
                && app.left.model.cursor == 20)
        #expect(
            app.left.handleClick(row: 23, modifiers: .shift)
                && app.left.model.selection.isSuperset(of: ["f20.txt", "f21.txt", "f22.txt"]))
        app.left.clicked(row: 2)
        #expect(app.left.model.cursorItem?.name == "f01.txt")
        // The status line describes the item under the cursor when nothing is marked.
        app.commands.perform(.unselectAll)
        #expect(app.left.statusLineText.hasPrefix("f01  txt  1  "))
        app.commands.perform(.selectAll)
        #expect(app.left.statusLineText == "0 k / 0 k in 90 / 90 file(s)")
        // The in-place editor and the context menu are the same as in the Full view.
        app.left.beginRename()
        #expect(app.left.isRenaming)
        let menu = app.left.contextMenu(forRow: 5)?.items.map(\.title) ?? []
        #expect(menu.contains("Open") && app.left.model.cursor == 5)
        #expect(app.left.contextMenu(forRow: -1)?.items.contains { $0.title == "Open" } == false)
        // Enter opens, as everywhere.
        app.left.model.moveCursor(to: 0)
        #expect(press(app, 36))
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A" && app.left.gridView.geometry.count == 5)
    }

    @Test func thumbnailsAreMadeInTheBackgroundForLocalFilesOnly() async {
        let app = await start()
        defer { app.stop() }
        let source = PanelStores.ScriptedThumbnails()
        app.left.thumbnails.source = source
        app.commands.perform(.viewThumbnails)
        app.layOut()
        #expect(app.left.gridView.geometry.flow == .rows && app.left.gridView.geometry.perLine > 1)
        draw(app.left.gridView)
        // Files get pictures; the folder and `[..]` show icons.
        #expect(Set(source.requested) == ["one.txt", "two.txt"] && app.left.thumbnails.runningCount == 2)
        source.answer("one.txt", with: NSImage(size: NSSize(width: 40, height: 30)))
        let arrived = await wait { app.left.thumbnails.runningCount == 1 }
        #expect(arrived)
        draw(app.left.gridView)
        #expect(source.requested.count == 2)
        // Leaving the folder gives up what is still being made.
        app.left.show(memory.url("/M"))
        await settle(app)
        #expect(source.cancelled == ["two.txt"] && app.left.thumbnails.runningCount == 0)
        // Items of other file systems show the icon of their type and ask for nothing.
        draw(app.left.gridView)
        #expect(source.requested.count == 2 && app.left.gridView.geometry.count == 2)
    }

    // MARK: Plugin columns

    @Test func pluginColumnsAreFilledInFromTheBackgroundAndRemembered() async {
        let app = await start()
        #expect(app.left.tableView.tableColumns.count == 5)
        app.left.extraColumns = ["upper", "unknown"]
        let table = app.left.tableView
        #expect(
            table.tableColumns.map(\.title) == ["Name", "Ext", "Size", "Date", "Attr", "Upper"]
                && table.tableColumns[5].width == 90)
        func text(_ column: Int, _ row: Int) -> String? {
            (app.left.tableView(table, viewFor: table.tableColumns[column], row: row) as? NSTableCellView)?.textField?
                .stringValue
        }
        // Drawing a row asks for its value and does not wait for it: the cells are empty, and
        // no value is ever worked out on the main thread (checked below).
        #expect(text(5, 2) == "" && text(5, 0) == "")
        let computed = await wait { !app.left.columnValues.isBusy }
        #expect(computed && text(5, 2) == "ONE.TXT" && text(5, 0) == "")
        #expect((1...3).contains(probe.counts.calls) && probe.counts.onMain == 0)
        #expect(text(0, 2) == "one" && text(2, 2) == "3")

        // The header's menu offers the views and the columns.
        app.left.fillHeaderMenu()
        let items = app.left.headerMenu.items
        #expect(
            items.map(\.title) == ["Brief", "Full", "Thumbnail View", "", "Upper", "Length", "", "Custom Columns…"])
        #expect(items[1].state == .on && items[4].state == .on && items[5].state == .off)
        app.left.extraColumnChosen(items[5])
        #expect(
            app.left.extraColumns == ["upper", "unknown", "length"] && table.tableColumns.count == 7
                && text(6, 2) == "")
        await wait { !app.left.columnValues.isBusy }
        #expect(text(6, 2) == "7")
        app.left.toggleExtraColumn("upper")
        #expect(table.tableColumns.map(\.title).suffix(2) == ["Attr", "Length"])

        // Columns and widths come back with the next start, for this panel only.
        table.tableColumns[2].width = 137
        table.tableColumns[5].width = 61
        app.shell.saveState()
        let saved = settings.value(PanelViewState.self, forKey: "left.view")
        #expect(
            saved?.extraColumns == ["unknown", "length"] && saved?.columnWidths["size"] == 137
                && saved?.columnWidths["+length"] == 61)
        app.stop()
        let again = await start()
        defer { again.stop() }
        #expect(again.left.extraColumns == ["unknown", "length"] && again.right.extraColumns.isEmpty)
        #expect(
            again.left.tableView.tableColumns.map(\.title).last == "Length"
                && again.right.tableView.tableColumns.count == 5)
        #expect(again.left.tableView.tableColumns[2].width == 137 && again.left.tableView.tableColumns[5].width == 61)
        // The Custom Columns dialog of the Show menu sets the same list.
        ui.formAnswers = [.values(["upper": .flag(true), "length": .flag(false)])]
        again.commands.perform("cm_CustomColumnConfig")
        #expect(again.left.extraColumns == ["unknown", "upper"])
    }

    // MARK: Quick filter

    @Test func theQuickFilterNarrowsTheListWhileTyping() async {
        let app = await start()
        defer { app.stop() }
        #expect(
            app.left.quickFilterBar.isHidden
                && app.kernel.keyBindings.command(for: Shortcut(.character("s"), .control)) == .quickFilter)
        app.commands.perform(.quickFilter)
        #expect(
            !app.left.quickFilterBar.isHidden && app.left.quickFilterText == "" && app.right.quickFilterBar.isHidden)
        app.left.quickFilterTyped("t")
        #expect(app.names(app.left) == ["one.txt", "two.txt"] && app.left.tableView.numberOfRows == 3)
        app.left.quickFilterTyped("tw")
        #expect(
            app.names(app.left) == ["two.txt"] && app.left.statusLineText == "0 k / 0 k in 0 / 1 file(s)   ⏷ Filter: tw"
        )
        app.left.quickFilterTyped("*o*")
        #expect(app.names(app.left) == ["docs", "one.txt", "two.txt"])
        app.left.quickFilterTyped("O?E*")
        #expect(app.names(app.left) == ["one.txt"])
        // Enter goes back to the list and keeps filter and field; the path bar still shows the display mask.
        app.left.leaveQuickFilterField()
        #expect(
            !app.left.quickFilterBar.isHidden && app.names(app.left) == ["one.txt"]
                && app.left.pathBarText.hasSuffix("/A/*.*"))
        // A reading of the folder keeps the filter.
        app.commands.perform(.reread)
        await settle(app)
        #expect(app.names(app.left) == ["one.txt"] && app.left.quickFilterText == "O?E*")
        // Esc in the list takes it away.
        #expect(
            press(app, 53) && app.left.quickFilterBar.isHidden && app.names(app.left).count == 3
                && app.left.quickFilterText == nil)
        #expect(!app.left.statusLineText.contains("Filter") && !press(app, 53))
        // A field that was left empty goes away by itself.
        app.commands.perform(.quickFilter)
        app.left.leaveQuickFilterField()
        #expect(app.left.quickFilterBar.isHidden)
    }

    @Test func theQuickFilterEndsWithTheFolderAndLiesOverTheDisplayFilter() async {
        let app = await start()
        defer { app.stop() }
        // Going into a folder: the filter does not hide where the cursor should go.
        app.commands.perform(.changeDirectory, .location(box.url("A/docs")))
        await settle(app)
        app.commands.perform(.quickFilter)
        app.left.quickFilterTyped("zzz")
        #expect(app.names(app.left).isEmpty)
        app.commands.perform(.goToParent)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A" && app.left.model.cursorItem?.name == "docs")
        #expect(app.left.model.filter == nil && app.left.quickFilterBar.isHidden && app.names(app.left).count == 3)

        // Over a display filter: both count, and the display filter comes back.
        app.commands.perform("cm_SrcUserDef", .text("*.txt | docs/"))
        #expect(app.names(app.left) == ["one.txt", "two.txt"] && app.left.pathBarText.hasSuffix("/A/*.txt | docs/"))
        app.commands.perform(.quickFilter)
        app.left.quickFilterTyped("o")
        app.left.quickFilterTyped("on")
        #expect(
            app.names(app.left) == ["one.txt"] && app.commands.isChecked("cm_SrcUserDef")
                && app.left.pathBarText.hasSuffix("/A/*.txt | docs/"))
        app.left.removeQuickFilter()
        #expect(app.names(app.left) == ["one.txt", "two.txt"] && app.left.model.filter?.title == "*.txt | docs/")
        // All Files removes a quick filter as well.
        app.commands.perform(.quickFilter)
        app.left.quickFilterTyped("tw")
        app.commands.perform("cm_SrcAllFiles")
        #expect(app.names(app.left).count == 3 && app.left.quickFilterBar.isHidden && app.left.quickFilterText == nil)
        #expect(app.left.pathBarText.hasSuffix("/A/*.*"))
        // Each tab has its own.
        app.commands.perform(.quickFilter)
        app.left.quickFilterTyped("one")
        app.commands.perform(.newTab)
        await settle(app)
        // The new tab was copied from this one, but the quick filter stays with the old tab: the
        // copy shows the folder as the display filter lets it through, and has no filter left over.
        #expect(app.left.quickFilterBar.isHidden && app.left.quickFilterText == nil)
        #expect(app.left.model.filter == nil && app.names(app.left).count == 3 && !press(app, 53))
        app.commands.perform(.previousTab)
        await settle(app)
        #expect(
            !app.left.quickFilterBar.isHidden && app.left.quickFilterBar.text == "one"
                && app.names(app.left) == ["one.txt"])
    }

    @Test func typingInTheQuickFilterWaitsForTheLastKeyAndEnterDoesNotWaitAtAll() async {
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.quickFilter)
        app.left.quickFilterBar.text = "t"
        app.left.quickFilterEdited("t")
        app.left.quickFilterBar.text = "tw"
        app.left.quickFilterEdited("tw")
        // Not filtered key by key: the list follows in a moment, once.
        #expect(app.names(app.left).count == 3)
        // (The limit only ends a wait for a list that never follows; under the thread
        // sanitizer the moment has taken more than the 2 s this used to allow.)
        let followed = await wait(upTo: 600) { app.names(app.left) == ["two.txt"] }
        #expect(followed && app.left.quickFilterText == "tw")
        // Enter filters with what is typed, at once.
        app.left.quickFilterBar.text = "one"
        app.left.quickFilterEdited("one")
        app.left.leaveQuickFilterField()
        #expect(app.names(app.left) == ["one.txt"] && app.left.quickFilterText == "one")
        // Esc before the list followed leaves it as it was.
        app.left.quickFilterBar.text = "zzz"
        app.left.quickFilterEdited("zzz")
        app.left.removeQuickFilter()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(app.names(app.left).count == 3 && app.left.quickFilterText == nil)
    }

    @Test func clicksThatMarkAreRefusedWhileAJobRunsButAPlainClickIsLeftToTheList() async {
        let app = await start()
        defer { app.stop() }
        app.commands.isBlocked = { true }
        #expect(!app.left.handleClick(row: 2, modifiers: []))
        #expect(app.left.handleClick(row: 2, modifiers: .command) && app.left.model.selection.isEmpty)
        #expect(app.left.handleClick(row: 2, modifiers: .shift) && app.left.model.selection.isEmpty)
        app.commands.isBlocked = { false }
        #expect(
            app.left.handleClick(row: 2, modifiers: .command)
                && app.left.model.selection == [app.left.model.item(atRow: 2)!.name])
    }

    // MARK: Path bar and tabs

    @Test func thePathBarLeadsToTheFoldersAbove() async {
        let app = await start()
        defer { app.stop() }
        app.layOut()
        let bar = app.left.pathBar
        #expect(app.left.pathBarText == box.url("A").path + "/*.*")
        #expect(bar.segments.last?.location.path == box.url("A").path && bar.segments.first?.location.path == "/")
        // A click in the right panel's bar goes up there and makes that panel the source.
        let rightBar = app.right.pathBar
        rightBar.click(at: rightBar.center(ofSegment: rightBar.segments.count - 2), count: 1)
        await settle(app)
        #expect(app.right.model.directory.path == box.root.path && app.kernel.panels.source === app.right)
        #expect(app.right.pathBarText == box.root.path + "/*.*")
        // A double click on the bar edits the path.
        ui.promptAnswers = [.text(box.url("A/docs").path)]
        bar.click(at: NSPoint(x: bar.bounds.maxX - 3, y: 10), count: 2)
        await settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs" && app.kernel.panels.source === app.left)
        // The menu copies the path.
        #expect(app.left.pathMenu().items.map(\.title).starts(with: ["Copy Path", "", "Go to Folder…"]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        app.left.copyPath(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == box.url("A/docs").path)
        // Other file systems write their paths their own way.
        app.left.show(memory.url("/M"))
        await settle(app)
        #expect(app.left.pathBarText == "mem:/M/*.*" && bar.segments.map(\.location.path) == ["/", "/M"])
    }

    @Test func tabsHaveAMenuAndCanBeMoved() async {
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.newTab)
        app.commands.perform(.changeDirectory, .location(box.url("A/docs")))
        await settle(app)
        app.left.tabs.insertTab(showing: box.url("home"), activate: false)
        #expect(
            app.left.tabBar.titles == ["A", "docs", "home"] && !app.left.tabBar.isHidden && app.right.tabBar.isHidden)
        // The menu of a tab shows that tab and offers the commands the plugins registered.
        let menu = app.left.tabMenu(forTab: 0)?.items.map(\.title) ?? []
        await settle(app)
        #expect(
            app.left.tabs.activeIndex == 0
                && ["New Folder Tab", "Close Tab", "Next Tab", "Previous Tab"].allSatisfy(menu.contains))
        app.left.moveTab(from: 0, to: 2)
        #expect(app.left.tabBar.titles == ["docs", "home", "A"] && app.left.tabs.activeIndex == 2)
        // Custom titles and the mark of locked tabs come from the model.
        app.left.tabs.tabs[0].customTitle = "Papers"
        app.left.tabs.tabs[0].isLocked = true
        app.left.tabs.activate(0)
        await settle(app)
        #expect(app.left.tabBar.titles == ["*Papers", "home", "A"])
    }

    // MARK: Drag and drop

    @Test func whatADragCarriesAndWhereADropGoes() async {
        let app = await start()
        defer { app.stop() }
        let all: NSDragOperation = [.copy, .move, .generic]
        // Rows of the left panel: [..], docs, one.txt, two.txt.
        #expect(
            app.left.draggedItems(fromRow: 0).isEmpty && app.left.draggedItems(fromRow: 2).map(\.name) == ["one.txt"])
        app.left.model.setSelected(true, rows: 2...3)
        #expect(
            app.left.draggedItems(fromRow: 3).map(\.name) == ["one.txt", "two.txt"]
                && app.left.draggedItems(fromRow: 1).map(\.name) == ["docs"])
        #expect(app.left.draggingItems(forRow: 3).count == 2)

        let fresh = box.url("B/fresh.txt")
        // Onto a folder row: into that folder. Onto a file or empty space: into the panel's folder.
        let onFolder = app.left.dropPlan(for: [fresh], row: 1, modifiers: [], allowed: all)
        #expect(onFolder?.destination.path == box.url("A/docs").path && onFolder?.row == 1 && onFolder?.kind == .move)
        let onFile = app.left.dropPlan(for: [fresh], row: 2, modifiers: .option, allowed: all)
        #expect(onFile?.destination.path == box.url("A").path && onFile?.row == -1 && onFile?.kind == .copy)
        #expect(app.left.dropPlan(for: [fresh], row: -1, modifiers: [], allowed: all)?.row == -1)
        // Onto [..]: into the folder above.
        #expect(
            app.left.dropPlan(for: [fresh], row: 0, modifiers: [], allowed: all)?.destination.path == box.root.path)
        // A panel's own items dropped on its background change nothing, unless copied.
        let own = [box.url("A/one.txt")]
        #expect(app.left.dropPlan(for: own, row: -1, modifiers: [], allowed: all) == nil)
        #expect(app.left.dropPlan(for: own, row: -1, modifiers: .option, allowed: all)?.kind == .copy)
        #expect(app.left.dropPlan(for: own, row: 1, modifiers: [], allowed: all)?.kind == .move)
        #expect(app.left.dropPlan(for: [box.url("A/docs")], row: 1, modifiers: [], allowed: all) == nil)
        #expect(app.left.dropPlan(for: [], row: 1, modifiers: [], allowed: all) == nil)
        // Between file systems it is a copy; a file system that cannot be written takes nothing.
        #expect(
            app.left.dropPlan(for: [memory.url("/M/remote.txt")], row: -1, modifiers: [], allowed: all)?.kind == .copy)
        app.right.show(memory.url("/M"))
        await settle(app)
        #expect(app.right.dropPlan(for: own, row: -1, modifiers: [], allowed: all)?.kind == .copy)
        memory.capabilities = []
        #expect(app.right.dropPlan(for: own, row: -1, modifiers: [], allowed: all) == nil)
    }

    @Test func aDropIsCarriedOutByTheFileTransferService() async throws {
        let app = await start()
        defer { app.stop() }
        let all: NSDragOperation = [.copy, .move, .generic]
        // Moved within the volume, after the question.
        let move = try #require(app.left.dropPlan(for: [box.url("B/fresh.txt")], row: 1, modifiers: [], allowed: all))
        ui.choiceAnswers = [1]
        app.left.carryOut(move)
        await settle(app)
        #expect(ui.log == ["choose: Move 1 item to / \(box.url("A/docs").path)"] && box.exists("B/fresh.txt"))
        ui.choiceAnswers = [0]
        app.left.carryOut(move)
        #expect(app.kernel.jobs.isBusy)
        // While the job runs, nothing else is taken.
        #expect(
            app.left.dropPlan(for: [box.url("B/fresh.txt")], row: 1, modifiers: [], allowed: all) == nil
                && app.left.draggedItems(fromRow: 2).isEmpty)
        await settle(app)
        #expect(box.read("A/docs/fresh.txt") == "fresh" && !box.exists("B/fresh.txt") && app.names(app.right).isEmpty)

        // Without the question; from another file system; and a copy next to the original.
        settings.set(false, forKey: PanelSettings.confirmsDropsKey)
        app.shell.panelCoordinator.applySettings()
        let copy = try #require(
            app.left.dropPlan(for: [memory.url("/M/remote.txt")], row: -1, modifiers: [], allowed: all))
        app.left.carryOut(copy)
        await settle(app)
        #expect(
            box.read("A/remote.txt") == "far" && memory.exists("/M/remote.txt")
                && app.names(app.left).contains("remote.txt"))
        let duplicate = try #require(
            app.left.dropPlan(for: [box.url("A/one.txt")], row: -1, modifiers: .option, allowed: all))
        app.left.carryOut(duplicate)
        await settle(app)
        #expect(box.read("A/one (2).txt") == "new" && box.exists("A/one.txt") && ui.log.count == 2)
    }

    // MARK: Colours and options

    @Test func namesAreColouredByMarkAndFileType() async throws {
        try box.file("A/.secret")
        let app = await start()
        defer { app.stop() }
        app.commands.perform(.showHidden)
        await settle(app)
        let model = app.left.model
        func color(_ name: String, selected: Bool = false) -> NSColor {
            app.left.nameColor(for: model.items.first { $0.name == name }, selected: selected)
        }
        #expect(
            color("one.txt") == .labelColor && color(".secret") == .secondaryLabelColor
                && color("one.txt", selected: true) == .systemRed)
        #expect(!app.commands.isChecked("cm_SwitchColorsByFileType"))
        // The list is edited as text; an entry that cannot be read is shown again.
        ui.formAnswers = [
            .values(["rules": .text("*.txt = nocolour"), "enabled": .flag(true)]),
            .values(["rules": .text("one.* = blue\n*.txt .* = #00FF00\n-docs = red"), "enabled": .flag(true)])
        ]
        app.commands.perform("afm_DefineColorsByFileType")
        #expect(ui.log.filter { $0.hasPrefix("inform") } == ["inform: This entry cannot be read:"])
        #expect(app.commands.isChecked("cm_SwitchColorsByFileType"))
        #expect(
            color("one.txt") == .systemBlue && color("two.txt") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        #expect(color(".secret") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) && color("docs") == .labelColor)
        // The mark colour wins; the switch turns the colours off without losing the list.
        #expect(color("one.txt", selected: true) == .systemRed)
        app.commands.perform("cm_SwitchColorsByFileType")
        #expect(
            color("one.txt") == .labelColor
                && settings.text(PanelSettings.colorRulesKey, default: "").hasPrefix("one.* = blue;;"))
        // The options page of the lists is there, next to the plugin's.
        #expect(
            app.kernel.preferences.pages.map(\.title).contains("File Panels")
                && app.kernel.preferences.pages.map(\.title).contains("Display"))
        settings.set(4, forKey: PanelSettings.thumbnailSizeKey)
        app.kernel.preferences.pages.first { $0.title == "File Panels" }?.onChange()
        #expect(app.left.settings.thumbnailSide == 256 && app.right.settings.thumbnailSide == 256)
    }

    @Test func aLargeFolderStaysFastInEveryView() async {
        for index in 0..<40_000 { memory.addFile(String(format: "/big/file-%05d.dat", index)) }
        let app = await start()
        defer { app.stop() }
        app.left.show(memory.url("/big"))
        await settle(app)
        app.layOut()
        #expect(app.left.model.items.count == 40_000)
        for (command, flow) in [(CommandID.viewBrief, GridGeometry.Flow.columns), (.viewThumbnails, .rows)] {
            // The main thread's own time, which a busy machine does not stretch.
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            app.commands.perform(command)
            draw(app.left.gridView)
            app.left.model.moveCursor(to: 39_000)
            draw(app.left.gridView)
            app.left.model.toggleSelection(row: 39_000)
            #expect(
                Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e9 < 1.5
                    && app.left.gridView.geometry.flow == flow)
            #expect(app.left.gridView.geometry.count == 40_001 && app.left.gridView.visibleRows.contains(39_000))
            #expect(app.left.gridView.visibleRows.count < 2_000)
        }
    }
}
