import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import CompareContentPlugin

/// The compare window's keys and moving around: differences, searching, the panes kept together.
@MainActor
@Suite
internal struct CoverageCompareWindowKeys {
    /// Key codes of the named keys.
    private enum Code {
        static let down: UInt16 = 125, up: UInt16 = 126, left: UInt16 = 123, right: UInt16 = 124
        static let backspace: UInt16 = 51, f3: UInt16 = 99, f6: UInt16 = 97, f7: UInt16 = 98
        /// A key that produces a character: its code does not name a key.
        static let character: UInt16 = 0
    }

    /// The differences are gone through with the buttons and with Option+arrows; past the last one it beeps.
    @Test
    internal func theDifferencesAreGoneThroughAndPastTheLastItBeeps() {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let blocks = stage.session.blocks.map(\.lowerBound)
        // The first difference is shown when the comparison comes.
        #expect(stage.selectedRows == [blocks[0]])
        stage.click("Next difference")
        #expect(stage.selectedRows == [blocks[1]])
        stage.press(Code.down, "", .option)
        #expect(stage.selectedRows == [blocks[2]])
        stage.press(Code.down, "", .option)
        #expect(stage.recorder.beeps == 1 && stage.selectedRows == [blocks[2]])
        stage.click("Previous difference")
        stage.press(Code.up, "", .option)
        #expect(stage.selectedRows == [blocks[0]])
        stage.press(Code.up, "", .option)
        #expect(stage.recorder.beeps == 2)
        // Without a selection the top of the pane counts.
        stage.tables[0].deselectAll(nil)
        stage.click("Next difference")
        #expect(stage.selectedRows == [blocks[0]])
    }

    /// The search finds text in either file from the selected row; nothing found beeps, and an empty search field
    /// is given the keyboard.
    @Test
    internal func theSearchFindsTextInEitherFile() throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let field = try #require(stage.searchField)
        field.stringValue = "NEW LINE"
        _ = field.target?.perform(field.action, with: field)
        let row = try #require(stage.selectedRows.first)
        #expect(stage.session.text(.right, row: row) == "new line")
        stage.press(Code.f3, "", .shift)
        stage.press(Code.f3)
        #expect(stage.selectedRows == [row])
        field.stringValue = "nowhere"
        stage.press(Code.f3)
        #expect(stage.recorder.beeps == 1 && stage.status == "\"nowhere\" was not found.")
        field.stringValue = ""
        stage.press(Code.f3)
        #expect(stage.window?.firstResponder === field.currentEditor() || stage.window?.firstResponder === field)
    }

    /// The keys of the panes do what the window's buttons do; other keys are the table's.
    @Test
    internal func theKeysOfThePanesDoWhatTheButtonsDo() throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let session = stage.session
        stage.press(Code.f6)
        #expect(session.isEditing && stage.button("Edit mode")?.state == .on)
        stage.press(Code.right, "", .option)
        #expect(session.hasUnsavedChanges)
        stage.press(Code.character, "z", .command)
        #expect(!session.hasUnsavedChanges)
        stage.press(Code.left, "", .option)
        stage.press(Code.character, "z", .control)
        stage.press(Code.left, "", .option)
        stage.press(Code.backspace, "", .option)
        #expect(!session.hasUnsavedChanges)
        stage.press(Code.right, "", .option)
        stage.press(Code.character, "s", .command)
        #expect(!session.hasUnsavedChanges && stage.memory.contents("/B/right.txt")?.contains("changed 3") == false)
        stage.press(Code.character, "s", .control)
        stage.press(Code.f7)
        stage.press(Code.character, "f", .control)
        stage.press(Code.character, "f", .command)
        #expect(stage.window?.firstResponder is NSTextView)
        stage.tables[0].selectRowIndexes([0, 1], byExtendingSelection: false)
        stage.press(Code.character, "c", .command)
        #expect(stage.recorder.scratch.pasteboard.string(forType: .string) == "line 0\nline 1")
        stage.press(Code.character, "c", .control)
        stage.press(Code.character, "u", .control)
        #expect(session.leftURL?.path == "/B/right.txt")
        stage.press(Code.f6)
        #expect(!session.isEditing)
        // Outside edit mode Option+arrows do not copy; a plain key is the table's own.
        stage.press(Code.right, "", .option)
        stage.press(Code.character, "x")
        #expect(!session.hasUnsavedChanges)
    }

    /// The panes scroll and select together.
    @Test
    internal func thePanesScrollAndSelectTogether() throws {
        let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
        defer { stage.close() }
        let (left, right) = (stage.tables[0], stage.tables[1])
        right.selectRowIndexes([5], byExtendingSelection: false)
        #expect(left.selectedRowIndexes == [5])
        let clip = try #require(right.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 40))
        #expect(left.enclosingScrollView?.contentView.bounds.origin.y == 40)
        // Scrolled again to the same place: nothing to follow.
        clip.scroll(to: NSPoint(x: 0, y: 40))
        #expect(left.enclosingScrollView?.contentView.bounds.origin.y == 40)
    }

    /// A pane whose window has gone answers no key of its own.
    @Test
    internal func aPaneWhoseWindowHasGoneAnswersNoKey() throws {
        // Made and let go of in a pool of its own, so that nothing keeps the window's controller.
        let (table, scratch) = try autoreleasepool { () throws -> (NSTableView, CoverageCompareStage.Recorder) in
            let stage = CoverageCompareStage(left: CoverageCompareWindow.left, right: CoverageCompareWindow.right)
            let table = try #require(stage.tables.first)
            stage.close()
            return (table, stage.recorder)
        }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .option,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: Code.down
            )
        )
        table.keyDown(with: event)
        #expect(scratch.beeps == 0)
    }
}
