import AppKit
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The list of the window: its cells, sorting, dragging, and the keys.
extension CoverageRenameWindow {
    // MARK: The list

    /// The cells show each item, its new name and how that stands.
    @Test
    internal func theCellsShowHowEachItemStands() {
        session.loadNames(fromText: "a.txt\nnew.txt\n..\n")
        #expect(cell("old", 0)?.stringValue == "a" && cell("ext", 0)?.stringValue == "txt")
        #expect(cell("new", 0)?.textColor == .secondaryLabelColor)
        #expect(cell("new", 1)?.textColor == .labelColor)
        #expect(cell("new", 2)?.toolTip == ".. is not a name.")
        #expect(cell("size", 3)?.stringValue == "<DIR>" && cell("old", 3)?.stringValue == "folder.d")
        #expect(cell("ext", 3)?.stringValue.isEmpty == true)
        session.loadNames(fromText: "same.txt\nsame.txt")
        #expect(cell("new", 1)?.toolTip == "Another file in the list gets the same name.")
        #expect(cell("size", 0)?.alignment == .right && cell("date", 0)?.stringValue.isEmpty == false)
        #expect(cell("location", 0)?.stringValue.hasSuffix("/") == true)
        session.loadNames(fromText: "taken.txt")
        #expect(cell("new", 0)?.toolTip == "A file with this name already exists.")
        session.clearGivenNames()
        session.settings.nameMask = "[X]"
        #expect(cell("new", 0)?.stringValue == RenameEngine.errorText && cell("new", 0)?.textColor == .systemRed)
        // A row or a column that is not there has no cell.
        if let table {
            #expect(controller.tableView(table, viewFor: nil, row: 0) == nil)
            #expect(controller.tableView(table, viewFor: table.tableColumns[0], row: 99) == nil)
        }
    }

    /// A click on a header sorts by that column and a second one turns the order; other columns do not sort.
    @Test
    internal func clickingAHeaderSortsAndAgainTurnsTheOrder() throws {
        let list = try #require(table)
        func click(_ id: String) {
            if let column = list.tableColumns.first(where: { $0.identifier.rawValue == id }) {
                controller.tableView(list, didClick: column)
            }
        }
        click("old")
        #expect(session.rows.first?.entry.name == "a.txt")
        click("old")
        #expect(session.rows.first?.entry.name == "folder.d")
        click("ext")
        click("size")
        click("date")
        let order = session.rows.map(\.entry.name)
        click("new")
        click("location")
        #expect(session.rows.map(\.entry.name) == order)
    }

