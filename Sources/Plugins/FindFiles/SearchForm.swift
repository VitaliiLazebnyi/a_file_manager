import AFMKernel
import AppKit

/// The four tabs of the Find Files window (spec 09 › General tab, Advanced tab, Plugins tab,
/// Load/Save tab).
///
/// It only holds controls: `settings` reads them out as a `SearchSettings` and writes one back, and
/// that is all the rest of the window knows of them. Main thread only.
@MainActor
internal final class SearchForm: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    internal let tabView = NSTabView()
    internal let searchForField = NSComboBox()
    /// Enter in one of the text fields.
    internal var onSubmit: (() -> Void)?
    /// Shows an open panel as a sheet of the window and hands on the button and the locations
    /// chosen.
    ///
    /// The program shows the real panel; a test answers in its place.
    internal var presentOpenPanel:
        (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse, [URL]) -> Void) -> Void = {
            panel,
            window,
            done in panel.beginSheetModal(for: window) { done($0, panel.urls) }
        }

    private let fields: [SearchField]
    private let store: SearchStore
    private let ui: any UserInteraction

    // General
    private let searchInField = NSComboBox()
    /// What the program put into "Search in" last (the panel's folder, a saved search): a
    /// field that says something else was typed, or picked, by the user.
    internal private(set) var placedSearchIn: String?
    private let namesRegexBox = SearchForm.box("RegEx")
    private let selectedBox = SearchForm.box("Only search in selected directories/files")
    private let archivesBox = SearchForm.box("Search archives")
    private let spotlightBox = SearchForm.box("Spotlight (local volumes)")
    private let depthPopup = NSPopUpButton()
    private let findTextBox = SearchForm.box("Find text:")
    private let textField = NSComboBox()
    private let wholeWordsBox = SearchForm.box("Whole words only")
    private let caseBox = SearchForm.box("Case sensitive")
    private let textRegexBox = SearchForm.box("RegEx")
    private let hexBox = SearchForm.box("Hex")
    private let notContainingBox = SearchForm.box("Find files NOT containing the text")
    private let encodingBoxes = TextEncoding.allCases.map { SearchForm.box($0.title) }

    // Advanced
    private let dateBox = SearchForm.box("Date between:")
    private let fromPicker = NSDatePicker()
    private let toPicker = NSDatePicker()
    private let notOlderBox = SearchForm.box("Not older than:")
    private let notOlderField = NSTextField(string: "1")
    private let notOlderUnit = NSPopUpButton()
    private let olderBox = SearchForm.box("Older than:")
    private let olderField = NSTextField(string: "1")
    private let olderUnit = NSPopUpButton()
    private let sizeBox = SearchForm.box("File size:")
    private let sizeComparison = NSPopUpButton()
    private let sizeField = NSTextField(string: "1")
    private let sizeUnit = NSPopUpButton()
    private let attributesBox = SearchForm.box("Attributes:")
    private let attributeBoxes = ["Hidden", "Directory", "Symbolic link", "Read only", "Executable", "Package"]
        .map {
            SearchForm.box($0)
        }
    private let duplicatesBox = SearchForm.box("Find duplicate files:")
    private let sameNameBox = SearchForm.box("same name")
    private let sameSizeBox = SearchForm.box("same size")
    private let sameContentsBox = SearchForm.box("same contents")

    // Plugins
    @MainActor
    private struct RuleRow {
        let field: NSPopUpButton
        let comparison: NSPopUpButton
        let value: NSTextField
        let view: NSStackView

        init(view: NSStackView) {
            (field, comparison, value) = (NSPopUpButton(), NSPopUpButton(), NSTextField())
            self.view = view
        }
    }
    private let rulesBox = SearchForm.box("Search in plugins (columns):")
    private let combinePopup = NSPopUpButton()
    private let rulesStack = NSStackView()
    private var ruleRows: [RuleRow] = []

    // Load/Save
    private let savedTable = NSTableView()
    private var saved: [SavedSearch] = []
    private var savedButtons: [NSButton] = []

    private static func box(_ title: String) -> NSButton {
        NSButton(checkboxWithTitle: title, target: nil, action: nil)
    }

    internal init(fields: [SearchField], store: SearchStore, ui: any UserInteraction) {
        self.fields = fields
        self.store = store
        self.ui = ui
        super.init()
        build()
        settings = SearchSettings()
        reloadSaved()
        reloadHistories()
    }

    // MARK: Layout

    private func row(_ views: [NSView], indent: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets.left = indent
        return stack
    }

    private func page(_ title: String, _ rows: [NSView]) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for view in rows where view.contentHuggingPriority(for: .horizontal) < .defaultLow {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        let item = NSTabViewItem()
        item.label = title
        item.view = stack
        tabView.addTabViewItem(item)
    }

    /// A row that takes the whole width of its page.
    private func wide(_ view: NSView) -> NSView {
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return view
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func build() {
        let checkboxes =
            [
                namesRegexBox, selectedBox, archivesBox, spotlightBox, findTextBox, wholeWordsBox, caseBox,
                textRegexBox, hexBox,
                notContainingBox, dateBox, notOlderBox, olderBox, sizeBox, attributesBox, duplicatesBox, sameNameBox,
                sameSizeBox,
                sameContentsBox, rulesBox
            ] + encodingBoxes + attributeBoxes
        for box in checkboxes {
            box.target = self
            box.action = #selector(optionChanged)
        }
        for field in [searchForField, searchInField, textField] {
            field.target = self
            field.action = #selector(submit)
            field.completes = true
            field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        }
        searchForField.placeholderString = "*.txt report | *.bak  (empty = all files)"
        searchInField.placeholderString = "start directories, separated by ;"
        textField.placeholderString = "text inside the files"

        // General
        depthPopup.addItems(
            withTitles: ["all (unlimited depth)", "current dir only"] + (1...10).map { "\($0) level(s)" }
        )
        let browse = NSButton(title: ">>", target: self, action: #selector(browse))
        let grid = NSGridView(views: [
            [label("Search for:"), searchForField, namesRegexBox],
            [label("Search in:"), searchInField, browse],
            [findTextBox, textField, NSView()]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 7
        let textOptions = NSGridView(views: [
            [wholeWordsBox, encodingBoxes[0]],
            [caseBox, encodingBoxes[1]],
            [textRegexBox, encodingBoxes[2]],
            [hexBox, encodingBoxes[3]]
        ])
        textOptions.rowSpacing = 4
        textOptions.columnSpacing = 24
        page(
            "General",
            [
                wide(grid),
                row([selectedBox, archivesBox, spotlightBox]),
                row([label("Search in subdirectories:"), depthPopup]),
                row([textOptions], indent: 20),
                row([notContainingBox], indent: 20)
            ]
        )

        // Advanced
        for picker in [fromPicker, toPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.dateValue = Date()
        }
        for popup in [notOlderUnit, olderUnit] {
            popup.addItems(withTitles: Age.Unit.allCases.map(\.title))
            popup.selectItem(at: Age.Unit.days.rawValue)
        }
        sizeComparison.addItems(withTitles: SizeRule.Comparison.allCases.map(\.title))
        sizeUnit.addItems(withTitles: SizeRule.Unit.allCases.map(\.title))
        for field in [notOlderField, olderField, sizeField] {
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        attributeBoxes.forEach { $0.allowsMixedState = true }
        page(
            "Advanced",
            [
                row([dateBox, fromPicker, label("and"), toPicker]),
                row([notOlderBox, notOlderField, notOlderUnit]),
                row([olderBox, olderField, olderUnit]),
                row([sizeBox, sizeComparison, sizeField, sizeUnit]),
                row([attributesBox] + attributeBoxes[0..<3]),
                row(Array(attributeBoxes[3...]), indent: 96),
                row([duplicatesBox, sameNameBox, sameSizeBox, sameContentsBox])
            ]
        )

        // Plugins
        combinePopup.addItems(withTitles: ["AND (all match)", "OR (any match)"])
        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 6
        page(
            "Plugins",
            [
                row([rulesBox, label("Combine with:"), combinePopup]),
                wide(rulesStack),
                row([
                    NSButton(title: "More rules", target: self, action: #selector(moreRules)),
                    NSButton(title: "Fewer rules", target: self, action: #selector(fewerRules))
                ])
            ]
        )
        addRuleRow()

        // Load/Save
        for (identifier, title, width) in [("name", "Previous searches", 180.0), ("summary", "Settings", 360.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            savedTable.addTableColumn(column)
        }
        savedTable.dataSource = self
        savedTable.delegate = self
        savedTable.rowHeight = 18
        savedTable.target = self
        savedTable.doubleAction = #selector(loadSaved)
        let scroll = NSScrollView()
        scroll.documentView = savedTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        savedButtons = [
            NSButton(title: "Load", target: self, action: #selector(loadSaved)),
            NSButton(title: "Save", target: self, action: #selector(saveCurrent)),
            NSButton(title: "Delete", target: self, action: #selector(deleteSaved))
        ]
        page("Load/Save", [wide(scroll), row(savedButtons)])
    }

    private func addRuleRow(_ rule: FieldRule? = nil) {
        let stack = NSStackView()
        stack.spacing = 8
        let row = RuleRow(view: stack)
        row.field.addItems(withTitles: fields.map(\.title))
        row.comparison.addItems(withTitles: FieldRule.Operator.allCases.map(\.title))
        row.value.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        [row.field, row.comparison, row.value].forEach(stack.addArrangedSubview)
        if let rule {
            row.field.selectItem(at: fields.firstIndex { $0.id == rule.field } ?? 0)
            row.comparison.selectItem(at: rule.comparison.rawValue)
            row.value.stringValue = rule.value
        }
        ruleRows.append(row)
        rulesStack.addArrangedSubview(stack)
        updateEnabled()
    }

    private func remove(_ row: RuleRow) {
        rulesStack.removeArrangedSubview(row.view)
        row.view.removeFromSuperview()
    }

    /// Sub-options are only offered while their main option is ticked.
    private func updateEnabled() {
        func enable(_ controls: [NSControl], when box: NSButton) {
            controls.forEach { $0.isEnabled = box.state == .on }
        }
        enable(
            [textField, wholeWordsBox, caseBox, textRegexBox, hexBox, notContainingBox] + encodingBoxes,
            when: findTextBox
        )
        if findTextBox.state == .on {
            // Hex bytes are their own encoding, and a regular expression is not a hex string.
            encodingBoxes.forEach { $0.isEnabled = hexBox.state == .off }
            textRegexBox.isEnabled = hexBox.state == .off
            hexBox.isEnabled = textRegexBox.state == .off
        }
        enable([fromPicker, toPicker], when: dateBox)
        enable([notOlderField, notOlderUnit], when: notOlderBox)
        enable([olderField, olderUnit], when: olderBox)
        enable([sizeComparison, sizeField, sizeUnit], when: sizeBox)
        enable(attributeBoxes, when: attributesBox)
        enable([sameNameBox, sameSizeBox, sameContentsBox], when: duplicatesBox)
        enable(
            [combinePopup] + ruleRows.flatMap { [$0.field, $0.comparison, $0.value] as [NSControl] },
            when: rulesBox
        )
        let hasSaved = saved.indices.contains(savedTable.selectedRow)
        savedButtons.first?.isEnabled = hasSaved
        savedButtons.last?.isEnabled = hasSaved
    }

    /// Whether the panel has marked items, which "Only search in selected" needs.
    internal func setSelectionAvailable(_ available: Bool) {
        selectedBox.isEnabled = available
        if !available { selectedBox.state = .off }
    }

    // MARK: Values

    internal var settings: SearchSettings {
        get {
            func isOn(_ box: NSButton) -> Bool { box.state == .on }
            func tri(_ box: NSButton) -> TriState {
                isOn(attributesBox) ? (box.state == .mixed ? .any : box.state == .on ? .yes : .no) : .any
            }
            var settings = SearchSettings()
            settings.searchFor = searchForField.stringValue
            settings.searchIn = searchInField.stringValue
            settings.namesAreRegex = isOn(namesRegexBox)
            settings.onlySelected = isOn(selectedBox)
            settings.searchArchives = isOn(archivesBox)
            settings.useSpotlight = isOn(spotlightBox)
            settings.depth = depthPopup.indexOfSelectedItem <= 0 ? nil : depthPopup.indexOfSelectedItem - 1
            settings.findText = isOn(findTextBox)
            settings.text = textField.stringValue
            settings.caseSensitive = isOn(caseBox)
            let encodings = zip(TextEncoding.allCases, encodingBoxes).filter { isOn($0.1) }.map(\.0)
            settings.textOptions = TextSearchOptions(
                wholeWords: isOn(wholeWordsBox),
                regex: isOn(textRegexBox),
                hex: isOn(hexBox),
                notContaining: isOn(notContainingBox),
                encodings: encodings.isEmpty ? [.utf8] : encodings
            )
            let calendar = Calendar.current
            if isOn(dateBox) {
                settings.criteria.dateFrom = calendar.startOfDay(for: fromPicker.dateValue)
                // The whole last day counts.
                settings.criteria.dateTo = calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: calendar.startOfDay(for: toPicker.dateValue)
                )?
                .addingTimeInterval(
                    -1
                )
            }
            func age(_ box: NSButton, _ field: NSTextField, _ unit: NSPopUpButton) -> Age? {
                isOn(box)
                    ? Age(max(field.integerValue, 0), Age.Unit(rawValue: unit.indexOfSelectedItem) ?? .days) : nil
            }
            settings.criteria.notOlderThan = age(notOlderBox, notOlderField, notOlderUnit)
            settings.criteria.olderThan = age(olderBox, olderField, olderUnit)
            if isOn(sizeBox) {
                settings.criteria.size = SizeRule(
                    SizeRule.Comparison(rawValue: sizeComparison.indexOfSelectedItem) ?? .equal,
                    Double(sizeField.stringValue.replacingOccurrences(of: ",", with: ".")) ?? 0,
                    SizeRule.Unit(rawValue: sizeUnit.indexOfSelectedItem) ?? .bytes
                )
            }
            (settings.criteria.hidden, settings.criteria.directory, settings.criteria.symbolicLink) =
                (tri(attributeBoxes[0]), tri(attributeBoxes[1]), tri(attributeBoxes[2]))
            (settings.criteria.readOnly, settings.criteria.executable, settings.criteria.package) =
                (tri(attributeBoxes[3]), tri(attributeBoxes[4]), tri(attributeBoxes[5]))
            settings.duplicates = DuplicateOptions(
                isEnabled: isOn(duplicatesBox),
                sameName: isOn(sameNameBox),
                sameSize: isOn(sameSizeBox),
                sameContents: isOn(sameContentsBox)
            )
            let rules = ruleRows.compactMap { row -> FieldRule? in
                guard fields.indices.contains(row.field.indexOfSelectedItem), !row.value.stringValue.isEmpty else {
                    return nil
                }
                return FieldRule(
                    fields[row.field.indexOfSelectedItem].id,
                    FieldRule.Operator(rawValue: row.comparison.indexOfSelectedItem) ?? .contains,
                    row.value.stringValue
                )
            }
            settings.fieldRules = FieldRules(
                isEnabled: isOn(rulesBox),
                matchAll: combinePopup.indexOfSelectedItem == 0,
                rules: rules
            )
            return settings
        }
        set {
            func set(_ box: NSButton, _ isOn: Bool) { box.state = isOn ? .on : .off }
            func set(_ box: NSButton, _ state: TriState) {
                box.state = state == .any ? .mixed : state == .yes ? .on : .off
            }
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
            let criteria = newValue.criteria
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
            for (box, state) in zip(
                attributeBoxes,
                [
                    criteria.hidden, criteria.directory, criteria.symbolicLink, criteria.readOnly,
                    criteria.executable, criteria.package
                ]
            ) { set(box, state) }
            set(duplicatesBox, newValue.duplicates.isEnabled)
            set(sameNameBox, newValue.duplicates.sameName)
            set(sameSizeBox, newValue.duplicates.sameSize)
            set(sameContentsBox, newValue.duplicates.sameContents)
            set(rulesBox, newValue.fieldRules.isEnabled)
            combinePopup.selectItem(at: newValue.fieldRules.matchAll ? 0 : 1)
            while let row = ruleRows.popLast() { remove(row) }
            newValue.fieldRules.rules.forEach { addRuleRow($0) }
            if ruleRows.isEmpty { addRuleRow() }
            updateEnabled()
        }
    }

    /// Adds what the fields hold to their histories (spec 09 › "Search for").
    internal func rememberHistory(limit: Int) {
        store.remember(searchForField.stringValue, in: .searchFor, limit: limit)
        store.remember(searchInField.stringValue, in: .searchIn, limit: limit)
        if findTextBox.state == .on { store.remember(textField.stringValue, in: .text, limit: limit) }
        reloadHistories()
    }

    private func reloadHistories() {
        for (field, kind) in [
            (searchForField, SearchStore.Field.searchFor), (searchInField, .searchIn), (textField, .text)
        ] {
            field.removeAllItems()
            field.addItems(withObjectValues: store.history(kind))
        }
    }

    // MARK: Actions

    @objc
    private func optionChanged() { updateEnabled() }
    @objc
    private func submit() { onSubmit?() }
    @objc
    private func moreRules() { addRuleRow() }

    @objc
    private func fewerRules() {
        if ruleRows.count > 1, let row = ruleRows.popLast() { remove(row) }
    }

    /// `>>`: choosing start directories on the local disks; several may be picked.
    @objc
    private func browse() {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles, panel.allowsMultipleSelection) = (true, false, true)
        panel.prompt = "Search here"
        guard let window = tabView.window else {
            return
        }
        presentOpenPanel(panel, window) { [weak self] response, urls in
            guard response == .OK, !urls.isEmpty else {
                return
            }
            self?.searchInField.stringValue = urls.map(\.path).joined(separator: ";")
        }
    }

    // MARK: Saved searches

    private func reloadSaved() {
        saved = store.searches
        savedTable.reloadData()
        updateEnabled()
    }

    @objc
    private func loadSaved() {
        guard saved.indices.contains(savedTable.selectedRow) else {
            return
        }
        settings = saved[savedTable.selectedRow].settings.loaded(over: settings)
        tabView.selectTabViewItem(at: 0)
    }

    @objc
    private func saveCurrent() {
        let proposal =
            saved.indices.contains(savedTable.selectedRow)
            ? saved[savedTable.selectedRow].name : searchForField.stringValue
        guard let name = ui.prompt("Save search as:", value: proposal)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else { return }
        store.save(SavedSearch(name: name, settings: settings))
        reloadSaved()
    }

    @objc
    private func deleteSaved() {
        guard saved.indices.contains(savedTable.selectedRow) else {
            return
        }
        store.delete(named: saved[savedTable.selectedRow].name)
        reloadSaved()
    }

    internal func numberOfRows(in _: NSTableView) -> Int { saved.count }

    internal func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? {
                let label = NSTextField(labelWithString: "")
                label.identifier = identifier
                label.lineBreakMode = .byTruncatingTail
                return label
            }()
        cell.stringValue = identifier.rawValue == "name" ? saved[row].name : saved[row].settings.summary
        return cell
    }

    internal func tableViewSelectionDidChange(_: Notification) {
        updateEnabled()
    }
}
