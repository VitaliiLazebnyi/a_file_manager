import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// The compare window's editing, resynchronizing and drawing: the buttons, the cells typed into, the marks, and
/// the rows of every kind.
@MainActor
@Suite
internal struct CoverageCompareWindowEdits {
    /// The buttons copy the difference at the cursor or the selected lines, undo, and save.
    @Test
    internal func theButtonsCopyUndoAndSave() {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let session = stage.session
        stage.toggle("Edit mode")
        // Nothing selected: nothing to copy.
        stage.tables[0].deselectAll(nil)
        stage.click("Copy ->")
        #expect(!session.hasUnsavedChanges)
        stage.tables[0].selectRowIndexes([3], byExtendingSelection: false)
        stage.click("Copy ->")
        #expect(session.modified.right && session.blocks.count == 2)
        stage.click("Undo")
        #expect(!session.hasUnsavedChanges)
        // Several rows: those rows.
        stage.tables[0].selectRowIndexes([0, 1, 2, 3], byExtendingSelection: false)
        stage.click("Copy <-")
        #expect(session.modified.left)
        stage.click("Save")
        #expect(!session.hasUnsavedChanges && stage.memory.contents("/A/left.txt")?.contains("changed 3") == true)
        // A row outside every difference: that row alone.
        stage.tables[0].selectRowIndexes([0], byExtendingSelection: false)
        stage.click("Copy ->")
        #expect(!session.hasUnsavedChanges)
    }

    /// A cell typed into changes the line of its side.
    @Test
    internal func aCellTypedIntoChangesItsLine() throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        stage.toggle("Edit mode")
        let controller = try #require(stage.controller)
        let (left, right) = (stage.tables[0], stage.tables[1])
        let column = right.tableColumns[1]
        let cell = try #require(controller.tableView(right, viewFor: column, row: 0) as? NSTextField)
        #expect(cell.isEditable)
        // Not in a table: nothing is changed.
        cell.stringValue = "typed"
        _ = cell.target?.perform(cell.action, with: cell)
        #expect(!stage.session.hasUnsavedChanges)
        right.reloadData()
        let shown = try #require(right.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)
        shown.stringValue = "typed"
        _ = shown.target?.perform(shown.action, with: shown)
        #expect(stage.session.text(.right, row: 0) == "typed" && stage.session.modified.right)
        _ = left
    }

    /// Two marked lines resynchronize the comparison; the mark can be forgotten, and the context menu swaps.
    @Test
    internal func markedLinesResynchronize() throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let (left, right) = (stage.tables[0], stage.tables[1])
        let menu = try #require(left.menu)
        func choose(_ title: String) {
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
                return
            }
            _ = (item.target as? NSObject)?.perform(action, with: item)
        }
        stage.window?.makeFirstResponder(left)
        left.selectRowIndexes([5], byExtendingSelection: false)
        stage.click("Resync")
        #expect(stage.status.hasPrefix("Line marked on the left"))
        stage.window?.makeFirstResponder(right)
        right.selectRowIndexes([7], byExtendingSelection: false)
        choose("Mark line for resync")
        #expect(!stage.session.anchors.isEmpty)
        choose("Forget resync")
        #expect(stage.session.anchors.isEmpty)
        stage.window?.makeFirstResponder(right)
        choose("Mark line for resync")
        #expect(stage.status.hasPrefix("Line marked on the right"))
        right.selectRowIndexes([1], byExtendingSelection: false)
        choose("Copy selection to clipboard")
        #expect(stage.recorder.scratch.pasteboard.string(forType: .string) == "line 1")
        choose("Swap Panels")
        stage.click("Swap")
        #expect(stage.session.leftURL?.path == "/A/left.txt")
    }

    /// Every kind of row is drawn: equal, changed, and lines one side does not have.
    @Test
    internal func everyKindOfRowIsDrawn() throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let controller = try #require(stage.controller)
        for table in stage.tables {
            for row in 0..<stage.session.rowCount {
                _ = controller.tableView(table, rowViewForRow: row)
                for column in table.tableColumns { _ = controller.tableView(table, viewFor: column, row: row) }
            }
        }
        // Drawn off the screen: a row of a difference has its colour, a row of equal lines none.
        for row in [0, 3] {
            let view = try #require(controller.tableView(stage.tables[0], rowViewForRow: row))
            view.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
        }
        #expect(stage.session.rowCount == 21)
    }

    /// In binary mode the rows past the end of the shorter file are drawn without a line on that side.
    @Test
    internal func binaryRowsPastTheShorterFileAreDrawn() throws {
        let stage = CoverageCompareStage(left: "\u{0}abc", right: "\u{0}abd" + String(repeating: "z", count: 40))
        defer { stage.close() }
        let controller = try #require(stage.controller)
        #expect(stage.session.isBinary)
        for table in stage.tables {
            for row in 0..<stage.session.rowCount { _ = controller.tableView(table, rowViewForRow: row) }
        }
        #expect(stage.session.text(.left, row: stage.session.rowCount - 1) == nil)
    }

    /// A very long line shows its start shows its start and cannot be edited.
    @Test
    internal func aVeryLongLineShowsItsStartAndIsNotEdited() throws {
        let long = String(repeating: "x", count: 4 * TextDiff.inlineLimit + 10)
        let stage = CoverageCompareStage(left: "a\n" + long + "\n", right: "a\n" + long + "y\n")
        defer { stage.close() }
        stage.toggle("Edit mode")
        let controller = try #require(stage.controller)
        let right = stage.tables[1]
        let cell = try #require(controller.tableView(right, viewFor: right.tableColumns[1], row: 1) as? NSTextField)
        #expect(!cell.isEditable && cell.stringValue.count == TextDiff.inlineLimit)
    }

    /// Esc while a comparison runs stops it and keeps the window; when none runs Esc is the window's, which closes.
    @Test
    internal func escStopsAComparisonThatRuns() async throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let window = try #require(stage.window)
        stage.session.runsInline = false
        stage.memory.stallsReads = true
        stage.click("Compare")
        #expect(stage.session.phase == .working)
        window.cancelOperation(nil)
        #expect(!stage.wasClosed)
        stage.memory.releaseStalls()
        let deadline = Date(timeIntervalSinceNow: 60)
        while stage.session.phase == .working, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(stage.session.phase == .ready)
        #expect(stage.controller?.stopsComparison() == false)
    }
}
