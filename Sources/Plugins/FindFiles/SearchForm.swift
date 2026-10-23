import AFMKernel
import AppKit

/// The four tabs of the Find Files window (spec 09 › General tab, Advanced tab, Plugins tab,
/// Load/Save tab).
///
/// It only holds controls: `settings` reads them out as a `SearchSettings` and writes one back, and
/// that is all the rest of the window knows of them. Main thread only.
@MainActor
internal final class SearchForm: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Shows an open panel as a sheet of a window, then hands the button and the locations chosen to the
    /// function given.
    internal typealias OpenPanelPresenter =
        (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse, [URL]) -> Void) -> Void

    /// One row of the Plugins tab: field, operator and value, in a stack of their own.
    @MainActor
    internal struct RuleRow {
        /// The field the rule tests.
        internal let field: NSPopUpButton
        /// The operator.
        internal let comparison: NSPopUpButton
        /// The value compared with.
        internal let value: NSTextField
        /// The stack the three are in.
        internal let view: NSStackView

        /// A row of new controls in `view`.
        internal init(view: NSStackView) {
            (field, comparison, value) = (NSPopUpButton(), NSPopUpButton(), NSTextField())
            self.view = view
        }
    }

    /// The tabs, which the window shows.
    internal let tabView = NSTabView()
    /// "Search for".
    internal let searchForField = NSComboBox()
    /// Enter in one of the text fields.
    internal var onSubmit: (() -> Void)?
    /// Shows an open panel as a sheet of the window and hands on the button and the locations
    /// chosen.
    ///
    /// The program shows the real panel; a test answers in its place.
    internal var presentOpenPanel: OpenPanelPresenter = { panel, window, done in
        panel.beginSheetModal(for: window) { done($0, panel.urls) }
    }
    /// What the program put into "Search in" last (the panel's folder, a saved search): a
    /// field that says something else was typed, or picked, by the user.
    internal private(set) var placedSearchIn: String?

    /// The fields the rules of the Plugins tab can test, in the order of their menu.
    internal let fields: [SearchField]
    /// The saved searches and the histories of the fields.
    internal let store: SearchStore
    /// Asks for the name a search is saved under.
    internal let interaction: any UserInteraction

    // General
    /// "Search in".
    internal let searchInField = NSComboBox()
    /// "RegEx" of "Search for".
    internal let namesRegexBox = SearchForm.box("RegEx")
    /// "Only search in selected directories/files".
    internal let selectedBox = SearchForm.box("Only search in selected directories/files")
    /// "Search archives".
    internal let archivesBox = SearchForm.box("Search archives")
    /// "Spotlight (local volumes)".
    internal let spotlightBox = SearchForm.box("Spotlight (local volumes)")
    /// "Search in subdirectories": all, the start directory only, or 1 to 10 levels.
    internal let depthPopup = NSPopUpButton()
    /// "Find text".
    internal let findTextBox = SearchForm.box("Find text:")
    /// The text to find.
    internal let textField = NSComboBox()
    /// "Whole words only".
    internal let wholeWordsBox = SearchForm.box("Whole words only")
    /// "Case sensitive".
    internal let caseBox = SearchForm.box("Case sensitive")
    /// "RegEx" of the text.
    internal let textRegexBox = SearchForm.box("RegEx")
    /// "Hex".
    internal let hexBox = SearchForm.box("Hex")
    /// "Find files NOT containing the text".
    internal let notContainingBox = SearchForm.box("Find files NOT containing the text")
    /// One box per encoding, in the order of `TextEncoding.allCases`.
    internal let encodingBoxes = TextEncoding.allCases.map { SearchForm.box($0.title) }

    // Advanced
    /// "Date between".
    internal let dateBox = SearchForm.box("Date between:")
    /// The first day of "Date between".
    internal let fromPicker = NSDatePicker()
    /// The last day of "Date between".
    internal let toPicker = NSDatePicker()
    /// "Not older than".
    internal let notOlderBox = SearchForm.box("Not older than:")
    /// The count of "Not older than".
    internal let notOlderField = NSTextField(string: "1")
    /// The unit of "Not older than", in the order of `Age.Unit`.
    internal let notOlderUnit = NSPopUpButton()
    /// "Older than".
    internal let olderBox = SearchForm.box("Older than:")
    /// The count of "Older than".
    internal let olderField = NSTextField(string: "1")
    /// The unit of "Older than", in the order of `Age.Unit`.
    internal let olderUnit = NSPopUpButton()
    /// "File size".
    internal let sizeBox = SearchForm.box("File size:")
    /// The comparison of the size, in the order of `SizeRule.Comparison`.
    internal let sizeComparison = NSPopUpButton()
    /// The figure of the size.
    internal let sizeField = NSTextField(string: "1")
    /// The unit of the size, in the order of `SizeRule.Unit`.
    internal let sizeUnit = NSPopUpButton()
    /// "Attributes".
    internal let attributesBox = SearchForm.box("Attributes:")
    /// The attribute boxes, each set, clear or mixed (either).
    internal let attributeBoxes = ["Hidden", "Directory", "Symbolic link", "Read only", "Executable", "Package"]
        .map { SearchForm.box($0) }
    /// "Find duplicate files".
    internal let duplicatesBox = SearchForm.box("Find duplicate files:")
    /// "same name" of the duplicates.
    internal let sameNameBox = SearchForm.box("same name")
    /// "same size" of the duplicates.
    internal let sameSizeBox = SearchForm.box("same size")
    /// "same contents" of the duplicates.
    internal let sameContentsBox = SearchForm.box("same contents")

    // Plugins
    /// "Search in plugins (columns)".
    internal let rulesBox = SearchForm.box("Search in plugins (columns):")
    /// "Combine with": AND, then OR.
    internal let combinePopup = NSPopUpButton()
    /// The stack of the rule rows.
    internal let rulesStack = NSStackView()
    /// The rule rows, top to bottom.
    internal var ruleRows: [RuleRow] = []

    // Load/Save
    /// The list of the saved searches.
    internal let savedTable = NSTableView()
    /// The saved searches the list shows, in its order.
    internal var saved: [SavedSearch] = []
    /// Load, Save and Delete.
    internal var savedButtons: [NSButton] = []

    /// The form as a `SearchSettings`: read out of the controls, or put into them.
    internal var settings: SearchSettings {
        get {
            func isOn(_ box: NSButton) -> Bool { box.state == .on }
            func tri(_ box: NSButton) -> TriState {
                isOn(attributesBox) ? (box.state == .mixed ? .any : box.state == .on ? .set : .unset) : .any
            }
            var read = SearchSettings()
            read.searchFor = searchForField.stringValue
            read.searchIn = searchInField.stringValue
            read.namesAreRegex = isOn(namesRegexBox)
            read.onlySelected = isOn(selectedBox)
            read.searchArchives = isOn(archivesBox)
            read.useSpotlight = isOn(spotlightBox)
            read.depth = depthPopup.indexOfSelectedItem <= 0 ? nil : depthPopup.indexOfSelectedItem - 1
            read.findText = isOn(findTextBox)
            read.text = textField.stringValue
            read.caseSensitive = isOn(caseBox)
            let encodings = zip(TextEncoding.allCases, encodingBoxes).filter { isOn($0.1) }.map(\.0)
            read.textOptions = TextSearchOptions(
                wholeWords: isOn(wholeWordsBox),
                regex: isOn(textRegexBox),
                hex: isOn(hexBox),
                notContaining: isOn(notContainingBox),
                encodings: encodings.isEmpty ? [.utf8] : encodings
            )
            let calendar = Calendar.current
            if isOn(dateBox) {
                read.criteria.dateFrom = calendar.startOfDay(for: fromPicker.dateValue)
                // The whole last day counts.
                read.criteria.dateTo = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: toPicker.dateValue)
                )?
                .addingTimeInterval(-1)
            }
            func age(_ box: NSButton, _ field: NSTextField, _ unit: NSPopUpButton) -> Age? {
                isOn(box)
                    ? Age(max(field.integerValue, 0), Age.Unit(rawValue: unit.indexOfSelectedItem) ?? .days) : nil
            }
            read.criteria.notOlderThan = age(notOlderBox, notOlderField, notOlderUnit)
            read.criteria.olderThan = age(olderBox, olderField, olderUnit)
            if isOn(sizeBox) {
                read.criteria.size = SizeRule(
                    SizeRule.Comparison(rawValue: sizeComparison.indexOfSelectedItem) ?? .equal,
                    Double(sizeField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    SizeRule.Unit(rawValue: sizeUnit.indexOfSelectedItem) ?? .bytes
                )
            }
            (read.criteria.hidden, read.criteria.directory, read.criteria.symbolicLink) =
                (tri(attributeBoxes[0]), tri(attributeBoxes[1]), tri(attributeBoxes[2]))
            (read.criteria.readOnly, read.criteria.executable, read.criteria.package) =
                (tri(attributeBoxes[3]), tri(attributeBoxes[4]), tri(attributeBoxes[5]))
            read.duplicates = DuplicateOptions(
                isEnabled: isOn(duplicatesBox),
                sameName: isOn(sameNameBox),
                sameSize: isOn(sameSizeBox),
                sameContents: isOn(sameContentsBox)
            )
            read.fieldRules = FieldRules(
                isEnabled: isOn(rulesBox),
                matchAll: combinePopup.indexOfSelectedItem == 0,
                rules: readRules()
            )
            return read
        }
        set {
            func set(_ box: NSButton, _ isOn: Bool) { box.state = isOn ? .on : .off }
            searchForField.stringValue = newValue.searchFor
            searchInField.stringValue = newValue.searchIn
            placedSearchIn = newValue.searchIn
            set(namesRegexBox, newValue.namesAreRegex)
            set(selectedBox, newValue.onlySelected && selectedBox.isEnabled)
            set(archivesBox, newValue.searchArchives)
            set(spotlightBox, newValue.useSpotlight)
            depthPopup.selectItem(
                at: min(
                    newValue.depth.map { max($0, 0) < Int.max ? max($0, 0) + 1 : Int.max } ?? 0,
                    depthPopup.numberOfItems - 1
                )
            )
            set(findTextBox, newValue.findText)
            textField.stringValue = newValue.text
            set(caseBox, newValue.caseSensitive)
            set(wholeWordsBox, newValue.textOptions.wholeWords)
            set(textRegexBox, newValue.textOptions.regex)
            set(hexBox, newValue.textOptions.hex)
            set(notContainingBox, newValue.textOptions.notContaining)
            for (encoding, box) in zip(TextEncoding.allCases, encodingBoxes) {
                set(box, newValue.textOptions.encodings.contains(encoding))
            }
            show(newValue.criteria)
            set(duplicatesBox, newValue.duplicates.isEnabled)
            set(sameNameBox, newValue.duplicates.sameName)
            set(sameSizeBox, newValue.duplicates.sameSize)
            set(sameContentsBox, newValue.duplicates.sameContents)
            set(rulesBox, newValue.fieldRules.isEnabled)
            combinePopup.selectItem(at: newValue.fieldRules.matchAll ? 0 : 1)
            while let row = ruleRows.popLast() {
                remove(row)
            }
            for rule in newValue.fieldRules.rules {
                addRuleRow(rule)
            }
            if ruleRows.isEmpty {
                addRuleRow(nil)
            }
            updateEnabled()
        }
    }

    /// The form for searches whose rules test `fields`, keeping its searches and histories in `store`.
    internal init(fields: [SearchField], store: SearchStore, interaction: any UserInteraction) {
        self.fields = fields
        self.store = store
        self.interaction = interaction
        super.init()
        build()
        settings = SearchSettings()
        reloadSaved()
        reloadHistories()
    }

    private static func box(_ title: String) -> NSButton {
        NSButton(checkboxWithTitle: title, target: nil, action: nil)
    }

    /// The rules of the rows that name a field and hold a value, in order.
    private func readRules() -> [FieldRule] {
        ruleRows.compactMap { row -> FieldRule? in
            guard fields.indices.contains(row.field.indexOfSelectedItem), !row.value.stringValue.isEmpty else {
                return nil
            }
            return FieldRule(
                fields[row.field.indexOfSelectedItem].id,
                FieldRule.Operator(rawValue: row.comparison.indexOfSelectedItem) ?? .contains,
                row.value.stringValue
            )
        }
    }

    /// Puts the criteria of the Advanced tab into its controls.
    private func show(_ criteria: FileCriteria) {
        func set(_ box: NSButton, _ isOn: Bool) { box.state = isOn ? .on : .off }
        func set(_ box: NSButton, _ state: TriState) {
            box.state = state == .any ? .mixed : state == .set ? .on : .off
        }
        set(dateBox, criteria.dateFrom != nil || criteria.dateTo != nil)
        fromPicker.dateValue = criteria.dateFrom ?? Date()
        toPicker.dateValue = criteria.dateTo ?? Date()
        func show(_ age: Age?, _ box: NSButton, _ field: NSTextField, _ unit: NSPopUpButton) {
            set(box, age != nil)
            field.integerValue = age?.count ?? 1
            unit.selectItem(at: (age?.unit ?? .days).rawValue)
        }
        show(criteria.notOlderThan, notOlderBox, notOlderField, notOlderUnit)
        show(criteria.olderThan, olderBox, olderField, olderUnit)
        set(sizeBox, criteria.size != nil)
        sizeComparison.selectItem(at: (criteria.size?.comparison ?? .equal).rawValue)
        let size = criteria.size?.value ?? 1
        // A whole number that fits an Int64 is shown without a fraction; a saved size of 1e30 or
        // infinity is shown as it is, not trapped on.
        sizeField.stringValue = size == size.rounded() && abs(size) < 9.0e18 ? String(Int64(size)) : String(size)
        sizeUnit.selectItem(at: (criteria.size?.unit ?? .kilobytes).rawValue)
        set(attributesBox, criteria.hasAttributes)
        let states = [
            criteria.hidden, criteria.directory, criteria.symbolicLink, criteria.readOnly, criteria.executable,
            criteria.package
        ]
        for (box, state) in zip(attributeBoxes, states) {
            set(box, state)
        }
    }
}
