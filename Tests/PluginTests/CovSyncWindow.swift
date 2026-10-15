import AFMContracts
import AFMKernel
import AppKit
import Foundation
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import CompareContentPlugin
@testable import DirectorySyncPlugin

/// The Synchronize directories window, driven as the user would: nothing is put on screen, the
/// folder panel and the sets pop-up answer from the test.
@MainActor
@Suite
internal struct CovSyncWindow {
    private let stage: CovSyncStage

    /// A fresh window on two folders for every test.
    internal init() throws {
        stage = try CovSyncStage(empty: [])
    }

    /// The window shows the stage.session; Compare fills the list and its status; closing lets go of
    /// the list, and showing takes it up again.
    @Test
    internal func compareFillsTheList() throws {
        defer { stage.finish() }
        stage.controller.show()
        #expect(stage.presenter.presented.last === stage.controller)
        #expect(stage.fields.first?.stringValue == "mem:/A" && stage.table?.numberOfRows == 0)
        stage.press("Compare")
        let table = try #require(stage.table)
        #expect(stage.session.phase == .compared && table.numberOfRows == stage.session.entries.count)
        let status = stage.views(NSTextField.self).map(\.stringValue)
        #expect(status.contains(stage.session.status))
        stage.controller.close()
        #expect(table.dataSource == nil && table.delegate == nil)
        stage.controller.show()
        #expect(table.dataSource === stage.controller && table.delegate === stage.controller)
    }

    /// Enter in a field compares; the options are taken from the controls.
    @Test
    internal func theControlsSetTheOptions() throws {
        defer { stage.finish() }
        stage.controller.show()
        let typed = stage.fields
        #expect(typed.count == 4)
        typed[1].stringValue = "  "
        typed[3].stringValue = "x"
        for title in [
            "Subdirs", "by content", "ignore date", "Asymmetric", "Empty directories", "ignore 1 h difference"
        ] {
            let box = try #require(stage.button(title))
            box.state = box.state == .on ? .off : .on
            box.sendAction(box.action, to: box.target)
        }
        let tolerance = try #require(stage.views(NSPopUpButton.self).first { !$0.pullsDown })
        tolerance.selectItem(at: 1)
        tolerance.sendAction(tolerance.action, to: tolerance.target)
        #expect(stage.session.options.mask == "*.*" && stage.session.options.timeOffsetHours == 0)
        #expect(stage.session.options.toleranceSeconds == 2 && stage.session.options.ignoreOneHourDifference)
        typed[3].stringValue = "2"
        typed[0].sendAction(typed[0].action, to: typed[0].target)
        #expect(stage.session.phase == .compared && stage.session.options.timeOffsetHours == 2)
    }