    /// Rows of the list's own drag are dropped at another place; other drags are refused.
    @Test
    internal func rowsAreDraggedToAnotherPlace() throws {
        let list = try #require(table)
        let scratch = ScratchPasteboard()
        let pasteboard = scratch.pasteboard
        pasteboard.clearContents()
        let item = try #require(controller.tableView(list, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        pasteboard.writeObjects([item])
        let drag = FakeDrag(from: list, pasteboard: pasteboard)
        #expect(controller.tableView(list, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .move)
        #expect(controller.tableView(list, validateDrop: drag, proposedRow: 0, proposedDropOperation: .on).isEmpty)
        let foreign = FakeDrag(from: nil, pasteboard: pasteboard)
        #expect(
            controller.tableView(list, validateDrop: foreign, proposedRow: 0, proposedDropOperation: .above).isEmpty
        )
        let moved = session.rows[2].entry.name
        #expect(controller.tableView(list, acceptDrop: drag, row: 0, dropOperation: .above))
        #expect(session.rows[0].entry.name == moved && list.selectedRowIndexes == [0])
        pasteboard.clearContents()
        #expect(!controller.tableView(list, acceptDrop: drag, row: 0, dropOperation: .above))
        let untouched = ScratchPasteboard()
        let empty = FakeDrag(from: list, pasteboard: untouched.pasteboard)
        #expect(!controller.tableView(list, acceptDrop: empty, row: 0, dropOperation: .above))
    }

    // MARK: Keys

    /// Shift and the arrows move rows, Delete takes them out and 1 switches "1x"; other keys go to the list.
    @Test
    internal func keysOfTheList() throws {
        let list = try #require(table)
        list.selectRowIndexes([1], byExtendingSelection: false)
        let second = session.rows[1].entry.name
        list.keyDown(with: Controls.key(Controls.Code.upArrow, "", .shift))
        #expect(session.rows[0].entry.name == second && list.selectedRowIndexes == [0])
        list.keyDown(with: Controls.key(Controls.Code.downArrow, "", .shift))
        #expect(session.rows[1].entry.name == second)
        list.keyDown(with: Controls.key(Controls.Code.character, "1"))
        #expect(session.settings.firstOnly)
        list.keyDown(with: Controls.key(Controls.Code.character, "1"))
        list.keyDown(with: Controls.key(Controls.Code.character, "1"))
        #expect(session.settings.firstOnly)
        let count = session.rowCount
        list.keyDown(with: Controls.key(Controls.Code.forwardDelete))
        #expect(session.rowCount == count - 1 && list.selectedRowIndexes == [1])
        list.deselectAll(nil)
        list.keyDown(with: Controls.key(Controls.Code.backspace))
        #expect(session.rowCount == count - 1)
        // Other keys go to the list as usual.
        list.keyDown(with: Controls.key(Controls.Code.downArrow))
        #expect(session.rowCount == count - 1 && session.settings.firstOnly)
        // The last row taken out leaves nothing selected.
        session.remove(IndexSet(0..<(session.rowCount - 1)))
        list.selectRowIndexes([0], byExtendingSelection: false)
        list.keyDown(with: Controls.key(Controls.Code.forwardDelete))
        #expect(session.rowCount == 0 && list.selectedRowIndexes.isEmpty)
    }

    /// F5, F2 and F10 work wherever the keyboard is; other keys go their usual way.
    @Test
    internal func functionKeysOfTheWindow() {
        session.settings.nameMask = "[N]2"
        window.sendEvent(Controls.key(Controls.Code.functionKey5))
        #expect(session.rows.first?.entry.name == "a2.txt" && session.settings == .unchanged)
        var clicked: [String?] = []
        controller.clickPopUp = { clicked.append($0.itemTitles.first) }
        window.sendEvent(Controls.key(Controls.Code.functionKey2))
        window.sendEvent(Controls.key(Controls.Code.functionKey10))
        #expect(clicked == ["F2 Load/save settings", "F10 Names"])
        // Any other key goes its usual way: here, into the field being edited.
        session.settings.nameMask = ""
        #expect(window.makeFirstResponder(nameMask))
        window.sendEvent(Controls.key(Controls.Code.character, "q"))
        #expect(nameMask.stringValue == "q")
    }

    /// Shift+Delete in a box drops its text from the history, if it is there.
    @Test
    internal func shiftDeleteDropsAnEntryFromAHistory() {
        session.store.remember("old", in: .search)
        session.store.remember("older", in: .search)
        session.settings.search = "older"
        #expect(window.makeFirstResponder(searchBox))
        window.sendEvent(Controls.key(Controls.Code.forwardDelete, "", .shift))
        #expect(session.store.history(.search) == ["old"] && searchBox.numberOfItems == 1)
        // Text that is in no history is left alone.
        #expect(window.makeFirstResponder(nil))
        session.settings.search = "never"
        #expect(window.makeFirstResponder(searchBox))
        window.sendEvent(Controls.key(Controls.Code.backspace, "", .shift))
        #expect(session.store.history(.search) == ["old"])
        // Outside a combo box the key is the field's own.
        #expect(window.makeFirstResponder(fields[0]))
        window.sendEvent(Controls.key(Controls.Code.forwardDelete, "", .shift))
        #expect(session.store.history(.search) == ["old"])
    }
}
