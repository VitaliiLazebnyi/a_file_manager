import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The keys and clicks of the file lists in the whole program: the cursor, marking, sorting.
@MainActor
@Suite(.serialized)
internal struct AppPanelKeyTests {
    /// The program's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the program's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.programFiles)
    }

    /// The arrows, Home, End and Page Up move the cursor; Shift and Insert mark; Tab changes panels.
    @Test
    internal func cursorAndMarkingKeys() async throws {
        let app = await fixture.startProgram()
        defer { app.stop() }
        // Laid out as if it were shown: a page is as many rows as the list has room for.
        app.window.window?.layoutIfNeeded()
        #expect(try app.press(124, []) && app.left.model.cursorItem?.name == "two.txt")  // →
        #expect(try app.press(123, []) && app.left.model.cursorItem?.name == "docs")  // ←
        #expect(try app.press(115, []) && app.left.model.cursorIsOnParentRow)  // Home
        #expect(try app.press(119, []) && app.left.model.cursorItem?.name == "two.txt")  // End
        #expect(try app.press(116, []) && app.left.model.cursor == 0)  // Page Up
        #expect(app.left.tableView.selectedRow == 0)
        #expect(try app.press(125, .shift) && app.left.model.selection.isEmpty)  // Shift+↓ on [..]
        #expect(
            try app.press(125, .shift) && app.left.model.selection == ["docs"]
                && app.left.model.cursorItem?.name == "one.txt"
        )
        #expect(try app.press(126, .shift) && app.left.model.selection == ["docs", "one.txt"])  // Shift+↑
        #expect(try app.press(114, []) && app.left.model.selection == ["one.txt"])  // Insert on docs
        // A letter is bound to nothing: it goes on to the table, which finds files by typing.
        #expect(try !app.press(0, []))
        // Tab makes the other panel the source.
        #expect(try app.press(48, []) && app.kernel.panels.source === app.right && app.right.isActive)
        #expect(try app.press(48, []) && app.kernel.panels.source === app.left)
    }

    /// Space marks a folder and works out its size in the background.
    @Test
    internal func spaceSelectsAFolderAndCalculatesItsSize() async throws {
        try fixture.box.file("A/docs/deep/big.bin", String(repeating: "x", count: 5_000))
        let app = await fixture.startProgram()
        defer { app.stop() }
        app.cursor(app.left, on: "docs")
        #expect(try app.press(49, []) && app.left.model.selection == ["docs"])
        #expect(await AppWait.until { app.left.model.cursorItem?.computedSize == 5_006 })
        #expect(app.left.model.totals.selectedBytes == 5_006)
    }

    /// A click on a column header sorts that panel by the column, a second click the other way.
    @Test
    internal func aClickOnAColumnHeaderSorts() async {
        let app = await fixture.startProgram()
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
}
