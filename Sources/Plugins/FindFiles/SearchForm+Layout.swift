import AppKit

/// The pages of the form and the options that are offered only while their main option is ticked.
extension SearchForm {
    /// Makes the four pages and wires the controls to the form.
    internal func build() {
        let checkboxes =
            [
                namesRegexBox, selectedBox, archivesBox, spotlightBox, findTextBox, wholeWordsBox, caseBox,
                textRegexBox, hexBox, notContainingBox, dateBox, notOlderBox, olderBox, sizeBox, attributesBox,
                duplicatesBox, sameNameBox, sameSizeBox, sameContentsBox, rulesBox
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
        buildGeneralPage()
        buildAdvancedPage()
        buildPluginsPage()
        buildLoadSavePage()
    }

    /// Sub-options are only offered while their main option is ticked.
    internal func updateEnabled() {
        func enable(_ controls: [NSControl], when box: NSButton) {
            for control in controls {
                control.isEnabled = box.state == .on
            }
        }
        enable(
            [textField, wholeWordsBox, caseBox, textRegexBox, hexBox, notContainingBox] + encodingBoxes,
            when: findTextBox
        )
        if findTextBox.state == .on {
            // Hex bytes are their own encoding, and a regular expression is not a hex string.
            for box in encodingBoxes {
                box.isEnabled = hexBox.state == .off
            }
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

    private func buildGeneralPage() {
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
                row([selectedBox, archivesBox, spotlightBox], indent: 0),
                row([label("Search in subdirectories:"), depthPopup], indent: 0),
                row([textOptions], indent: 20),
                row([notContainingBox], indent: 20)
            ]
        )
    }

    private func buildAdvancedPage() {
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
        for box in attributeBoxes {
            box.allowsMixedState = true
        }
        page(
            "Advanced",
            [
                row([dateBox, fromPicker, label("and"), toPicker], indent: 0),
                row([notOlderBox, notOlderField, notOlderUnit], indent: 0),
                row([olderBox, olderField, olderUnit], indent: 0),
                row([sizeBox, sizeComparison, sizeField, sizeUnit], indent: 0),
                row([attributesBox] + attributeBoxes[0..<3], indent: 0),
                row(Array(attributeBoxes[3...]), indent: 96),
                row([duplicatesBox, sameNameBox, sameSizeBox, sameContentsBox], indent: 0)
            ]
        )
    }

    private func buildPluginsPage() {
        combinePopup.addItems(withTitles: ["AND (all match)", "OR (any match)"])
        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 6
        page(
            "Plugins",
            [
                row([rulesBox, label("Combine with:"), combinePopup], indent: 0),
                wide(rulesStack),
                row(
                    [
                        NSButton(title: "More rules", target: self, action: #selector(moreRules)),
                        NSButton(title: "Fewer rules", target: self, action: #selector(fewerRules))
                    ],
                    indent: 0
                )
            ]
        )
        addRuleRow(nil)
    }

    private func buildLoadSavePage() {
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
        page("Load/Save", [wide(scroll), row(savedButtons, indent: 0)])
    }

    private func row(_ views: [NSView], indent: CGFloat) -> NSStackView {
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

    // MARK: Actions

    @objc
    private func optionChanged() { updateEnabled() }

    @objc
    private func submit() { onSubmit?() }

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
}
