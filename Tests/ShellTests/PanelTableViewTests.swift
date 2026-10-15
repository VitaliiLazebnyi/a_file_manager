import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The table of the Full view by itself: keys, clicks that mark, the context menu, Select All,
/// the menu entries it offers and drags that leave or end.
@MainActor
@Suite(.serialized)
internal struct PanelTableViewTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the plugins a file manager cannot do without, laid out.
    private func start() async -> PanelProgram.Running {
        let app = await program.start(
            plugins: CorePlugins.make(pasteboard: program.scratch.pasteboard),
            fileSystems: []
        )
        app.layOut()
        return app
    }

    /// A mouse event over row `row` of the table.
    private func mouse(_ type: NSEvent.EventType, onRow row: Int, of table: NSTableView, flags: NSEvent.ModifierFlags)
        throws -> NSEvent
    {
        try PanelDropHelpers.mouse(
            type,
            at: PanelDropHelpers.point(ofRow: row, in: table),
            clicks: 1,
            flags: flags,
            in: table.window
        )
    }

    /// Keys the panel takes go to it, the others to the table; Cmd+click and Shift+click mark;
    /// Select All marks everything; the context menu is the row's.
    @Test
    internal func keysClicksAndTheMenuOfTheTable() async throws {
        let app = await start()
        defer { app.stop() }
        let table = app.left.tableView
        let after = PanelKeyRecorder()
        let chain = table.nextResponder
        table.nextResponder = after
        defer { table.nextResponder = chain }
        table.keyDown(with: PanelProgram.key(125, String(UnicodeScalar(UInt8(0x1F))), []))
        table.keyDown(with: PanelProgram.key(105, String(UnicodeScalar(UInt8(0x10))), .function))
        #expect(after.keys.count + after.commands.count > 0)
        table.keyDown(with: PanelProgram.key(17, "t", []))
        #expect(app.left.model.cursorItem?.name == "two.txt")
        table.mouseDown(with: try mouse(.leftMouseDown, onRow: 2, of: table, flags: .command))
        table.mouseDown(with: try mouse(.leftMouseDown, onRow: 3, of: table, flags: .shift))
        #expect(app.left.model.selection == ["one.txt", "two.txt"] && table.window?.firstResponder === table)
        app.commands.perform(.unselectAll, .nothing)
        table.selectAll(nil)
        #expect(app.left.model.selection == ["docs", "one.txt", "two.txt"])
        let menu = table.menu(for: try mouse(.rightMouseDown, onRow: 1, of: table, flags: []))
        #expect(menu?.items.contains { $0.title == "Open" } == true && app.left.model.cursor == 1)
        #expect(table.validateUserInterfaceItem(MenuBuilder.item(Command(.open, "Open"), keys: nil)))
        let other = NSMenuItem(title: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "")
        #expect(table.validateUserInterfaceItem(other) == NSTableView().validateUserInterfaceItem(other))
    }

    /// A drag that leaves the table or ends forgets what was read of it.
    @Test
    internal func aDragThatLeavesOrEndsIsForgotten() async {
        let app = await start()
        defer { app.stop() }
        let table = app.left.tableView
        let board = PanelDropHelpers.pasteboard([program.box.url("B/fresh.txt")])
        defer { board.releaseGlobally() }
        let info = PanelDraggingInfo(
            sequence: 7_401,
            pasteboard: board,
            location: PanelDropHelpers.point(ofRow: 1, in: table),
            allowed: PanelDraggingInfo.anything
        )
        _ = PanelDrop.session(for: info)
        // (A drag of this program that another test left under way would keep the session.)
        PanelDrop.endDrag()
        table.draggingExited(info)
        #expect(PanelDrop.session == nil)
        _ = PanelDrop.session(for: info)
        table.draggingEnded(info)
        #expect(PanelDrop.session == nil)
    }

    /// A table that belongs to no panel (its panel has gone) leaves keys and the menu to
    /// AppKit and offers no command.
    @Test
    internal func aTableOfNoPanelLeavesEverythingToAppKit() {
        let table = FileTableView()
        let after = PanelKeyRecorder()
        table.nextResponder = after
        table.keyDown(with: PanelProgram.key(0, "a", []))
        table.selectAll(nil)
        #expect(table.menu(for: PanelProgram.key(0, "a", [])) == nil)
        #expect(!table.validateUserInterfaceItem(MenuBuilder.item(Command(.open, "Open"), keys: nil)))
    }
}
