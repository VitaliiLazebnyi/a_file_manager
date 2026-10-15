import AFMContracts
import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The window of the Multi-Rename Tool, driven through its controls, its keys and its menus, as
/// the user would; menus and sheets it opens are closed again at once.
@MainActor @Suite(.serialized) final class CoverageRenameWindow {
    let memory = MemoryFileSystem()
    let box: Sandbox
    let bench: TestBench
    let session: MultiRenameSession
    let controller: MultiRenameWindowController
    let window: NSWindow

    init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        memory.addFile("/w/a.txt", "a")
        memory.addFile("/w/b.txt", "b")
        memory.addFile("/w/c.jpg", "c")
        memory.addDirectory("/w/folder.d")
        memory.addFile("/w/taken.txt", "t")
        bench = TestBench(
            plugins: [],
            fileSystems: [LocalFileSystem(), memory],
            left: memory.url("/w"),
            right: memory.url("/w")
        )
        let listed = bench.left.model.items
        let items = ["a.txt", "b.txt", "c.jpg", "folder.d"].compactMap { name in listed.first { $0.name == name } }
        session = MultiRenameSession(
            kernel: bench.kernel,
            items: items,
            store: RenameStore(settings: bench.kernel.settings),
            settings: .unchanged,
            logDirectory: box.url("log"),
            previewsInBackground: false
        )
        controller = MultiRenameWindowController(kernel: bench.kernel, session: session)
        window = try #require(controller.window)
    }

    /// The window goes with the test: drawn later, it would ask a kernel that is gone.
    isolated deinit {
        // What closing hands to the autorelease pool is let go of while the window still lives.
        autoreleasepool { controller.close() }
    }

    var ui: ScriptedInteraction { bench.interaction }
    var content: NSView? { window.contentView }
    var table: NSTableView? { Controls.all(NSTableView.self, in: content).first }
    var combos: [NSComboBox] { Controls.all(NSComboBox.self, in: content) }
    var nameMask: NSComboBox { combos[0] }
    var searchBox: NSComboBox { combos[1] }
    var replaceBox: NSComboBox { combos[2] }

    /// The editable fields that are not combo boxes: extension, counter start and step.
    var fields: [NSTextField] {
        Controls.all(NSTextField.self, in: content).filter { $0.isEditable && !($0 is NSComboBox) }
    }

    var status: String {
        Controls.all(NSTextField.self, in: content)
            .first { !$0.isEditable && $0.lineBreakMode == .byTruncatingTail }?
            .stringValue ?? ""
    }

    func popup(_ title: String) -> NSPopUpButton? {
        Controls.all(NSPopUpButton.self, in: content).first { $0.itemTitles.first == title }
    }

    func press(_ title: String) {
        guard let button = Controls.button(title, in: content) else {
            Issue.record("no button \(title)")
            return
        }
        Controls.send(button)
    }

    func cell(_ column: String, _ row: Int) -> NSTextField? {
        guard let table, let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == column }) else {
            return nil
        }
        return controller.tableView(table, viewFor: tableColumn, row: row) as? NSTextField
    }

    /// Chooses the item whose title is `title` in a pop-up menu, as the user does.
    func choose(_ title: String, in popupTitle: String) {
        guard let popup = popup(popupTitle), let index = popup.itemTitles.firstIndex(of: title) else {
            Issue.record("no item \(title) in \(popupTitle)")
            return
        }
        popup.selectItem(at: index)
        Controls.send(popup)
    }

    // MARK: Fields

    @Test func typingInAFieldShowsAtOnce() throws {
        nameMask.stringValue = "n[C]"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nameMask))
        #expect(session.settings.nameMask == "n[C]" && cell("new", 0)?.stringValue == "n1.txt")
        fields[0].stringValue = "x"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[0]))
        #expect(cell("new", 1)?.stringValue == "n2.x")
        // Numbers that are not numbers count from 1 by 1.
        fields[1].stringValue = "ten"
        fields[2].stringValue = " 5 "
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[1]))
        #expect(session.settings.counter.start == 1 && session.settings.counter.step == 5)
        fields[2].stringValue = "x"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[2]))
        #expect(session.settings.counter.step == 1)
    }

    @Test func aHistoryEntryChosenInAComboBoxIsTaken() {
        session.store.remember("[N]_old", in: .nameMask)
        session.settings.nameMask = "[N]2"
        #expect(nameMask.numberOfItems == 1)
        nameMask.selectItem(at: 0)
        controller.comboBoxSelectionDidChange(
            Notification(name: NSComboBox.selectionDidChangeNotification, object: nameMask)
        )
        #expect(session.settings.nameMask == "[N]_old")
        // Nothing chosen: nothing changes.
        nameMask.deselectItem(at: 0)
        controller.comboBoxSelectionDidChange(
            Notification(name: NSComboBox.selectionDidChangeNotification, object: nameMask)
        )
        #expect(session.settings.nameMask == "[N]_old")
    }

    @Test func boxesPopUpsAndSteppersChangeTheSettings() throws {
        for title in ["^", "1x", "[E]", "RegEx", "Subst."] {
            let box = try #require(Controls.button(title, in: content))
            box.state = box.state == .on ? .off : .on
            Controls.send(box)
        }
        let settings = session.settings
        #expect(settings.caseSensitive && settings.firstOnly && !settings.searchesExtension)
        #expect(settings.regularExpression && settings.substitute)
        let letterCase = try #require(popup("Unchanged"))
        letterCase.selectItem(at: LetterCase.upper.rawValue)
        Controls.send(letterCase)
        #expect(session.settings.letterCase == .upper && cell("new", 0)?.stringValue == "A.TXT")
        // Nothing chosen counts as no change.
        letterCase.selectItem(at: -1)
        Controls.send(letterCase)
        #expect(session.settings.letterCase == .unchanged)
        let digits = try #require(popup("1"))
        digits.selectItem(at: 10)
        Controls.send(digits)
        #expect(session.settings.counter.digits == 0)
        let steppers = Controls.all(NSStepper.self, in: content)
        steppers[0].integerValue = 7
        Controls.send(steppers[0])
        steppers[1].integerValue = 3
        Controls.send(steppers[1])
        #expect(session.settings.counter.start == 7 && session.settings.counter.step == 3)
        #expect(fields[1].stringValue == "7" && fields[2].stringValue == "3")
    }

    @Test func settingsFromTheSessionFillTheFields() {
        var settings = RenameSettings()
        settings.counter = CounterDefinition(start: 4, step: 2, digits: 0)
        settings.extensionMask = "[E]x"
        settings.search = "a"
        settings.replacement = "b"
        settings.letterCase = .lower
        (settings.caseSensitive, settings.firstOnly, settings.searchesExtension) = (true, true, false)
        (settings.regularExpression, settings.substitute) = (true, true)
        session.settings = settings
        #expect(
            ["^", "1x", "[E]", "RegEx", "Subst."].map { Controls.button($0, in: content)?.state } == [
                .on, .on, .off, .on, .on
            ]
        )
        #expect(fields[0].stringValue == "[E]x" && searchBox.stringValue == "a" && replaceBox.stringValue == "b")
        #expect(popup("1")?.indexOfSelectedItem == 10 && popup("Unchanged")?.indexOfSelectedItem == 1)
        settings.counter.digits = 3
        session.settings = settings
        #expect(fields[1].stringValue == "4" && fields[2].stringValue == "2" && popup("1")?.indexOfSelectedItem == 2)
    }

    // MARK: The status line

    @Test func theStatusLineSaysWhatIsWrong() {
        session.settings.nameMask = "[Q]"
        #expect(status == "Invalid placeholder: [Q]")
        session.settings.nameMask = "[=tc.size]"
        #expect(status == "Content-plugin fields [=…] are not available.")
        session.settings.nameMask = "[N]"
        session.settings.regularExpression = true
        session.settings.search = "("
        #expect(status == "Invalid regular expression: (")
        session.settings.search = "(a*)*b"
        session.settings.nameMask = String(repeating: "a", count: 40)
        #expect(status.hasPrefix("The regular expression takes too long for these names"))
        #expect(MultiRenameWindowController.describe(RenameMaskError.numberTooLarge) == "The rename mask is invalid.")
    }

    @Test func theStatusLineCountsConflictsAndUnusableNames() {
        session.loadNames(fromText: "same.txt\nsame.txt\n..\n")
        #expect(status == "2 name conflict(s), 1 name(s) cannot be used")
        session.loadNames(fromText: "taken.txt")
        #expect(status == "1 name conflict(s)")
        session.loadNames(fromText: "..")
        #expect(status == "1 name(s) cannot be used")
        session.loadNames(fromText: "new.txt")
        #expect(status == "The names come from a list. Please press 'Start!' to start renaming!")
        session.clearGivenNames()
        #expect(status == "Please press 'Start!' to start renaming!")
    }

    // MARK: The list

    @Test func theCellsShowHowEachItemStands() {
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

    @Test func clickingAHeaderSortsAndAgainTurnsTheOrder() throws {
        let table = try #require(table)
        func click(_ id: String) {
            if let column = table.tableColumns.first(where: { $0.identifier.rawValue == id }) {
                controller.tableView(table, didClick: column)
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

    @Test func rowsAreDraggedToAnotherPlace() throws {
        let table = try #require(table)
        let scratch = ScratchPasteboard()
        let pasteboard = scratch.pasteboard
        pasteboard.clearContents()
        let item = try #require(controller.tableView(table, pasteboardWriterForRow: 2) as? NSPasteboardItem)
        pasteboard.writeObjects([item])
        let drag = FakeDrag(from: table, pasteboard: pasteboard)
        #expect(controller.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .move)
        #expect(controller.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .on).isEmpty)
        let foreign = FakeDrag(from: nil, pasteboard: pasteboard)
        #expect(
            controller.tableView(table, validateDrop: foreign, proposedRow: 0, proposedDropOperation: .above).isEmpty
        )
        let moved = session.rows[2].entry.name
        #expect(controller.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above))
        #expect(session.rows[0].entry.name == moved && table.selectedRowIndexes == [0])
        pasteboard.clearContents()
        #expect(!controller.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above))
        let untouched = ScratchPasteboard()
        let empty = FakeDrag(from: table, pasteboard: untouched.pasteboard)
        #expect(!controller.tableView(table, acceptDrop: empty, row: 0, dropOperation: .above))
    }

    // MARK: Keys

    @Test func keysOfTheList() throws {
        let table = try #require(table)
        table.selectRowIndexes([1], byExtendingSelection: false)
        let second = session.rows[1].entry.name
        table.keyDown(with: Controls.key(Controls.Code.up, "", .shift))
        #expect(session.rows[0].entry.name == second && table.selectedRowIndexes == [0])
        table.keyDown(with: Controls.key(Controls.Code.down, "", .shift))
        #expect(session.rows[1].entry.name == second)
        table.keyDown(with: Controls.key(Controls.Code.character, "1"))
        #expect(session.settings.firstOnly)
        table.keyDown(with: Controls.key(Controls.Code.character, "1"))
        table.keyDown(with: Controls.key(Controls.Code.character, "1"))
        #expect(session.settings.firstOnly)
        let count = session.rowCount
        table.keyDown(with: Controls.key(Controls.Code.forwardDelete))
        #expect(session.rowCount == count - 1 && table.selectedRowIndexes == [1])
        table.deselectAll(nil)
        table.keyDown(with: Controls.key(Controls.Code.backspace))
        #expect(session.rowCount == count - 1)
        // Other keys go to the list as usual.
        table.keyDown(with: Controls.key(Controls.Code.down))
        #expect(session.rowCount == count - 1 && session.settings.firstOnly)
        // The last row taken out leaves nothing selected.
        session.remove(IndexSet(0..<(session.rowCount - 1)))
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.keyDown(with: Controls.key(Controls.Code.forwardDelete))
        #expect(session.rowCount == 0 && table.selectedRowIndexes.isEmpty)
    }

    @Test func functionKeysOfTheWindow() {
        session.settings.nameMask = "[N]2"
        window.sendEvent(Controls.key(Controls.Code.f5))
        #expect(session.rows.first?.entry.name == "a2.txt" && session.settings == .unchanged)
        var clicked: [String?] = []
        controller.clickPopUp = { clicked.append($0.itemTitles.first) }
        window.sendEvent(Controls.key(Controls.Code.f2))
        window.sendEvent(Controls.key(Controls.Code.f10))
        #expect(clicked == ["F2 Load/save settings", "F10 Names"])
        // Any other key goes its usual way: here, into the field being edited.
        session.settings.nameMask = ""
        #expect(window.makeFirstResponder(nameMask))
        window.sendEvent(Controls.key(Controls.Code.character, "q"))
        #expect(nameMask.stringValue == "q")
    }

    @Test func shiftDeleteDropsAnEntryFromAHistory() {
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

    // MARK: Placeholders

    @Test func buttonsPutPlaceholdersIntoTheMasks() {
        session.settings.nameMask = ""
        session.settings.extensionMask = ""
        for title in ["[N] Name", "[C] Counter", "[YMD] Date", "[hms] Time"] { press(title) }
        #expect(nameMask.stringValue == "[N][C][YMD][hms]")
        press("[E] Ext.")
        #expect(fields[0].stringValue == "[E]")
        // A field that is being edited gets the placeholder in place of what is selected.
        #expect(window.makeFirstResponder(fields[0]))
        fields[0].currentEditor()?.selectedRange = NSRange(location: 0, length: 3)
        let counters = Controls.all(NSButton.self, in: content).filter { $0.title == "[C] Counter" }
        if let last = counters.last { Controls.send(last) }
        #expect(session.settings.extensionMask == "[C]")
    }

    @Test func moreFieldsComeFromMenus() throws {
        session.settings.nameMask = ""
        var menus: [(NSMenu, NSView)] = []
        controller.popUpMenu = { menus.append(($0, $1)) }
        press("+")
        let menu = try #require(menus.first?.0)
        #expect((menus.first?.1 as? NSButton)?.title == "+")
        #expect(menu.items.first?.title == "[P]  Parent folder")
        menu.performActionForItem(at: 0)
        #expect(nameMask.stringValue == "[P]")
        ui.formAnswers = [.values(["first": .text("2"), "last": .text("3")])]
        press("#")
        let rangeMenu = try #require(menus.last?.0)
        #expect(rangeMenu.items.map(\.title).last == "[X#-#]  Clipboard text")
        rangeMenu.performActionForItem(at: 3)
        #expect(nameMask.stringValue == "[P][A2-3]")
    }

    @Test func theRangePickerAsksForPositions() {
        session.settings.nameMask = ""
        session.settings.extensionMask = ""
        ui.formAnswers = [
            .cancel,
            .values(["first": .text("x")]),
            .values(["first": .text("2"), "last": .text("")]),
            .values(["first": .text("2"), "last": .text("3"), "length": .flag(true)]),
            .values(["first": .text("2"), "last": .text("3"), "firstFromEnd": .flag(true), "lastFromEnd": .flag(true)])
        ]
        for _ in 0..<5 { press("[N#-#] Range") }
        #expect(nameMask.stringValue == "[N2-][N2,3][N-2--3]")
        #expect(ui.forms.first?.isEmpty == false)
        ui.formAnswers = [.values(["first": .text("1")])]
        press("[E#-#] Range")
        #expect(fields[0].stringValue == "[E1-]")
    }

    @Test func theRangePickerShowsTheFirstName() {
        let folder = session.rows.firstIndex { $0.entry.item.isFolder } ?? 0
        session.move(IndexSet(integer: folder), to: 0)
        session.settings.nameMask = ""
        ui.formAnswers = [.cancel, .cancel]
        press("[N#-#] Range")
        var menus: [NSMenu] = []
        controller.popUpMenu = { menu, _ in menus.append(menu) }
        press("#")
        menus.first?.performActionForItem(at: 0)
        #expect(ui.log == ["form: Select the characters to insert:", "form: Select the characters to insert:"])
        session.remove(IndexSet(0..<session.rowCount))
        ui.formAnswers = [.cancel]
        press("[N#-#] Range")
        #expect(ui.log.count == 3)
    }

    // MARK: Menus

    @Test func savedSettingsAreSavedLoadedAndDeleted() {
        session.settings.nameMask = "s[C]"
        ui.promptAnswers = [.text(" Mine "), .cancel]
        choose("Save settings…", in: "F2 Load/save settings")
        #expect(session.store.savedNames == ["Mine"])
        choose("Save settings…", in: "F2 Load/save settings")
        choose("<default>", in: "F2 Load/save settings")
        #expect(session.settings == .unchanged)
        choose("Mine", in: "F2 Load/save settings")
        #expect(session.settings.nameMask == "s[C]")
        ui.formAnswers = [.cancel, .values(["row": .index(0)])]
        choose("Delete entry…", in: "F2 Load/save settings")
        #expect(session.store.savedNames == ["Mine"])
        choose("Delete entry…", in: "F2 Load/save settings")
        #expect(session.store.savedNames.isEmpty)
        // The title of the menu does nothing.
        choose("F2 Load/save settings", in: "F2 Load/save settings")
        #expect(session.settings.nameMask == "s[C]")
    }

    @Test func deletingOtherSavedSettingsKeepsTheLoadedName() {
        session.save(as: "One")
        session.save(as: "Two")
        // Nothing loaded yet: the first entry is proposed.
        ui.formAnswers = [.cancel]
        choose("Delete entry…", in: "F2 Load/save settings")
        if case .list(_, let selected)? = ui.forms.last?.first?.kind { #expect(selected == 0) }
        choose("Two", in: "F2 Load/save settings")
        ui.formAnswers = [.values(["row": .index(0)])]
        choose("Delete entry…", in: "F2 Load/save settings")
        #expect(session.store.savedNames == ["Two"])
        ui.promptAnswers = [.accept]
        choose("Save settings…", in: "F2 Load/save settings")
        #expect(ui.log.last == "prompt: Save settings [Two]")
    }

    @Test func namesComeFromTheNamesMenu() throws {
        ui.formAnswers = [.values(["names": .text("x\ny")])]
        choose("Edit names…", in: "F10 Names")
        #expect(session.givenNames == ["x", "y"])
        #expect(popup("F10 Names")?.item(withTitle: "Use the rename masks again")?.isEnabled == true)
        choose("Use the rename masks again", in: "F10 Names")
        #expect(session.givenNames == nil)
        choose("F10 Names", in: "F10 Names")
        // A list loaded from a file: the open panel is answered in the user's place.
        memory.addFile("/lists/names.txt", "x1\nx2")
        var answers: [(NSApplication.ModalResponse, [URL])] = [(.cancel, [memory.url("/lists/names.txt")])]
        var shown: [NSOpenPanel] = []
        controller.presentOpenPanel = { panel, sheetOf, done in
            #expect(sheetOf === self.window && !panel.allowsMultipleSelection)
            shown.append(panel)
            let (response, urls) = answers.removeFirst()
            done(response, urls)
        }
        choose("Load names from file…", in: "F10 Names")
        #expect(shown.count == 1 && session.givenNames == nil)
        answers = [(.OK, [memory.url("/lists/names.txt")])]
        choose("Load names from file…", in: "F10 Names")
        #expect(session.givenNames == ["x1", "x2"])
        // A file that cannot be read is reported.
        controller.namesFileChosen(memory.url("/lists/gone.txt"))
        #expect(ui.log.contains { $0.hasPrefix("inform: The names cannot be loaded!") })
        controller.namesFileChosen(nil)
        #expect(session.givenNames == ["x1", "x2"])
    }

    // MARK: Buttons

    @Test func startUndoResultListAndClose() {
        session.settings.nameMask = "r[C]"
        press("Start!")
        #expect(session.rowCount == 0 && memory.allPaths.contains("/w/r1.txt"))
        bench.kernel.commands.register(Command(.view, "View"), parameterized: { _ in })
        press("Result list")
        ui.choiceAnswers = [0]
        press("Undo")
        #expect(memory.allPaths.contains("/w/a.txt"))
        var closed = false
        controller.onClose = { closed = true }
        press("Close")
        #expect(closed && !window.isVisible)
    }

    /// A field that does not let go of the keyboard keeps the run from starting.
    @Test func startWaitsForTheFieldsToLetGo() {
        let stubborn = Stubborn(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        content?.addSubview(stubborn)
        #expect(window.makeFirstResponder(stubborn))
        session.settings.nameMask = "r[C]"
        press("Start!")
        #expect(session.rowCount == 4 && !memory.allPaths.contains("/w/r1.txt"))
        stubborn.letsGo = true
        press("↻ Next step (F5)")
        #expect(session.rows.first?.entry.name == "r1.txt")
    }

    @Test func startIsRefusedWhileARunIsUnderWay() {
        let jobs = CancellingJobService(moment: .held, panels: bench.panelSet)
        bench.kernel.attach(jobs)
        session.settings.nameMask = "r[C]"
        press("Start!")
        press("Start!")
        #expect(jobs.heldCount == 1)
        jobs.runHeld()
        #expect(memory.allPaths.contains("/w/r1.txt"))
    }

    /// A view that keeps the keyboard until it is told to let go.
    private final class Stubborn: NSView {
        var letsGo = false
        override var acceptsFirstResponder: Bool { true }
        override func resignFirstResponder() -> Bool { letsGo }
    }

    @Test func theWindowIsNeverMadeFromAnArchive() {
        #expect(MultiRenameWindowController(coder: NSCoder()) == nil)
    }
}

/// The tool opened through its command with a window, as the program opens it.
@MainActor @Suite(.serialized) struct CoverageRenamePluginWindow {
    let memory = MemoryFileSystem()
    let box: Sandbox
    let plugin: MultiRenamePlugin
    let bench: TestBench
    /// The windows the tool was asked to show: none is put on screen.
    let presenter = StabilityPresenter()

    init() throws {
        _ = NSApplication.shared
        box = try Sandbox()
        memory.addFile("/p/a.txt")
        memory.addFile("/p/b.txt")
        plugin = MultiRenamePlugin(logDirectory: box.url("log"))
        plugin.present = presenter.present
        bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/p"), right: memory.url("/p"))
    }

    var windows: [NSWindow] { presenter.open.filter { $0.title == "Multi-Rename Tool" } }

    @Test func openingAgainReplacesTheWindowAndClosingKeepsTheSettings() async {
        defer {
            plugin.stop()
            presenter.closeAll()
        }
        bench.left.model.selectAll()
        #expect(bench.commands.perform(.multiRename))
        let first = plugin.session
        #expect(windows.count == 1)
        first?.settings.nameMask = "o[C]"
        #expect(bench.commands.perform(.multiRename))
        #expect(windows.count == 1 && plugin.session !== first && plugin.session?.settings.nameMask == "o[C]")
        // The clipboard is read when a mask asks for it.
        plugin.session?.settings.nameMask = "[X+]c"
        #expect(await RunLoopWait.until { plugin.session?.isComputing == false })
        // As the close button does, without `performClose`, which runs the event loop for a moment.
        if let window = windows.first, window.delegate?.windowShouldClose?(window) ?? true {
            window.close()
        }
        #expect(plugin.session == nil && windows.isEmpty)
        #expect(bench.commands.perform(.multiRename))
        #expect(plugin.session?.settings.nameMask == "[X+]c")
        plugin.stop()
        #expect(windows.isEmpty)
        // Stopped again, with nothing open, nothing happens.
        plugin.stop()
    }
}

/// The tool without a window, where the log goes when no folder is given.
@MainActor @Suite struct CoverageRenamePluginDefaults {
    @Test func theLogGoesToTheUsersLogsFolderAndTheClipboardIsEmpty() throws {
        let memory = MemoryFileSystem()
        memory.addFile("/d/a.txt")
        let plugin = MultiRenamePlugin(opensWindows: false)
        let bench = TestBench(plugins: [plugin], fileSystems: [memory], left: memory.url("/d"), right: memory.url("/d"))
        bench.left.model.selectAll()
        #expect(bench.commands.perform(.multiRename))
        let session = try #require(plugin.session)
        #expect(session.logURL.path.hasSuffix("Library/Logs/Test/renlog.txt"))
        session.settings.nameMask = "[X+]n"
        #expect(session.rows.first?.newName == "n.txt")
        plugin.stop()
    }
}
