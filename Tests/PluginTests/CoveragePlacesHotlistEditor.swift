import AFMKernel
import AppKit
import Foundation
import TestSupport
import Testing

@testable import PlacesPlugin

/// The hotlist editor, run as the modal window it is, with a script that works it.
@MainActor
@Suite(.serialized)
internal struct CoveragePlacesHotlistEditor {
    /// The file system of the panels, which show `mem:/C`.
    internal let memory = MemoryFileSystem()
    /// The kernel with the Places plugin.
    internal let bench: TestBench

    /// A list of an item, a submenu with one item, and a separator.
    internal let sample = Hotlist(entries: [
        .item("A", command: "cd /a"), .submenu("S", [.item("In", command: "cd /in")]), .separator
    ])

    /// The scripted answers to the editor's questions, and what it asked.
    internal var interaction: ScriptedInteraction { bench.interaction }

    /// The kernel with the Places plugin, both panels on `mem:/C`.
    internal init() {
        _ = NSApplication.shared
        memory.addDirectory("/C")
        bench = TestBench(
            plugins: [PlacesPlugin(keepsTreesOnDisk: false, favorites: [])],
            fileSystems: [memory],
            left: memory.url("/C"),
            right: memory.url("/C")
        )
    }

    /// Opens the editor on `list` in `directory` and returns what it gives back.
    ///
    /// No modal loop runs: `script` works the window and ends it.
    internal func edit(
        _ list: Hotlist,
        in directory: URL,
        script: (CoveragePlacesEditorParts) throws -> Void
    ) rethrows -> Hotlist? {
        let controller = HotlistEditorWindowController(list, kernel: bench.kernel, currentDirectory: directory)
        defer { controller.close() }
        guard let window = controller.window else {
            Issue.record("the editor has no window")
            return nil
        }
        try script(CoveragePlacesEditorParts(window: window))
        #expect(!window.isVisible)
        return controller.result
    }

    /// Opens the editor on `list` in the panel's folder `mem:/C`; see `edit(_:in:script:)`.
    internal func edit(_ list: Hotlist, script: (CoveragePlacesEditorParts) throws -> Void) rethrows -> Hotlist? {
        try edit(list, in: memory.url("/C"), script: script)
    }

    /// Cancel gives nothing back, whatever was changed before.
    @Test
    internal func cancelGivesNothingBack() {
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

    /// The fields show and change the selected entry; with nothing selected, typing goes nowhere.
    @Test
    internal func theFieldsBelongToTheSelectedEntry() {
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
        #expect(result?.entries[0] == .item("A", command: "cd /a") && result?.hideCharacter.isEmpty == true)
    }

    /// New items, submenus and separators go below the selected entry, or into the submenu that
    /// is selected; a title of `-` makes a separator and an empty one adds nothing.
    @Test
    internal func entriesAreAddedBelowTheSelectionOrIntoTheSubmenu() {
        interaction.promptAnswers = [.accept, .text("-"), .cancel, .text(""), .text("Sub"), .cancel, .text("")]
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
        #expect(interaction.log.contains("prompt: Title of the new entry: [C]"))
        #expect(result?.entries[1].children.first == .item("C", command: "cd mem:/C"))
        #expect(result?.count == 8)
    }

    /// Titles change as typed, except a separator's and with nothing selected.
    @Test
    internal func titlesChangeExceptForSeparators() {
        interaction.promptAnswers = [.text("&First"), .cancel, .text("")]
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
        #expect(result?.entries.map(\.title) == ["&First", "S", "-"] && interaction.promptAnswers.isEmpty)
    }

    /// Entries move with the buttons and Shift-arrows and are deleted with the button, Delete and
    /// Command-Backspace; with nothing selected the buttons do nothing.
    @Test
    internal func entriesMoveAndAreDeletedByButtonAndKey() throws {
        let result = try edit(sample) { parts in
            parts.click("Move Down")
            #expect(parts.titles.prefix(2) == ["▾ S", "      A"])
            parts.click("Move Up")
            #expect(parts.titles.prefix(2) == ["A", "▾ S"])
            try parts.press("\u{F701}", code: 125, .shift)
            try parts.press("\u{F700}", code: 126, .shift)
            parts.select(3)
            try parts.press("\u{F728}", code: 117, [])
            try parts.press("\u{7F}", code: 51, .command)
            // A key the editor does not take goes to the list.
            try parts.press("x", code: 7, [])
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

    /// A double click marks the entry with the hide character or takes the mark off, and the box
    /// hides the marked entries.
    @Test
    internal func aDoubleClickMarksAnEntryHiddenAndTheBoxHidesThem() {
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

    /// A full list takes no new entry and says so; a folder without a name is proposed as the
    /// title by its path.
    @Test
    internal func aFullListTakesNoMoreAndANamelessFolderIsProposedByItsPath() throws {
        let full = Hotlist(entries: (0..<Hotlist.limit).map { .item("e\($0)", command: "") })
        let nameless = try #require(URL(string: "mem:"))
        interaction.promptAnswers = [.accept]
        let result = edit(full, in: nameless) { parts in
            parts.click("Add Item…")
            parts.click("Cancel")
        }
        #expect(result == nil)
        let path = bench.kernel.fileSystems.displayPath(nameless)
        #expect(interaction.log == ["prompt: Title of the new entry: [\(path)]", "inform: The directory menu is full."])
    }
}
