import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The commands only the window provides: the cursor keys, the in-place name editor, the
/// command line's history.
@MainActor
@Suite(.serialized)
internal struct AppShellCommandsTests {
    /// The window's folders and stand-ins.
    private let fixture: AppFixture

    /// A sandbox with the window's files.
    internal init() throws {
        fixture = try AppFixture(files: AppFixture.windowFiles)
    }

    /// Page Up and Page Down move the cursor by the rows the list has room for.
    @Test
    internal func pageKeysMoveByAPage() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        app.window.window?.layoutIfNeeded()
        app.left.model.moveCursor(to: 0)
        let page = app.left.pageSize
        app.commands.perform(.cursorPageDown)
        #expect(app.left.model.cursor == min(page, app.left.model.rowCount - 1))
        app.commands.perform(.cursorPageUp)
        #expect(app.left.model.cursor == 0)
    }

    /// The name editor is offered for an entry under the cursor and opens on it.
    @Test
    internal func theNameEditorOpensOnTheEntryUnderTheCursor() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        app.left.model.moveCursor(to: 0)
        app.cursor(app.left, on: "one.txt")
        #expect(app.commands.isEnabled(.editNameInPlace))
        app.commands.perform(.editNameInPlace)
        #expect(app.left.renamingRow == app.left.model.cursor)
    }

    /// The history command brings back a hidden command line.
    @Test
    internal func theHistoryCommandShowsTheCommandLine() async {
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        app.commands.perform(.showCommandLine)
        #expect(app.line.isHidden)
        app.commands.perform(.commandLineHistory)
        #expect(!app.line.isHidden && !app.line.isHistoryOpen)
    }

    /// In an empty folder ← goes to the only row there is.
    @Test
    internal func theFirstEntryOfAnEmptyFolderIsItsOnlyRow() async throws {
        let empty = try fixture.box.folder("empty")
        let app = await fixture.startWindow(with: WindowTestPlugin())
        defer { app.stop() }
        app.commands.perform(.changeDirectory, .location(empty))
        await app.settle()
        #expect(app.left.model.items.isEmpty)
        app.commands.perform(.cursorToFirstEntry)
        #expect(app.left.model.cursor == 0)
    }
}
