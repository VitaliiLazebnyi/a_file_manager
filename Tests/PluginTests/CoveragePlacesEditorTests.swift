import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The parts of the hotlist editor's window, found by their place in it.
@MainActor
struct CoveragePlacesEditorParts {
    let window: NSWindow
    var controller: HotlistEditorWindowController? { window.delegate as? HotlistEditorWindowController }
    var content: NSView? { window.contentView }
    var table: NSTableView? { CoveragePlacesLoop.views(NSTableView.self, in: content).first }
    var fields: [NSTextField] { CoveragePlacesLoop.views(NSTextField.self, in: content).filter(\.isEditable) }
    var command: NSTextField { fields[0] }
    var target: NSTextField { fields[1] }
    var hideCharacter: NSTextField { fields[2] }
    var number: String {
        ((content as? NSStackView)?.arrangedSubviews.last as? NSStackView)?.arrangedSubviews.first
            .map { ($0 as? NSTextField)?.stringValue ?? "" } ?? ""
    }
    var titles: [String] {
        guard let table, let controller else {
            return []
        }
        return (0..<controller.numberOfRows(in: table))
            .map {
                (controller.tableView(table, viewFor: nil, row: $0) as? NSTextField)?.stringValue ?? ""
            }
    }

    /// Clicks the button titled `title`, whether it is enabled or not.
    func click(_ title: String) {
        guard let button = CoveragePlacesLoop.button(title, in: content), let action = button.action else {
            Issue.record("no button \(title)")
            return
        }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    func select(_ row: Int) {
        table?.selectRowIndexes([row], byExtendingSelection: false)
    }

    func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        controller?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        table?.keyDown(with: CoveragePlacesLoop.key(characters, code: code, modifiers: modifiers))
    }
}

/// The hotlist editor, run as the modal window it is, with a script that works it.
@MainActor
@Suite(.serialized)
struct CoveragePlacesHotlistEditor {
    let memory = MemoryFileSystem()
    let bench: TestBench
    var ui: ScriptedInteraction { bench.interaction }

    init() {
        _ = NSApplication.shared
        memory.addDirectory("/C")
        bench = TestBench(
            plugins: [PlacesPlugin(keepsTreesOnDisk: false, favorites: [])],
            fileSystems: [memory],
            left: memory.url("/C"),
            right: memory.url("/C")
        )
    }

    /// Opens the editor on `list` without a modal loop; `script` works the window and ends it.
    func edit(
        _ list: Hotlist,
        in directory: URL? = nil,
        script: (CoveragePlacesEditorParts) -> Void
    ) -> Hotlist? {
        let controller = HotlistEditorWindowController(
            list,
            kernel: bench.kernel,
            currentDirectory: directory ?? memory.url("/C")
        )
        defer { controller.close() }
        guard let window = controller.window else {
            Issue.record("the editor has no window")
            return nil
        }
        script(CoveragePlacesEditorParts(window: window))
        #expect(!window.isVisible)
        return controller.result
    }

    let sample = Hotlist(entries: [
        .item("A", command: "cd /a"), .submenu("S", [.item("In", command: "cd /in")]), .separator
    ])

    @Test
    func cancelGivesNothingBack() {
        var hidden = sample
        hidden.hidesMarked = true
        let result = edit(hidden) { parts in
            let box = CoveragePlacesLoop.button("Hide menu items starting with this character:", in: parts.content)
            #expect(box?.state == .on)
            parts.click("Delete Item")
            parts.click("Cancel")
        }
        #expect(result == nil)
    }

    @Test
    func theFieldsBelongToTheSelectedEntry() {
        let result = edit(sample) { parts in
            #expect(parts.command.stringValue == "cd /a" && parts.number == "Entry 1 of 4")
            parts.select(2)
            #expect(parts.command.stringValue == "cd /in" && parts.command.isEnabled)
            parts.type("cd /in2", into: parts.command)
            parts.type("cd mem:/C", into: parts.target)
            parts.select(1)
            #expect(parts.command.stringValue.isEmpty && !parts.command.isEnabled && parts.number == "Entry 2 of 4")
            // Nothing selected: typing goes nowhere.
            parts.table?.deselectAll(nil)
            parts.type("cd /lost", into: parts.command)
            #expect(parts.number == "Entry 0 of 4")
            parts.type("-", into: parts.hideCharacter)
            parts.click("OK")
        }
        #expect(result?.entries[1].children == [.item("In", command: "cd /in2", target: "cd mem:/C")])
        #expect(result?.entries[0] == .item("A", command: "cd /a") && result?.hideCharacter == "")
    }

