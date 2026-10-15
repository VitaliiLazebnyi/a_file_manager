import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The three views of a panel through the real program (spec 03 › View types): switched and
/// remembered, the cursor, marks and keys of the Brief view, the pictures of the Thumbnails view,
/// and a large folder in every view.
@MainActor
@Suite(.serialized)
internal struct PanelViewsTests {
    private let program: PanelProgram

    /// The program's folders, with `B/fresh.txt` and a file in the memory file system.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        program.memory.addFile("/M/remote.txt", "far")
    }

    /// Starts the program with the plugins a file manager cannot do without.
    private func start() async -> PanelProgram.Running {
        await program.start(plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard), fileSystems: [])
    }

    /// Has a view draw itself into a bitmap, as it would on screen.
    private func draw(_ view: NSView) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) else {
            return
        }
        view.cacheDisplay(in: view.visibleRect, to: bitmap)
    }

    /// The view of each panel is switched with its keys and comes back with the next start.
    @Test
    internal func theViewOfEachPanelIsSwitchedAndRemembered() async {
        let app = await start()
        #expect(app.left.viewMode == .full && !app.left.showsGrid && app.left.tableView.enclosingScrollView?.isHidden == false)
        #expect(app.kernel.keyClashes.isEmpty)
        // Ctrl+F1 (key code 122).
        #expect(program.press(app, 122, .control) && app.left.viewMode == .brief && app.commands.isChecked(.viewBrief))
        #expect(app.left.showsGrid && app.left.tableView.enclosingScrollView?.isHidden == true)
        #expect(app.left.gridView.enclosingScrollView?.isHidden == false)
        #expect(app.left.gridView.geometry.flow == .columns && app.left.gridView.geometry.count == 4)
        #expect(app.right.viewMode == .full && program.settings.value(PanelViewState.self, forKey: "left.view")?.mode == 1)
        #expect(program.press(app, 122, [.control, .shift]) && app.left.viewMode == .thumbnails)
        #expect(app.left.gridView.geometry.flow == .rows && app.left.gridView.geometry.cell == CGSize(width: 116, height: 136))
        app.stop()

        let again = await start()
        defer { again.stop() }
        #expect(again.left.viewMode == .thumbnails && again.right.viewMode == .full && again.left.gridView.geometry.count == 4)
        #expect(again.commands.isChecked(.viewThumbnails))
        // Ctrl+F2 (key code 120) brings the table back, with the list in it.
        #expect(program.press(again, 120, .control) && again.left.viewMode == .full && again.left.tableView.numberOfRows == 4)
        #expect(again.left.tableView.selectedRow == again.left.model.cursor)
    }

    /// In the Brief view the arrows step through the grid, the other keys are those of the Full
    /// view, letters find a file, clicks mark, and the status line describes the cursor's item.
    @Test
    internal func cursorMarkingAndKeysWorkInTheBriefView() async throws {
        for index in 0..<90 {
            try program.box.file(String(format: "A/many/f%02d.txt", index))
        }
        let app = await start()
        defer { app.stop() }
        app.left.show(program.box.url("A/many"))
        await program.settle(app)
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        let grid = app.left.gridView
        let perColumn = grid.geometry.perLine
        #expect(grid.geometry.count == 91 && perColumn > 5 && perColumn < 91 && grid.frame.width >= grid.geometry.cell.width * 2)
        // → and ← step a column; ↓ and ↑, which are bound to nothing, a row.
        #expect(program.press(app, 124, []) && app.left.model.cursor == perColumn)
        grid.keyDown(with: PanelProgram.key(125, "", []))
        #expect(app.left.model.cursor == perColumn + 1)
        #expect(program.press(app, 123, []) && app.left.model.cursor == 1)
        grid.keyDown(with: PanelProgram.key(126, "", []))
        #expect(app.left.model.cursorIsOnParentRow)
        // The other keys are the ones of the Full view: End, Home, Page Down, Insert, Shift+↓, Space.
        #expect(program.press(app, 119, []) && app.left.model.cursor == 90 && program.press(app, 115, []) && app.left.model.cursor == 0)
        #expect(program.press(app, 121, []) && app.left.model.cursor == min(90, grid.geometry.pageSize))
        app.cursor(app.left, on: "f03.txt")
        #expect(program.press(app, 114, []) && program.press(app, 125, .shift) && app.left.model.selection == ["f03.txt", "f04.txt"])
        #expect(program.press(app, 49, []) && app.left.model.selection == ["f03.txt", "f04.txt", "f05.txt"])
        // Letters find a file by typing.
        grid.keyDown(with: PanelProgram.key(3, "f", []))
        grid.keyDown(with: PanelProgram.key(18, "1", []))
        grid.keyDown(with: PanelProgram.key(23, "5", []))
        #expect(app.left.model.cursorItem?.name == "f15.txt")
        // Clicks: Cmd toggles, Shift marks the range from the cursor.
        #expect(app.left.handleClick(row: 20, modifiers: .command) && app.left.model.selection.contains("f19.txt"))
        #expect(app.left.model.cursor == 20)
        #expect(app.left.handleClick(row: 23, modifiers: .shift))
        #expect(app.left.model.selection.isSuperset(of: ["f20.txt", "f21.txt", "f22.txt"]))
        app.left.clicked(row: 2)
        #expect(app.left.model.cursorItem?.name == "f01.txt")
        // The status line describes the item under the cursor when nothing is marked.
        app.commands.perform(.unselectAll, .nothing)
        #expect(app.left.statusLineText.hasPrefix("f01  txt  1  "))
        app.commands.perform(.selectAll, .nothing)
        #expect(app.left.statusLineText == "0 k / 0 k in 90 / 90 file(s)")
        // The in-place editor and the context menu are the same as in the Full view.
        app.left.beginRename()
        #expect(app.left.isRenaming)
        let menu = app.left.contextMenu(forRow: 5)?.items.map(\.title) ?? []
        #expect(menu.contains("Open") && app.left.model.cursor == 5)
        #expect(app.left.contextMenu(forRow: -1)?.items.contains { $0.title == "Open" } == false)
        // Enter opens, as everywhere.
        app.left.model.moveCursor(to: 0)
        #expect(program.press(app, 36, []))
        await program.settle(app)
        #expect(app.left.model.directory.lastPathComponent == "A" && app.left.gridView.geometry.count == 5)
    }

    /// Pictures are made in the background for local files only, and given up with the folder.
    @Test
    internal func thumbnailsAreMadeInTheBackgroundForLocalFilesOnly() async {
        let app = await start()
        defer { app.stop() }
        let source = PanelScriptedThumbnails()
        app.left.thumbnails.source = source
        app.commands.perform(.viewThumbnails, .nothing)
        app.layOut()
        #expect(app.left.gridView.geometry.flow == .rows && app.left.gridView.geometry.perLine > 1)
        draw(app.left.gridView)
        // Files get pictures; the folder and `[..]` show icons.
        #expect(Set(source.requested) == ["one.txt", "two.txt"] && app.left.thumbnails.running.count == 2)
        source.answer("one.txt", with: NSImage(size: NSSize(width: 40, height: 30)))
        #expect(await PanelWait.until { app.left.thumbnails.running.count == 1 })
        draw(app.left.gridView)
        #expect(source.requested.count == 2)
        // Leaving the folder gives up what is still being made.
        app.left.show(program.memory.url("/M"))
        await program.settle(app)
        #expect(source.cancelled == ["two.txt"] && app.left.thumbnails.running.isEmpty)
        // Items of other file systems show the icon of their type and ask for nothing.
        draw(app.left.gridView)
        #expect(source.requested.count == 2 && app.left.gridView.geometry.count == 2)
    }

    /// A folder of 40,000 entries costs the main thread little in every view.
    @Test
    internal func aLargeFolderStaysFastInEveryView() async {
        for index in 0..<40_000 {
            program.memory.addFile(String(format: "/big/file-%05d.dat", index))
        }
        let app = await start()
        defer { app.stop() }
        app.left.show(program.memory.url("/big"))
        await program.settle(app)
        app.layOut()
        #expect(app.left.model.items.count == 40_000)
        for (command, flow) in [(CommandID.viewBrief, GridGeometry.Flow.columns), (.viewThumbnails, .rows)] {
            // The main thread's own time, which a busy machine does not stretch.
            let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            app.commands.perform(command, .nothing)
            draw(app.left.gridView)
            app.left.model.moveCursor(to: 39_000)
            draw(app.left.gridView)
            app.left.model.toggleSelection(row: 39_000)
            #expect(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e9 < 1.5)
            #expect(app.left.gridView.geometry.flow == flow && app.left.gridView.geometry.count == 40_001)
            #expect(app.left.gridView.visibleRows.contains(39_000) && app.left.gridView.visibleRows.count < 2_000)
        }
    }
}
