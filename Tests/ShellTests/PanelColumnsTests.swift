import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The columns of the Full view through the real program (spec 03 › Custom columns): plugin
/// columns filled in from the background, the header's menu, and widths that are remembered.
@MainActor
@Suite(.serialized)
internal struct PanelColumnsTests {
    private let program: PanelProgram
    private let probe = PanelProbe()

    /// The program's folders, with `B/fresh.txt`.
    internal init() throws {
        program = try PanelProgram(rightFile: "fresh.txt", contents: "fresh")
    }

    /// Starts the program with the core plugins and a plugin that offers two columns.
    private func start() async -> PanelProgram.Running {
        let plugins = CorePlugins.make(pasteboard: program.scratch.pasteboard) + [PanelColumnsPlugin(probe: probe)]
        return await program.start(plugins: plugins, fileSystems: [])
    }

    /// The text of the cell of `column` in `row` of the left panel.
    private func text(_ app: PanelProgram.Running, _ column: Int, _ row: Int) -> String? {
        let table = app.left.tableView
        let cell = app.left.tableView(table, viewFor: table.tableColumns[column], row: row) as? NSTableCellView
        return cell?.textField?.stringValue
    }

    /// A row asks for its value and does not wait for it; the value arrives from the background;
    /// the header's menu shows and hides the columns; columns and widths come back with the next
    /// start, for this panel only; the Custom Columns dialog sets the same list.
    @Test
    internal func pluginColumnsAreFilledInFromTheBackgroundAndRemembered() async {
        let app = await start()
        #expect(app.left.tableView.tableColumns.count == 5)
        app.left.extraColumns = ["upper", "unknown", "upper"]
        let table = app.left.tableView
        #expect(
            table.tableColumns.map(\.title) == ["Name", "Ext", "Size", "Date", "Attr", "Upper"]
                && table.tableColumns[5].width == 90
        )
        // Drawing a row asks for its value and does not wait for it: the cells are empty, and
        // no value is ever worked out on the main thread (checked below).
        #expect(text(app, 5, 2)?.isEmpty == true && text(app, 5, 0)?.isEmpty == true)
        #expect(await PanelWait.until { app.left.columnValues.working.isEmpty && !app.left.columnValues.hasWaiting })
        #expect(await PanelWait.until { text(app, 5, 2) == "ONE.TXT" })
        #expect(text(app, 5, 0)?.isEmpty == true && (1...3).contains(probe.callCount) && probe.callsOnMain == 0)
        #expect(text(app, 0, 2) == "one" && text(app, 2, 2) == "3")
        // The header's menu offers the views and the columns.
        app.left.fillHeaderMenu()
        let items = app.left.headerMenu.items
        #expect(items.map(\.title) == ["Brief", "Full", "Thumbnail View", "", "Upper", "Length", "", "Custom Columns…"])
        #expect(items[1].state == .on && items[4].state == .on && items[5].state == .off)
        app.left.extraColumnChosen(items[5])
        app.left.extraColumnChosen(NSMenuItem())
        #expect(app.left.extraColumns == ["upper", "unknown", "upper", "length"] && table.tableColumns.count == 7)
        #expect(await PanelWait.until { text(app, 6, 2) == "7" })
        app.left.toggleExtraColumn("upper")
        #expect(table.tableColumns.map(\.title).suffix(2) == ["Attr", "Length"])
        // Columns and widths come back with the next start, for this panel only.
        table.tableColumns[2].width = 137
        table.tableColumns[5].width = 61
        app.shell.saveState()
        let saved = program.settings.value(PanelViewState.self, forKey: "left.view")
        #expect(saved?.extraColumns == ["unknown", "length"] && saved?.columnWidths["size"] == 137)
        #expect(saved?.columnWidths["+length"] == 61)
        app.stop()
        let again = await start()
        defer { again.stop() }
        #expect(again.left.extraColumns == ["unknown", "length"] && again.right.extraColumns.isEmpty)
        #expect(
            again.left.tableView.tableColumns.map(\.title).last == "Length"
                && again.right.tableView.tableColumns.count == 5
        )
        #expect(again.left.tableView.tableColumns[2].width == 137 && again.left.tableView.tableColumns[5].width == 61)
        // The Custom Columns dialog of the Show menu sets the same list.
        program.interaction.formAnswers = [.values(["upper": .flag(true), "length": .flag(false)])]
        again.commands.perform("cm_CustomColumnConfig", .nothing)
        #expect(again.left.extraColumns == ["unknown", "upper"])
    }

    /// A click on a header sorts by its column, and once more reverses the order; Attr does not
    /// sort.
    ///
    /// The header of the grid offers the same menu.
    @Test
    internal func aClickOnAHeaderSortsByItsColumn() async {
        let app = await start()
        defer { app.stop() }
        let table = app.left.tableView
        app.left.tableView(table, didClick: table.tableColumns[2])
        #expect(app.left.model.wantedSort.key == .size)
        let descending = app.left.model.wantedSort.descending
        app.left.tableView(table, didClick: table.tableColumns[2])
        #expect(app.left.model.wantedSort.key == .size && app.left.model.wantedSort.descending != descending)
        app.left.tableView(table, didClick: table.tableColumns[4])
        #expect(app.left.model.wantedSort.key == .size)
        app.left.sortHeader.onClick?(.name)
        #expect(app.left.model.wantedSort.key == .name && app.left.sortHeader.order.key == .name)
        #expect(app.left.sortHeader.menuProvider?() === app.left.headerMenu && !app.left.headerMenu.items.isEmpty)
        // The table keeps the widths as they are dragged.
        table.tableColumns[1].width = 77
        app.left.tableViewColumnDidResize(Notification(name: NSTableView.columnDidResizeNotification))
        #expect(app.left.columnWidths["ext"] == 77)
    }
}