    @Test
    func entriesAreAddedBelowTheSelectionOrIntoTheSubmenu() {
        ui.promptAnswers = [.accept, .text("-"), .cancel, .text(""), .text("Sub"), .cancel, .text("")]
        let result = edit(sample) { parts in
            parts.select(1)
            parts.click("Add Item…")
            parts.click("Add Item…")
            parts.click("Add Item…")
            parts.click("Add Item…")
            parts.click("Add Submenu…")
            parts.click("Add Submenu…")
            parts.click("Add Submenu…")
            parts.table?.deselectAll(nil)
            parts.click("Add Separator")
            #expect(
                parts.titles == [
                    "A", "▾ S", "      C", "      " + HotlistMenu.separatorTitle, "      ▾ Sub", "      In",
                    HotlistMenu.separatorTitle, HotlistMenu.separatorTitle
                ]
            )
            parts.click("OK")
        }
        #expect(ui.log.contains("prompt: Title of the new entry: [C]"))
        #expect(result?.entries[1].children.first == .item("C", command: "cd mem:/C"))
        #expect(result?.count == 8)
    }

    @Test
    func titlesChangeExceptForSeparators() {
        ui.promptAnswers = [.text("&First"), .cancel, .text("")]
        let result = edit(sample) { parts in
            parts.click("Change Title…")
            parts.click("Change Title…")
            parts.click("Change Title…")
            parts.select(3)
            #expect(CoveragePlacesLoop.button("Change Title…", in: parts.content)?.isEnabled == false)
            parts.click("Change Title…")
            parts.table?.deselectAll(nil)
            parts.click("Change Title…")
            parts.click("OK")
        }
        #expect(result?.entries.map(\.title) == ["&First", "S", "-"] && ui.promptAnswers.isEmpty)
    }

    @Test
    func entriesMoveAndAreDeletedByButtonAndKey() {
        let result = edit(sample) { parts in
            parts.click("Move Down")
            #expect(parts.titles.prefix(2) == ["▾ S", "      A"])
            parts.click("Move Up")
            #expect(parts.titles.prefix(2) == ["A", "▾ S"])
            parts.press("\u{F701}", code: 125, .shift)
            parts.press("\u{F700}", code: 126, .shift)
            parts.select(3)
            parts.press("\u{F728}", code: 117)
            parts.press("\u{7F}", code: 51, .command)
            // A key the editor does not take goes to the list.
            parts.press("x", code: 7)
            #expect(parts.titles == ["A", "▾ S"])
            parts.table?.deselectAll(nil)
            parts.click("Move Up")
            parts.click("Delete Item")
            parts.select(0)
            parts.click("Delete Item")
            parts.click("Delete Item")
            #expect(parts.titles.isEmpty && parts.number.isEmpty)
            parts.click("Delete Item")
            parts.click("OK")
        }
        #expect(result == Hotlist())
    }

    @Test
    func aDoubleClickMarksAnEntryHiddenAndTheBoxHidesThem() {
        let result = edit(sample) { parts in
            guard let table = parts.table, let action = table.doubleAction else {
                return
            }
            NSApp.sendAction(action, to: table.target, from: table)
            table.deselectAll(nil)
            NSApp.sendAction(action, to: table.target, from: table)
            parts.type("!", into: parts.hideCharacter)
            parts.select(1)
            NSApp.sendAction(action, to: table.target, from: table)
            // A click turns the box on.
            // (`performClick` runs the event loop for a moment, which can end the test process.)
            if let box = CoveragePlacesLoop.button("Hide menu items starting with this character:", in: parts.content) {
                box.state = box.state == .on ? .off : .on
                box.sendAction(box.action, to: box.target)
            }
            parts.click("OK")
        }
        #expect(result?.entries.map(\.title) == ["?A", "!S", "-"] && result?.hidesMarked == true)
        #expect(result?.hideCharacter == "!")
    }

    @Test
    func aFullListTakesNoMoreAndANamelessFolderIsProposedByItsPath() throws {
        let full = Hotlist(entries: (0..<Hotlist.limit).map { .item("e\($0)", command: "") })
        let nameless = try #require(URL(string: "mem:"))
        ui.promptAnswers = [.accept]
        let result = edit(full, in: nameless) { parts in
            parts.click("Add Item…")
            parts.click("Cancel")
        }
        #expect(result == nil)
        let path = bench.kernel.fileSystems.displayPath(nameless)
        #expect(ui.log == ["prompt: Title of the new entry: [\(path)]", "inform: The directory menu is full."])
    }
}
