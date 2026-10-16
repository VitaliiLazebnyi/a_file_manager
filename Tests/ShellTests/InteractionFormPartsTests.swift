import AFMContracts
import AFMKernel
import AppKit
import Testing

@testable import AFMShell

/// The parts of a form: its answer, its keys, its lists, and a scrolled form following the keyboard.
@MainActor
@Suite
internal struct InteractionFormPartsTests {
    /// Makes sure AppKit is there for the views of the form.
    internal init() {
        _ = NSApplication.shared
    }

    /// Every view inside `view`, depth first.
    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    /// The button that ended the form is its answer with the fields; the Cancel after them is nil.
    @Test
    internal func theButtonThatEndedTheFormIsItsAnswer() {
        let dialog = FormDialog(fields: [.checkbox("flag", "Recursive", false), .text("name", "Name:", "a")])
        let alert = dialog.makeAlert(title: "Form", detail: "", buttons: ["OK", "Apply"])
        #expect(alert.buttons.last?.title == "Cancel")
        let applied = dialog.answer(after: .alertSecondButtonReturn, buttons: ["OK", "Apply"])
        #expect(applied?.button == 1 && applied?.values["flag"] == .flag(false) && applied?.text("name") == "a")
        #expect(dialog.answer(after: .alertThirdButtonReturn, buttons: ["OK", "Apply"]) == nil)
    }

    /// The rows may take what the screen leaves beside the alert, within limits.
    @Test
    internal func theRowsTakeWhatTheScreenLeaves() {
        #expect(FormDialog.maximumHeight(forScreenHeight: nil) == 460)
        #expect(FormDialog.maximumHeight(forScreenHeight: 2_000) == 560)
        #expect(FormDialog.maximumHeight(forScreenHeight: 400) == 240)
        #expect(FormDialog.maximumHeight >= 240)
    }

    /// In a box for several lines Tab and Shift+Tab leave the box; other keys are the box's own.
    @Test
    internal func tabLeavesABoxOfSeveralLines() throws {
        let dialog = FormDialog(fields: [.lines("notes", "Notes:", "a"), .text("name", "Name:", "b")])
        let alert = dialog.makeAlert(title: "Form", detail: "", buttons: ["OK"])
        let box = try #require(dialog.firstInput as? NSTextView)
        alert.window.makeFirstResponder(box)
        #expect(dialog.textView(box, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(alert.window.firstResponder !== box)
        alert.window.makeFirstResponder(box)
        #expect(dialog.textView(box, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(!dialog.textView(box, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    /// In a scrolled form the field that gets the keyboard is brought into view.
    @Test
    internal func aScrolledFormFollowsTheKeyboard() throws {
        let fields =
            (1...40).map { FormField.text("field\($0)", "Field \($0):", "\($0)") }
            + [.lines("notes", "Notes:", "")]
        let dialog = FormDialog(fields: fields)
        let alert = dialog.makeAlert(title: "Many", detail: "", buttons: ["OK"], maximumHeight: 300)
        let scroll = try #require(dialog.scrollView)
        let views = Self.views(in: try #require(alert.accessoryView))
        let last = try #require(views.compactMap { $0 as? NSTextField }.last { $0.isEditable })
        alert.window.makeFirstResponder(last)
        #expect(scroll.contentView.bounds.origin.y > 0)
        let notes = try #require(views.compactMap { $0 as? NSTextView }.first)
        alert.window.makeFirstResponder(notes)
        alert.window.makeFirstResponder(nil)
        #expect(alert.window.firstResponder === alert.window)
    }

    /// A short list has no filter; typing in the filter of a long one narrows it; the arrow and
    /// page keys move through it from there.
    @Test
    internal func theKeysOfAListsFilterMoveThroughTheList() throws {
        let short = FormList(rows: ["a", "b"], selected: 0, width: 200)
        short.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(short.searchField == nil && short.shown == [0, 1])
        let rows = (1...30).map { "Row \($0)" }
        let list = FormList(rows: rows, selected: 0, width: 200)
        let filter = try #require(list.searchField)
        filter.stringValue = "row 1"
        list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(list.shown.count == 11)
        let editor = NSTextView()
        func send(_ selector: Selector) -> Bool {
            list.control(filter, textView: editor, doCommandBy: selector)
        }
        #expect(send(#selector(NSResponder.moveDown(_:))) && list.selectedRow == 9)
        #expect(send(#selector(NSResponder.moveUp(_:))) && list.selectedRow == 0)
        #expect(send(#selector(NSResponder.pageDown(_:))) && list.selectedRow != 0)
        #expect(send(#selector(NSResponder.scrollPageUp(_:))) && list.selectedRow == 0)
        #expect(send(#selector(NSResponder.scrollPageDown(_:))) && send(#selector(NSResponder.pageUp(_:))))
        #expect(!send(#selector(NSResponder.insertNewline(_:))))
        // Rows are found by typing their beginning; an empty list moves nowhere.
        #expect(list.tableView(list.table, typeSelectStringFor: nil, row: 1) == "Row 10")
        list.filter("nothing")
        list.moveSelection(by: 1)
        #expect(list.selectedRow == -1)
    }

    /// A double click on a row accepts the form; one beside the rows does not.
    @Test
    internal func aDoubleClickOnARowAcceptsTheForm() throws {
        let dialog = FormDialog(fields: [.list("row", "", ["x", "y"], selected: 0)])
        let alert = dialog.makeAlert(title: "Pick", detail: "", buttons: ["Go"])
        var accepted = 0
        let counter = AppActionCounter { accepted += 1 }
        let first = try #require(alert.buttons.first)
        (first.target, first.action) = (counter, #selector(AppActionCounter.run(_:)))
        let list = dialog.lists[0]
        list.table.sendAction(list.table.doubleAction, to: list.table.target)
        #expect(accepted == 0)
        list.doubleClicked(row: 1)
        #expect(accepted == 1)
    }
}
