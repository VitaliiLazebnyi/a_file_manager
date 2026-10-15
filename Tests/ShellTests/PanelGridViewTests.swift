import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The grid of the Brief and Thumbnails views by itself: what it draws, and what the mouse and
/// the keyboard do in it.
@MainActor
@Suite(.serialized)
internal struct PanelGridViewTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the plugins a file manager cannot do without, in the Brief view.
    private func startInBrief() async -> PanelProgram.Running {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        return app
    }

    /// Esc in the rename box: the box goes.
    private func cancelRenaming(_ panel: PanelViewController) {
        if let field = panel.renameField {
            _ = panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
    }

    /// A mouse event over cell `row` of the grid.
    private func mouse(
        _ type: NSEvent.EventType,
        onRow row: Int,
        of grid: FileGridView,
        clicks: Int,
        flags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try PanelDropHelpers.mouse(
            type,
            at: PanelDropHelpers.point(ofRow: row, in: grid),
            clicks: clicks,
            flags: flags,
            in: grid.window
        )
    }

    /// A grid that belongs to no panel (its panel has gone) draws nothing, takes no clicks, keys
    /// or drops, and offers no menu.
    @Test
    internal func aGridOfNoPanelDoesNothing() throws {
        let grid = FileGridView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        NSView(frame: grid.frame).addSubview(grid)
        grid.reload(flow: .rows)
        PanelDropHelpers.draw(grid)
        let click = try PanelDropHelpers.mouse(.leftMouseDown, at: .zero, clicks: 1, flags: [], in: nil)
        grid.mouseDown(with: click)
        grid.mouseDragged(with: click)
        grid.mouseUp(with: click)
        grid.selectAll(nil)
        grid.keyDown(with: PanelProgram.key(0, "a", []))
        let board = PanelDropHelpers.pasteboard([URL(fileURLWithPath: "/x/a.txt")])
        defer { board.releaseGlobally() }
        let info = PanelDraggingInfo(
            sequence: 7_301,
            pasteboard: board,
            location: .zero,
            allowed: PanelDraggingInfo.anything
        )
        #expect(grid.geometry.cellCount == 0 && grid.draggingUpdated(info).isEmpty && !grid.performDragOperation(info))
        #expect(grid.menu(for: click) == nil && grid.becomeFirstResponder())
        let command = MenuBuilder.item(Command(.open, "Open"), keys: nil)
        #expect(!grid.validateUserInterfaceItem(command))
        #expect(grid.validateUserInterfaceItem(NSMenuItem(title: "Other", action: nil, keyEquivalent: "")))
        PanelDrop.endSession(nil)
    }

    /// A grid outside a scroll view and a window is laid out for its own size and draws the
    /// pictures of its files at twice the points.
    @Test
    internal func aGridOutsideAScrollViewIsLaidOutForItsOwnSize() async {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = FileGridView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        grid.panel = app.left
        app.left.settings.thumbnailSide = 64
        grid.reload(flow: .rows)
        #expect(grid.geometry.viewport == NSSize(width: 400, height: 300) && grid.geometry.cell.width == 84)
        PanelDropHelpers.draw(grid)
        #expect(grid.row(at: NSPoint(x: -10, y: -10)) == -1 && grid.row(at: NSPoint(x: 5, y: 5)) == 0)
    }

    /// Rows that are not in the list are neither scrolled to nor drawn again.
    @Test
    internal func rowsOutsideTheListAreLeftAlone() async {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = app.left.gridView
        let shown = grid.visibleRect
        for row in [-1, grid.geometry.cellCount] {
            grid.scrollRowToVisible(row)
            grid.redraw(row: row)
        }
        #expect(grid.visibleRect == shown)
    }

    /// The grid draws the frame of a drop on the list and on a row, leaves out the name under
    /// the rename box, and draws a folder of a file system that tells nothing of its volume.
    @Test
    internal func theGridDrawsDropsTheRenameBoxAndUnknownVolumes() async {
        let script = ScriptedFileSystem()
        script.inner.addDirectory("/s")
        script.batches = [[script.item(named: "a.txt", in: "/s"), script.item(named: "b.txt", in: "/s")]]
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: [script]
        )
        defer { app.stop() }
        app.commands.perform(.viewBrief, .nothing)
        app.layOut()
        let grid = app.left.gridView
        grid.dropRow = -1
        PanelDropHelpers.draw(grid)
        grid.dropRow = 1
        PanelDropHelpers.draw(grid)
        grid.dropRow = nil
        // Only part of the list: the cells of its column that lie outside are skipped.
        if let bitmap = grid.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 10, height: 10)) {
            grid.cacheDisplay(in: NSRect(x: 0, y: 0, width: 10, height: 10), to: bitmap)
        }
        app.cursor(app.left, on: "one.txt")
        app.left.beginRename()
        PanelDropHelpers.draw(grid)
        #expect(app.left.isRenaming && app.left.renamingRow == app.left.model.cursor)
        cancelRenaming(app.left)
        app.left.show(script.url("/s"))
        await program.settle(app)
        #expect(app.left.model.volume == nil && app.names(app.left) == ["a.txt", "b.txt"])
        PanelDropHelpers.draw(grid)
    }

    /// A click moves the cursor, Cmd+click marks, a double click opens; a second click on the
    /// cursor's item, once the double-click time has passed, renames it; the context menu is the
    /// row's.
    @Test
    internal func clicksInTheGrid() async throws {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = app.left.gridView
        grid.mouseDown(with: try mouse(.leftMouseDown, onRow: 2, of: grid, clicks: 1, flags: []))
        grid.mouseUp(with: try mouse(.leftMouseUp, onRow: 2, of: grid, clicks: 1, flags: []))
        #expect(app.left.model.cursorItem?.name == "one.txt" && grid.window?.firstResponder === grid)
        grid.mouseDown(with: try mouse(.leftMouseDown, onRow: 3, of: grid, clicks: 1, flags: .command))
        #expect(app.left.model.selection == ["two.txt"] && app.left.model.cursor == 3)
        // A second, unhurried click on the cursor's item.
        app.left.isActive = true
        grid.mouseDown(with: try mouse(.leftMouseDown, onRow: 3, of: grid, clicks: 1, flags: []))
        grid.mouseUp(with: try mouse(.leftMouseUp, onRow: 3, of: grid, clicks: 1, flags: []))
        #expect(await PanelWait.until { app.left.isRenaming })
        cancelRenaming(app.left)
        let menu = grid.menu(for: try mouse(.rightMouseDown, onRow: 2, of: grid, clicks: 1, flags: []))
        #expect(menu?.items.contains { $0.title == "Open" } == true && app.left.model.cursor == 2)
        #expect(grid.validateUserInterfaceItem(MenuBuilder.item(Command(.open, "Open"), keys: nil)))
        grid.mouseDown(with: try mouse(.leftMouseDown, onRow: 1, of: grid, clicks: 2, flags: []))
        await program.settle(app)
        #expect(app.left.model.directory.lastPathComponent == "docs")
    }

    /// Keys the panel does not take go on to the grid's own handling; Select All marks everything;
    /// the grid follows its scroll view only while it is shown.
    @Test
    internal func keysSelectAllAndScrollingInTheGrid() async throws {
        let app = await startInBrief()
        defer { app.stop() }
        let grid = app.left.gridView
        grid.keyDown(with: PanelProgram.key(105, String(UnicodeScalar(UInt8(0x10))), .function))
        grid.selectAll(nil)
        #expect(app.left.model.selection == ["docs", "one.txt", "two.txt"])
        let clip = try #require(grid.superview as? NSClipView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        app.commands.perform(.viewFull, .nothing)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: clip)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        #expect(!app.left.showsGrid)
    }

    /// In the Thumbnails view the rename box lies over the name below the picture.
    @Test
    internal func theRenameBoxOfAThumbnailLiesOverItsName() async {
        let app = await startInBrief()
        defer { app.stop() }
        app.commands.perform(.viewThumbnails, .nothing)
        app.layOut()
        app.cursor(app.left, on: "one.txt")
        app.left.beginRename()
        let frame = app.left.gridView.nameFrame(ofRow: app.left.model.cursor)
        #expect(
            app.left.isRenaming && frame.height == 20 && frame.maxY == app.left.gridView.geometry.frame(of: 2).maxY - 16
        )
        cancelRenaming(app.left)
    }

    /// Hidden files are drawn dimmed in the Brief and the Thumbnails view.
    @Test
    internal func hiddenFilesAreDrawnInBothViews() async throws {
        try program.box.file("A/.secret")
        let app = await startInBrief()
        defer { app.stop() }
        app.commands.perform(.showHidden, .nothing)
        await program.settle(app)
        #expect(app.left.model.items.contains { $0.name == ".secret" && $0.isHidden })
        PanelDropHelpers.draw(app.left.gridView)
        app.commands.perform(.viewThumbnails, .nothing)
        app.layOut()
        PanelDropHelpers.draw(app.left.gridView)
        #expect(app.left.gridView.geometry.cellCount == 5)
    }
}
