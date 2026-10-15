import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import AFMShell

/// The in-place name editor and finding a file by typing, through the real program (review 2,
/// S012, S019 – S021, S049; spec 07 › In-place rename).
@MainActor
@Suite(.serialized)
internal struct PanelEditingTests {
    private let program: PanelProgram

    /// The program's folders.
    internal init() throws {
        program = try PanelProgram(rightFile: "one.txt", contents: "old")
    }

    /// The editor stays while its item is in the list, follows it to its row, and goes with it.
    @Test
    internal func theNameEditorStaysWhileItsItemIsInTheList() async throws {
        let app = await program.start()
        defer { app.stop() }
        await program.rest(app)
        app.cursor(app.left, on: "one.txt")
        app.left.beginRename()
        app.left.beginRename()
        #expect(app.left.isRenaming && app.left.renamingRow == app.left.model.row(ofName: "one.txt"))
        // A refresh after an operation: the list changes around the item.
        try program.box.file("A/a-first.txt")
        try program.box.file("A/zz-last.txt")
        var read = false
        app.left.reload(focus: nil, quietly: false) { read = true }
        await PanelWait.until { read }
        #expect(app.names(app.left).contains("a-first.txt"))
        #expect(app.left.isRenaming && app.left.renamingRow == app.left.model.row(ofName: "one.txt"))
        // Another order: the editor follows its item.
        let before = app.left.renamingRow
        app.left.model.setSort(ListOrder(key: app.left.model.sort.key, descending: !app.left.model.sort.descending))
        #expect(app.left.isRenaming && app.left.renamingRow == app.left.model.row(ofName: "one.txt"))
        #expect(app.left.renamingRow != before)
        // The item is gone: so is the editor.
        try FileManager.default.removeItem(at: program.box.url("A/one.txt"))
        read = false
        app.left.reload(focus: nil, quietly: false) { read = true }
        await PanelWait.until { read }
        #expect(!app.left.isRenaming && app.left.renamingRow == nil && !app.names(app.left).contains("one.txt"))
    }

    /// Enter in the editor renames through the Rename command; Esc and a click elsewhere take it
    /// away; other keys are the box's own.
    ///
    /// A quiet reload while it is open waits for it.
    @Test
    internal func theEditorRenamesOnEnterAndGoesOnEsc() async throws {
        let app = await program.start()
        defer { app.stop() }
        app.cursor(app.left, on: "two.txt")
        app.left.beginRename()
        let field = try #require(app.left.renameField)
        app.left.reload(focus: nil, quietly: true, completion: nil)
        #expect(app.left.hasPendingReread)
        #expect(!app.left.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(
            !app.left.control(
                NSTextField(),
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )
        )
        #expect(
            app.left.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        )
        #expect(!app.left.isRenaming)
        await program.rest(app)
        app.left.beginRename()
        app.left.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        #expect(!app.left.isRenaming)
        app.left.beginRename()
        let again = try #require(app.left.renameField)
        again.stringValue = "renamed.txt"
        #expect(app.left.control(again, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await program.settle(app)
        #expect(program.box.exists("A/renamed.txt") && !program.box.exists("A/two.txt"))
    }

    /// A second, unhurried click on the cursor's item renames once the double-click time is
    /// over, unless the cursor moved; other clicks do not.
    @Test
    internal func aSecondClickOnTheCursorsItemRenames() async throws {
        let app = await program.start()
        defer { app.stop() }
        app.left.isActive = true
        app.cursor(app.left, on: "one.txt")
        let row = app.left.model.cursor
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        #expect(app.left.isRenameClick(row: row, event: click, wasFocused: true))
        #expect(
            !app.left.isRenameClick(row: row, event: click, wasFocused: false)
                && !app.left.isRenameClick(row: 0, event: click, wasFocused: true)
        )
        app.left.scheduleRename(row: row, after: 0.01)
        #expect(await PanelWait.until { app.left.isRenaming })
        app.left.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        // The cursor moved meanwhile: nothing happens; a click before the time cancels it.
        app.left.scheduleRename(row: row, after: 0.05)
        app.cursor(app.left, on: "two.txt")
        await PanelWait.pause(0.15)
        #expect(!app.left.isRenaming)
        app.left.scheduleRename(row: app.left.model.cursor, after: 0.05)
        app.left.cancelPendingRename()
        await PanelWait.pause(0.15)
        #expect(!app.left.isRenaming)
    }

    /// Typing finds a file in a long list without looking through it on the main thread; only
    /// the search for the last key counts.
    @Test
    internal func typingFindsAFileInALongListWithoutLookingThroughItOnTheMainThread() async {
        for index in 0..<25_000 {
            program.memory.addFile(String(format: "/long/f%05d.txt", index))
        }
        let app = await program.start()
        defer { app.stop() }
        app.left.show(program.memory.url("/long"))
        await program.settle(app)
        #expect(app.left.model.items.count == 25_000 && !app.left.tableView.allowsTypeSelect)
        let start = app.left.model.cursor
        app.left.typeToFind("f", at: 1)
        // Nothing has moved yet: the list is looked through elsewhere.
        #expect(app.left.model.cursor == start)
        #expect(await PanelWait.until { app.left.model.cursorItem?.name == "f00000.txt" })
        app.left.typeToFind("2", at: 1.1)
        #expect(await PanelWait.until { app.left.model.cursorItem?.name == "f20000.txt" })
        // Only the search for the last key counts.
        app.left.typeToFind("4", at: 1.2)
        app.left.typeToFind("9", at: 1.3)
        #expect(await PanelWait.until { app.left.model.cursorItem?.name == "f24900.txt" })
        // No name starts with this: the cursor stays.
        app.left.typeToFind("zzz", at: 5)
        await PanelWait.pause(0.3)
        #expect(app.left.model.cursorItem?.name == "f24900.txt")
    }
}
