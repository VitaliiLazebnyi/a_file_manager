import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The four tabs of the Find Files window: what the controls say, the browse button and the
/// saved searches, driven through the controls.
@MainActor
@Suite
internal struct CoverageFindForm {
    /// A file system for the fields to know.
    internal let memory = MemoryFileSystem()
    /// The file systems of the fields.
    internal let registry = FileSystemRegistry()
    /// Where the saved searches go.
    internal let settings = MemorySettings()
    /// The questions the form asks, answered by the test.
    internal let answers = ScriptedInteraction()
    /// The form, in no window unless a test puts it in one.
    internal let form: SearchForm

    /// The form over an empty memory.
    internal init() {
        _ = NSApplication.shared
        registry.register(memory)
        form = SearchForm(
            fields: SearchField.builtIn(fileSystems: registry),
            store: SearchStore(settings: settings),
            ui: answers
        )
    }

    /// Every view of a type on all four pages.
    internal func all<View: NSView>(_ type: View.Type) -> [View] {
        form.tabView.tabViewItems.flatMap { Controls.all(type, in: $0.view) }
    }

    /// The button (a box or a push button) with this title.
    internal func box(_ title: String) -> NSButton? { all(NSButton.self).first { $0.title == title } }

    /// Sends the action of the button with this title, as a click does.
    internal func press(_ title: String) {
        guard let button = box(title) else {
            Issue.record("no button \(title)")
            return
        }
        Controls.send(button)
    }

    /// The pop-up buttons whose first item has this title.
    internal func popup(startingWith title: String) -> [NSPopUpButton] {
        all(NSPopUpButton.self).filter { $0.itemTitles.first == title }
    }

    /// The controls say what is searched for.
    @Test
    internal func theControlsSayWhatIsSearchedFor() throws {
        for title in ["Attributes:", "Not older than:", "Older than:", "File size:", "Search in plugins (columns):"] {
            box(title)?.state = .on
        }
        let attributes = ["Hidden", "Directory", "Symbolic link", "Read only", "Executable", "Package"].compactMap(box)
        (attributes[0].state, attributes[1].state, attributes[2].state) = (.on, .off, .mixed)
        // Units that are not chosen count as days, bytes and "equal".
        for unit in popup(startingWith: Age.Unit.minutes.title) { unit.selectItem(at: -1) }
        popup(startingWith: SizeRule.Comparison.allCases[0].title).first?.selectItem(at: -1)
        popup(startingWith: SizeRule.Unit.bytes.title).first?.selectItem(at: -1)
        let fields = all(NSTextField.self).filter { $0.isEditable && !($0 is NSComboBox) }
        // Not older than, older than, size, the value of the rule.
        let size = fields[2]
        size.stringValue = "1,5"
        all(NSPopUpButton.self).first { $0.itemTitles.first == "all (unlimited depth)" }?.selectItem(at: 3)
        let rule = try #require(popup(startingWith: FieldRule.Operator.allCases[0].title).first)
        rule.selectItem(at: -1)
        fields.last?.stringValue = "abc"
        let read = form.settings
        #expect(read.depth == 2)
        #expect(read.criteria.hidden == .yes && read.criteria.directory == .no && read.criteria.symbolicLink == .any)
        #expect(read.criteria.notOlderThan?.unit == .days && read.criteria.olderThan?.unit == .days)
        #expect(read.criteria.size?.comparison == .equal && read.criteria.size?.unit == .bytes)
        #expect(read.fieldRules.rules.first?.comparison == .contains)
    }

    /// Sizes and rules that cannot be shown as they are.
    @Test
    internal func sizesAndRulesThatCannotBeShownAsTheyAre() {
        var odd = SearchSettings()
        odd.criteria.size = SizeRule(.greater, 1e30)
        odd.depth = Int.max
        odd.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("plugin.gone", .equals, "x")])
        form.settings = odd
        #expect(form.settings.depth == 10 && form.settings.criteria.size?.value == 1e30)
        #expect(form.settings.fieldRules.rules.first?.field == "tc.name")
        // A size that is no number counts as none.
        let size = all(NSTextField.self).first { $0.stringValue == "1e+30" }
        size?.stringValue = "lots"
        #expect(form.settings.criteria.size?.value == 0)
    }

    /// Boxes fields and rule buttons.
    @Test
    internal func boxesFieldsAndRuleButtons() {
        var submitted = 0
        form.onSubmit = { submitted += 1 }
        Controls.send(form.searchForField)
        #expect(submitted == 1)
        box("Find text:")?.state = .on
        press("Find text:")
        #expect(box("Whole words only")?.isEnabled == true)
        press("More rules")
        press("More rules")
        #expect(popup(startingWith: FieldRule.Operator.allCases[0].title).count == 3)
        press("Fewer rules")
        press("Fewer rules")
        press("Fewer rules")
        #expect(popup(startingWith: FieldRule.Operator.allCases[0].title).count == 1)
    }

    /// Browse chooses start directories.
    @Test
    internal func browseChoosesStartDirectories() {
        // Not in a window yet: there is nothing to show the panel on.
        var shown = 0
        form.presentOpenPanel = { _, _, _ in shown += 1 }
        press(">>")
        #expect(shown == 0)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        // Closing would release it once more than it was retained: the test holds it itself.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = form.tabView
        var choices: [(NSApplication.ModalResponse, [URL])] = [
            (.cancel, [URL(fileURLWithPath: "/x")]), (.OK, []),
            (.OK, [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])
        ]
        form.presentOpenPanel = { panel, sheetOf, done in
            #expect(sheetOf === window && panel.canChooseDirectories && panel.allowsMultipleSelection)
            let (response, urls) = choices.removeFirst()
            done(response, urls)
        }
        form.settings = SearchSettings()
        press(">>")
        press(">>")
        #expect(form.settings.searchIn.isEmpty)
        press(">>")
        #expect(form.settings.searchIn == "/a;/b")
    }

    /// Saved searches are saved loaded and deleted.
    @Test
    internal func savedSearchesAreSavedLoadedAndDeleted() throws {
        let table = try #require(all(NSTableView.self).first)
        var saved = SearchSettings()
        saved.searchFor = "*.txt"
        form.settings = saved
        // Nothing chosen: Load and Delete do nothing.
        press("Load")
        press("Delete")
        answers.promptAnswers = [.cancel, .text("  "), .accept]
        press("Save")
        press("Save")
        press("Save")
        #expect(answers.log.last == "prompt: Save search as: [*.txt]" && table.numberOfRows == 1)
        let name = try #require(form.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTextField)
        let summary = try #require(form.tableView(table, viewFor: table.tableColumns[1], row: 0) as? NSTextField)
        #expect(name.stringValue == "*.txt" && summary.stringValue == "*.txt")
        #expect((form.tableView(table, viewFor: nil, row: 0) as? NSTextField)?.stringValue == "*.txt")
        table.selectRowIndexes([0], byExtendingSelection: false)
        form.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(box("Load")?.isEnabled == true)
        form.settings = SearchSettings()
        press("Load")
        #expect(form.settings.searchFor == "*.txt")
        // Saving with a search chosen proposes its name.
        table.selectRowIndexes([0], byExtendingSelection: false)
        answers.promptAnswers = [.cancel]
        press("Save")
        #expect(answers.log.last == "prompt: Save search as: [*.txt]")
        table.selectRowIndexes([0], byExtendingSelection: false)
        press("Delete")
        #expect(table.numberOfRows == 0)
    }
}
