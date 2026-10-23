import AFMKernel
import AppKit
import LocalFileSystemPlugin
import TestSupport
import Testing

@testable import MultiRenamePlugin

/// The window of the Multi-Rename Tool, driven through its controls, its keys and its menus, as
/// the user would; menus and sheets it opens are closed again at once.
@MainActor
@Suite(.serialized)
internal final class CoverageRenameWindow {
    /// A view that keeps the keyboard until it is told to let go.
    internal final class Stubborn: NSView {
        /// Whether the view gives the keyboard up when asked.
        internal var letsGo = false

        /// The view takes the keyboard.
        override internal var acceptsFirstResponder: Bool { true }

        /// The view gives the keyboard up only once it is told to.
        override internal func resignFirstResponder() -> Bool { letsGo }
    }

    /// The file system of the list: three files, a folder and `taken.txt` in `/w`.
    internal let memory = MemoryFileSystem()
    /// A folder on the disk for the log.
    internal let box: Sandbox
    /// The program the window runs in.
    internal let bench: TestBench
    /// The session the window shows: `a.txt`, `b.txt`, `c.jpg` and `folder.d`.
    internal let session: MultiRenameSession
    /// The window's controller.
    internal let controller: MultiRenameWindowController
    /// The window, never put on screen.
    internal let window: NSWindow

    /// The answers to the window's questions, and what it asked.
    internal var interaction: ScriptedInteraction { bench.interaction }
    /// The content of the window.
    internal var content: NSView? { window.contentView }
    /// The list of the items.
    internal var table: NSTableView? { Controls.all(NSTableView.self, in: content).first }
    /// The boxes with a history: name mask, search, replacement.
    internal var combos: [NSComboBox] { Controls.all(NSComboBox.self, in: content) }
    /// The name mask.
    internal var nameMask: NSComboBox { combos[0] }
    /// "Search for".
    internal var searchBox: NSComboBox { combos[1] }
    /// "Replace with".
    internal var replaceBox: NSComboBox { combos[2] }

    /// The editable fields that are not combo boxes: extension, counter start and step.
    internal var fields: [NSTextField] {
        Controls.all(NSTextField.self, in: content).filter { $0.isEditable && !($0 is NSComboBox) }
    }

    /// The status line.
    internal var status: String {
        Controls.all(NSTextField.self, in: content)
            .first { !$0.isEditable && $0.lineBreakMode == .byTruncatingTail }?
            .stringValue ?? ""
    }

    /// The window over four items of `/w`.
    internal init() throws {
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
            previewsInBackground: false,
            clipboard: { nil },
            clipboardChangeCount: nil
        )
        controller = MultiRenameWindowController(kernel: bench.kernel, session: session)
        window = try #require(controller.window)
    }

    /// The pop-up button whose first item is `title`.
    internal func popup(_ title: String) -> NSPopUpButton? {
        Controls.all(NSPopUpButton.self, in: content).first { $0.itemTitles.first == title }
    }

    /// Presses the button titled `title`; a button that is not there fails the test.
    internal func press(_ title: String) {
        guard let button = Controls.button(title, in: content) else {
            Issue.record("no button \(title)")
            return
        }
        Controls.send(button)
    }

    /// The cell of `row` in the column `column`, as the list asks for it.
    internal func cell(_ column: String, _ row: Int) -> NSTextField? {
        guard let table, let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == column }) else {
            return nil
        }
        return controller.tableView(table, viewFor: tableColumn, row: row) as? NSTextField
    }

    /// Chooses the item whose title is `title` in a pop-up menu, as the user does.
    internal func choose(_ title: String, in popupTitle: String) {
        guard let popup = popup(popupTitle), let index = popup.itemTitles.firstIndex(of: title) else {
            Issue.record("no item \(title) in \(popupTitle)")
            return
        }
        popup.selectItem(at: index)
        Controls.send(popup)
    }

    // MARK: Fields

    /// What is typed into a field shows in the preview at once; a counter field that holds no number counts
    /// from 1 by 1.
    @Test
    internal func typingInAFieldShowsAtOnce() {
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

    /// An entry chosen from the history of a box is taken; choosing nothing changes nothing.
    @Test
    internal func aHistoryEntryChosenInAComboBoxIsTaken() {
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

    /// The check boxes, the pop-up buttons and the steppers change the settings.
    @Test
    internal func boxesPopUpsAndSteppersChangeTheSettings() throws {
        for title in ["^", "1x", "[E]", "RegEx", "Subst."] {
            let checkbox = try #require(Controls.button(title, in: content))
            checkbox.state = checkbox.state == .on ? .off : .on
            Controls.send(checkbox)
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

    /// Settings put into the session fill the fields.
    @Test
    internal func settingsFromTheSessionFillTheFields() {
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

    /// The status line says what is wrong with the masks or the expression.
    @Test
    internal func theStatusLineSaysWhatIsWrong() {
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

    /// The status line counts the conflicts and the names that cannot be used, or says what the start
    /// button does.
    @Test
    internal func theStatusLineCountsConflictsAndUnusableNames() {
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

    /// The window goes with the test: drawn later, it would ask a kernel that is gone.
    isolated deinit {
        // What closing hands to the autorelease pool is let go of while the window still lives.
        autoreleasepool { controller.close() }
    }
}
