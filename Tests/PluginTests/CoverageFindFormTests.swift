import AFMContracts
import AFMKernel
import AppKit
import TestSupport
import Testing

@testable import FindFilesPlugin

/// The four tabs of the Find Files window: what the controls say, the browse button and the
/// saved searches, driven through the controls.
@MainActor @Suite struct CoverageFindForm {
    let memory = MemoryFileSystem()
    let registry = FileSystemRegistry()
    let settings = MemorySettings()
    let ui = ScriptedInteraction()
    let form: SearchForm

    init() {
        _ = NSApplication.shared
        registry.register(memory)
        form = SearchForm(
            fields: SearchField.builtIn(fileSystems: registry),
            store: SearchStore(settings: settings),
            ui: ui
        )
    }

    /// Every view of a type on all four pages.
    func all<View: NSView>(_ type: View.Type) -> [View] {
        form.tabView.tabViewItems.flatMap { Controls.all(type, in: $0.view) }
    }

    func box(_ title: String) -> NSButton? { all(NSButton.self).first { $0.title == title } }

    func press(_ title: String) {
        guard let button = box(title) else {
            Issue.record("no button \(title)")
            return
        }
        Controls.send(button)
    }

    func popup(startingWith title: String) -> [NSPopUpButton] {
        all(NSPopUpButton.self).filter { $0.itemTitles.first == title }
    }

    @Test func theControlsSayWhatIsSearchedFor() throws {
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

    @Test func sizesAndRulesThatCannotBeShownAsTheyAre() {
        var settings = SearchSettings()
        settings.criteria.size = SizeRule(.greater, 1e30)
        settings.depth = Int.max
        settings.fieldRules = FieldRules(isEnabled: true, rules: [FieldRule("plugin.gone", .equals, "x")])
        form.settings = settings
        #expect(form.settings.depth == 10 && form.settings.criteria.size?.value == 1e30)
        #expect(form.settings.fieldRules.rules.first?.field == "tc.name")
        // A size that is no number counts as none.
        let size = all(NSTextField.self).first { $0.stringValue == "1e+30" }
        size?.stringValue = "lots"
        #expect(form.settings.criteria.size?.value == 0)
    }

    @Test func boxesFieldsAndRuleButtons() {
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

    @Test func browseChoosesStartDirectories() throws {
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
        var answers: [(NSApplication.ModalResponse, [URL])] = [
            (.cancel, [URL(fileURLWithPath: "/x")]), (.OK, []),
            (.OK, [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")])
        ]
        form.presentOpenPanel = { panel, sheetOf, done in
            #expect(sheetOf === window && panel.canChooseDirectories && panel.allowsMultipleSelection)
            let (response, urls) = answers.removeFirst()
            done(response, urls)
        }
        form.settings = SearchSettings()
        press(">>")
        press(">>")
        #expect(form.settings.searchIn.isEmpty)
        press(">>")
        #expect(form.settings.searchIn == "/a;/b")
    }

    @Test func savedSearchesAreSavedLoadedAndDeleted() throws {
        let table = try #require(all(NSTableView.self).first)
        var settings = SearchSettings()
        settings.searchFor = "*.txt"
        form.settings = settings
        // Nothing chosen: Load and Delete do nothing.
        press("Load")
        press("Delete")
        ui.promptAnswers = [.cancel, .text("  "), .accept]
        press("Save")
        press("Save")
        press("Save")
        #expect(ui.log.last == "prompt: Save search as: [*.txt]" && table.numberOfRows == 1)
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
        ui.promptAnswers = [.cancel]
        press("Save")
        #expect(ui.log.last == "prompt: Save search as: [*.txt]")
        table.selectRowIndexes([0], byExtendingSelection: false)
        press("Delete")
        #expect(table.numberOfRows == 0)
    }
}