    /// The Show buttons and their keys hide and show kinds of rows.
    @Test
    internal func theShowButtonsAndKeysFilterTheList() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let equal = try #require(stage.button("="))
        equal.state = .off
        equal.sendAction(equal.action, to: equal.target)
        #expect(!stage.session.show.contains(.equal))
        for (character, code) in [("l", 37), ("e", 14), ("n", 45), ("r", 15), ("d", 2), ("s", 1)] {
            try stage.type(character, code: UInt16(code), [.control, .shift])
        }
        #expect(stage.session.show.contains(.equal) && !stage.session.show.contains(.copyToRight))
        #expect(equal.state == .on)
    }

    /// The keys of the list set, clear and reverse the actions of the selected rows, open the
    /// viewer, the editor and the comparison, the sets pop-up, and go from folder to folder.
    @Test
    internal func theKeysOfTheList() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        let new = try #require(stage.position("new.txt"))
        table.selectRowIndexes([new], byExtendingSelection: false)
        let index = try #require(stage.session.rows.firstIndex { $0.name == "new.txt" })
        try stage.type(" ", code: 49, [])
        #expect(stage.session.rows[index].action == SyncAction.none)
        try stage.type(" ", code: 49, .shift)
        #expect(stage.session.rows[index].action == .copyToRight)
        let odd = try #require(stage.position("odd.txt"))
        table.selectRowIndexes([odd], byExtendingSelection: false)
        let different = try #require(stage.session.rows.firstIndex { $0.name == "odd.txt" })
        try stage.type("l", code: 37, .control)
        #expect(stage.session.rows[different].action == .copyToRight)
        try stage.type("w", code: 13, .control)
        #expect(stage.session.rows[different].action == .copyToLeft)
        try stage.type("r", code: 15, .control)
        try stage.type("m", code: 46, .control)
        #expect(stage.session.rows[different].action == SyncAction.none)
        try stage.type("d", code: 2, .control)
        // F3 with Ctrl, alone and with Shift, F4 alone and with Shift, F2.
        try stage.type("\u{F706}", code: 99, .control)
        try stage.type("\u{F706}", code: 99, [])
        try stage.type("\u{F706}", code: 99, .shift)
        try stage.type("\u{F707}", code: 118, [])
        try stage.type("\u{F707}", code: 118, .shift)
        try stage.type("\u{F705}", code: 120, [])
        #expect(stage.answers.menusShown == 1)
        table.selectRowIndexes([0], byExtendingSelection: false)
        try stage.type("\u{F72D}", code: 121, .control)
        #expect(table.selectedRow > 0)
        try stage.type("\u{F72C}", code: 116, .control)
        #expect(table.selectedRow >= 0)
        // A key the list does not know goes on to the table.
        try stage.type("\u{F701}", code: 125, [])
    }

    /// The row menu acts on the selected rows; without a selection it is empty.
    @Test
    internal func theRowMenuActsOnTheSelection() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        let menu = try #require(table.menu)
        table.deselectAll(nil)
        stage.controller.menuNeedsUpdate(menu)
        #expect(menu.items.isEmpty)
        let odd = try #require(stage.position("odd.txt"))
        table.selectRowIndexes([odd], byExtendingSelection: false)
        stage.controller.menuNeedsUpdate(menu)
        #expect(menu.items.count > 10)
        for item in menu.items where !item.isSeparatorItem {
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
        let index = try #require(stage.session.rows.firstIndex { $0.name == "odd.txt" })
        #expect(stage.session.rows[index].action == .deleteBoth)
    }

    /// The sets pop-up saves the directories and settings under a name, loads and removes them.
    @Test
    internal func theSetsMenuSavesLoadsAndRemoves() throws {
        defer { stage.finish() }
        stage.controller.show()
        let pullDowns = stage.views(NSPopUpButton.self).filter(\.pullsDown)
        let sets = try #require(pullDowns.first)
        let menu = try #require(sets.menu)
        func run(_ title: String, in items: [NSMenuItem]) {
            let item = items.first { $0.title == title }
            #expect(item != nil, "\(title)")
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        }
        stage.controller.menuNeedsUpdate(menu)
        #expect(menu.items.count == 2)
        stage.bench.interaction.promptAnswers = [.cancel, .text("Mine")]
        run("Add current directories and settings to list…", in: menu.items)
        run("Add current directories and settings to list…", in: menu.items)
        #expect(stage.session.savedSets.map(\.name) == ["Mine"])
        stage.controller.menuNeedsUpdate(menu)
        stage.fields[0].stringValue = "mem:/B"
        run("Mine", in: menu.items)
        #expect(stage.fields[0].stringValue == "mem:/A")
        let remove = try #require(menu.items.last?.submenu)
        run("Mine", in: remove.items)
        #expect(stage.session.savedSets.isEmpty)
    }

    /// The `>>` buttons ask for a folder; a chosen one is put in the field, none leaves it.
    @Test
    internal func theFolderButtonsAskForAFolder() {
        defer { stage.finish() }
        stage.controller.show()
        let pickers = stage.views(NSButton.self).filter { $0.title == ">>" }
        #expect(pickers.count == 2)
        stage.answers.folder = URL(fileURLWithPath: "/tmp/chosen")
        pickers[1].sendAction(pickers[1].action, to: pickers[1].target)
        #expect(stage.fields[2].stringValue == "/tmp/chosen")
        stage.answers.folder = nil
        pickers[0].sendAction(pickers[0].action, to: pickers[0].target)
        #expect(stage.fields[0].stringValue == "mem:/A" && stage.answers.folderRequests == 2)
    }

    /// The cells show names, sizes, dates and the action; folders and captions their own way.
    @Test
    internal func theCellsShowTheRows() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        for position in stage.session.entries.indices {
            for column in table.tableColumns {
                #expect(stage.controller.tableView(table, viewFor: column, row: position) is NSTextField)
            }
            let isHeader = stage.controller.tableView(table, isGroupRow: position)
            #expect(stage.controller.tableView(table, shouldSelectRow: position) == !isHeader)
            if isHeader { #expect(stage.controller.tableView(table, viewFor: nil, row: position) is NSTextField) }
        }
        stage.controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    /// A click on a column header sorts by it, again the other way; the action column does not sort.
    @Test
    internal func theHeadersSort() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        func click(_ id: String) {
            let column = table.tableColumns.first { $0.identifier.rawValue == id }
            if let column { stage.controller.tableView(table, didClick: column) }
        }
        click("rightSize")
        #expect(stage.session.sort.key == .size && stage.session.sort.side == .right && stage.session.sort.ascending)
        click("rightSize")
        #expect(!stage.session.sort.ascending)
        click("leftDate")
        #expect(stage.session.sort.key == .date && stage.session.sort.side == .left)
        click("action")
        #expect(stage.session.sort.key == .date)
        click("leftName")
        #expect(stage.session.sort.key == .name)
    }

    /// Clicks on the list without a row hit do nothing; a double click compares the selected row.
    @Test
    internal func clicksWithoutARowDoNothing() throws {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        let table = try #require(stage.table)
        let odd = try #require(stage.position("odd.txt"))
        table.selectRowIndexes([odd], byExtendingSelection: false)
        let before = stage.session.rows.map(\.action)
        table.sendAction(table.action, to: table.target)
        #expect(stage.session.rows.map(\.action) == before)
        table.sendAction(table.doubleAction, to: table.target)
        let mouse = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: -50, y: -50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        #expect(table.menu(for: mouse) == nil)
    }

    /// Synchronize hands the plan to the session; Close closes the window.
    @Test
    internal func synchronizeAndClose() {
        defer { stage.finish() }
        stage.controller.show()
        stage.press("Compare")
        stage.bench.interaction.formAnswers = [.cancel]
        stage.press("Synchronize…")
        #expect(!stage.bench.interaction.log.isEmpty)
        stage.press("Close")
        #expect(!stage.presenter.isOpen(stage.controller.window))
    }
}
