import AFMContracts
import AFMKernel
import AppKit
import Testing

@testable import AFMShell

/// Forms: the dialogs of fields that plugins ask the user to fill in.
@MainActor
@Suite
internal struct InteractionFormTests {
    /// Makes sure AppKit is there for the views of the form.
    internal init() {
        _ = NSApplication.shared
    }

    /// A form answers with its fields' values and puts the keyboard in its first input.
    @Test
    internal func aFormReadsItsFieldsAndPutsTheKeyboardInTheFirstInput() {
        let fields: [FormField] = [
            .note("Fill this in."), .checkbox("flag", "Recursive", true), .text("name", "Name:", "report.txt"),
            .password("secret", "Password:"), .lines("notes", "Notes:", "a\nb"),
            .choice("kind", "Kind:", ["One", "Two", "Two"], selected: 2),
            .list("row", "Pick:", ["x", "y", "z"], selected: 1)
        ]
        let dialog = FormDialog(fields: fields)
        let alert = dialog.makeAlert(title: "Form", detail: "Detail", buttons: ["OK", "Apply"])
        #expect(
            alert.buttons.map(\.title) == ["OK", "Apply", "Cancel"] && alert.buttons.last?.keyEquivalent == "\u{1b}"
        )
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        // Unchanged, the form answers with what the fields were given.
        let answer = dialog.values(button: 1)
        #expect(answer.button == 1 && answer.values == FormValues(defaultsOf: fields).values)
        #expect(
            (dialog.firstInput as? NSTextField)?.stringValue == "report.txt"
                && alert.window.initialFirstResponder === dialog.firstInput
        )
        #expect(dialog.scrollView == nil && dialog.lists.count == 1 && dialog.lists[0].searchField == nil)
    }

    /// A form taller than the screen allows scrolls, its first row at the top.
    @Test
    internal func aFormWithManyFieldsIsScrolled() {
        let fields = (1...40).map { FormField.text("field\($0)", "Field \($0):", "\($0)") }
        let dialog = FormDialog(fields: fields)
        let alert = dialog.makeAlert(title: "Many", detail: "", buttons: ["OK"], maximumHeight: 300)
        #expect(dialog.scrollView != nil && alert.accessoryView === dialog.scrollView)
        #expect(dialog.scrollView?.frame.height == 300 && (dialog.scrollView?.documentView?.frame.height ?? 0) > 900)
        // The first row is at the top of what is seen.
        #expect(dialog.scrollView?.contentView.isFlipped == true && dialog.scrollView?.contentView.bounds.origin.y == 0)
        #expect(dialog.values(button: 0).text("field40") == "40")
    }

    /// A long list gets a filter; typing narrows it down and the answer counts in the whole list.
    @Test
    internal func aLongListIsNarrowedDownByTyping() {
        let rows = (1...30).map { "Entry \($0)" } + ["Übersicht"]
        let dialog = FormDialog(fields: [.list("row", "", rows, selected: 4)])
        _ = dialog.makeAlert(title: "Pick", detail: "", buttons: ["Go"])
        let list = dialog.lists[0]
        #expect(list.searchField != nil && dialog.firstInput === list.searchField && list.selectedRow == 4)
        list.filter("entry 2")
        #expect(
            list.shown.map { rows[$0] }.starts(with: ["Entry 2", "Entry 20", "Entry 21"]) && list.shown.count == 11
        )
        // The chosen row is gone from the list: the first one that is left is chosen.
        #expect(list.selectedRow == 1 && dialog.values(button: 0).index("row") == 1)
        list.moveSelection(by: 2)
        #expect(list.selectedRow == 20)
        list.moveSelection(by: 100)
        #expect(list.selectedRow == 28)
        // A row that stays in the list stays chosen; the answer counts in the whole list.
        list.filter("")
        #expect(list.shown.count == 31 && list.selectedRow == 28)
        list.filter("ubersicht")
        #expect(list.selectedRow == 30)
        list.filter("nothing like this")
        #expect(list.selectedRow == -1 && dialog.values(button: 0).index("row") == -1)
    }
}
