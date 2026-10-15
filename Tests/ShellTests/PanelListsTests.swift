import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The lists of a panel in the states the program meets now and then: not on screen yet, the
/// table's own selection, columns the panel does not know, keys meant for another view, pictures
/// that arrive for another view, a rename while the view changes.
@MainActor
@Suite(.serialized)
internal struct PanelListsTests {
    private let program: PanelProgram

    /// The program's folders: `A` with `docs`, `one.txt`, `two.txt`; `B` with `fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
        program.memory.addFile("/m/y.txt")
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

    /// A panel that is not on screen yet draws nothing, writes no status line and notes no
    /// widths.
    @Test
    internal func aPanelNotOnScreenYetDrawsNothing() {
        let kernel = Kernel(productName: "Test", settings: MemorySettings(), interaction: ScriptedInteraction())
        let panel = PanelViewController(tabs: PanelTabs(PanelModel(directory: program.box.url("A"))), kernel: kernel)
        panel.redraw()
        panel.updateStatus()
        panel.rememberColumnWidths()
        #expect(!panel.isViewLoaded && panel.columnWidths.isEmpty)
    }

    /// The table's own selection is the cursor; a column the panel does not know shows nothing.
    @Test
    internal func theTablesSelectionIsTheCursor() async {
        let app = await start()
        defer { app.stop() }
        let table = app.left.tableView
        table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(app.left.model.cursor == 2)
        #expect(app.left.tableView(table, viewFor: nil, row: 1) == nil)
        let stranger = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("stranger"))
        #expect(
            app.left.tableView(table, viewFor: stranger, row: 1) == nil && app.left.contentColumn(of: stranger) == nil
        )
    }

    /// Arrow keys of the grid do nothing in the table; finding by typing works in a folder without
    /// a `[..]` row too; the pictures and the column values that arrive for another view are left
    /// alone.
    @Test
    internal func whatBelongsToAnotherViewIsLeftAlone() async {
        let app = await start()
        defer { app.stop() }
        app.left.moveCursor(.downArrow)
        #expect(app.left.model.cursor == 0)
        app.left.thumbnailArrived(for: "one.txt")
        app.right.show(program.memory.url("/"))
        await program.settle(app)
        #expect(!app.right.model.hasParentRow)
        app.right.moveCursor(toNameStartingWith: "m")
        #expect(await PanelWait.until { app.right.model.cursorItem?.name == "m" })
        app.commands.perform(.viewBrief, .nothing)
        app.left.columnValuesArrived(for: ["one.txt"])
        app.commands.perform(.viewThumbnails, .nothing)
        app.layOut()
        app.left.thumbnailArrived(for: "two.txt")
        app.left.thumbnailArrived(for: "nothing.txt")
        #expect(app.left.viewMode == .thumbnails)
    }
}
