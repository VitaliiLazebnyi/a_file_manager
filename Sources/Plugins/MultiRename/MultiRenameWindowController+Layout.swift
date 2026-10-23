import AppKit

/// The content of the window: the four groups of fields, the menus, the list and the buttons.
extension MultiRenameWindowController {
    /// The columns of the list.
    private static let columns = [
        Column(identifier: "old", title: "Old name", width: 190), Column(identifier: "ext", title: "Ext.", width: 50),
        Column(identifier: "new", title: "New name", width: 250), Column(identifier: "size", title: "Size", width: 90),
        Column(identifier: "date", title: "Date", width: 150),
        Column(identifier: "location", title: "Location", width: 220)
    ]

    /// Makes the content of `window`.
    internal func buildContent(in window: NSWindow) {
        for combo in [nameMaskBox, searchBox, replaceBox] {
            combo.delegate = self
            combo.completes = false
            combo.numberOfVisibleItems = 12
        }
        for field in [extensionField, startField, stepField] {
            field.delegate = self
        }
        nameMaskBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        extensionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        for field in [startField, stepField] {
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        let masks = makeMaskGroups()
        let top = NSStackView(views: [masks.name, masks.ext, makeSearchGroup(), makeCounterGroup()])
        top.alignment = .top
        top.spacing = 8
        masks.name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        settingsPopup.target = self
        settingsPopup.action = #selector(settingsChosen(_:))
        namesPopup.target = self
        namesPopup.action = #selector(namesChosen(_:))
        let tools = row([NSView(), namesPopup, settingsPopup])
        let scroll = makeList()
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (control, action) in [
            (nextStepButton, #selector(nextStep)), (startButton, #selector(start)), (undoButton, #selector(undo)),
            (resultButton, #selector(showResultList)), (closeButton, #selector(closeWindow))
        ] {
            control.target = self
            control.action = action
        }
        let footer = row([statusLabel, NSView(), nextStepButton, startButton, undoButton, resultButton, closeButton])
        let stack = NSStackView(views: [top, tools, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for part in [top, tools, scroll, footer] {
            part.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
        window.initialFirstResponder = nameMaskBox
    }

    /// The groups of the two masks with their insert buttons.
    private func makeMaskGroups() -> (name: NSBox, ext: NSBox) {
        let nameButtons = [
            button("[N] Name", #selector(insertName), tip: ""),
            button("[N#-#] Range", #selector(insertNameRange), tip: ""),
            button("[C] Counter", #selector(insertNameCounter), tip: ""),
            button("[YMD] Date", #selector(insertDate), tip: ""),
            button("[hms] Time", #selector(insertTime), tip: ""),
            button("+", #selector(showMoreFields(_:)), tip: "More fields"),
            button("#", #selector(showRangeFields(_:)), tip: "Ranges of other fields")
        ]
        let extensionButtons = [
            button("[E] Ext.", #selector(insertExtension), tip: ""),
            button("[E#-#] Range", #selector(insertExtensionRange), tip: ""),
            button("[C] Counter", #selector(insertExtensionCounter), tip: "")
        ]
        maskOnlyButtons = nameButtons + extensionButtons
        let nameGroup = box(
            "Rename mask: file name",
            [nameMaskBox, row(Array(nameButtons[0..<4])), row(Array(nameButtons[4...]))]
        )
        let extensionGroup = box(
            "Extension",
            [extensionField, row(Array(extensionButtons[0..<2])), extensionButtons[2]]
        )
        return (nameGroup, extensionGroup)
    }

    /// The group of Search & Replace and the case conversion.
    private func makeSearchGroup() -> NSBox {
        for (check, tip) in [
            (caseBox, "Respect upper/lowercase"), (onceBox, "Replace only the first occurrence (key 1 in the list)"),
            (extensionBox, "Also search the extension"), (regexBox, "Search for is a regular expression"),
            (substituteBox, "Replace the whole name by Replace with")
        ] {
            check.target = self
            check.action = #selector(optionChanged)
            check.toolTip = tip
        }
        for letterCase in LetterCase.allCases {
            letterCasePopup.addItem(withTitle: letterCase.title)
        }
        letterCasePopup.target = self
        letterCasePopup.action = #selector(optionChanged)
        let searchGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Search for:"), searchBox],
            [NSTextField(labelWithString: "Replace with:"), replaceBox]
        ])
        searchGrid.column(at: 0).xPlacement = .trailing
        searchGrid.rowSpacing = 6
        return box(
            "Search & Replace",
            [
                searchGrid, row([caseBox, onceBox, extensionBox, regexBox, substituteBox]),
                row([NSTextField(labelWithString: "Upper/lowercase:"), letterCasePopup])
            ]
        )
    }

    /// The group "Define counter".
    private func makeCounterGroup() -> NSBox {
        for stepper in [startStepper, stepStepper] {
            stepper.minValue = -1_000_000_000
            stepper.maxValue = 1_000_000_000
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))
        }
        digitsPopup.addItems(withTitles: (1...10).map(String.init) + ["a (automatic)"])
        digitsPopup.target = self
        digitsPopup.action = #selector(optionChanged)
        let counterGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Start at:"), row([startField, startStepper])],
            [NSTextField(labelWithString: "Step by:"), row([stepField, stepStepper])],
            [NSTextField(labelWithString: "Digits:"), digitsPopup]
        ])
        counterGrid.column(at: 0).xPlacement = .trailing
        counterGrid.rowSpacing = 6
        return box("Define counter [C]", [counterGrid])
    }

    /// The list of the items in its scroll view.
    private func makeList() -> NSScrollView {
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 18
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.registerForDraggedTypes([Self.rowType])
        table.onKey = { [weak self] event in self?.handleListKey(event) == true }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    private func box(_ title: String, _ rows: [NSView]) -> NSBox {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let box = NSBox()
        box.title = title
        box.contentView = stack
        box.contentViewMargins = NSSize(width: 8, height: 6)
        return box
    }

    private func button(_ title: String, _ action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = tip.isEmpty ? nil : tip
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 6
        return stack
    }

    @objc
    private func optionChanged() {
        fieldsChanged()
    }

    @objc
    private func stepperChanged(_ sender: NSStepper) {
        (sender === startStepper ? startField : stepField).stringValue = String(sender.integerValue)
        fieldsChanged()
    }
}
