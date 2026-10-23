import AFMKernel
import AppKit

/// Controls and session: the options, the files, the font, moving between differences and searching.
extension CompareWindowController {
    /// Sets the controls to what the session holds.
    internal func pullControls() {
        leftField.stringValue = session.displayPath(.left)
        rightField.stringValue = session.displayPath(.right)
        binaryBox.state = session.forceBinary ? .on : .off
        bytesPopup.selectItem(at: CompareSettingsKey.bytesPerLineChoices.firstIndex(of: session.bytesPerLine) ?? 1)
        caseBox.state = session.options.ignoreCase ? .on : .off
        spacesBox.state = session.options.ignoreRepeatedSpaces ? .on : .off
        endingsBox.state = session.options.ignoreLineEndings ? .on : .off
        verticalBox.state = split.isVertical ? .off : .on
        editBox.state = session.isEditing ? .on : .off
    }

    /// A box or the bytes popup was changed: the layout, edit mode, the mode or the options follow.
    @objc
    internal func optionChanged(_ sender: NSControl) {
        if sender === verticalBox {
            split.isVertical = verticalBox.state != .on
            settings.set(verticalBox.state == .on, forKey: CompareSettingsKey.vertical)
            split.adjustSubviews()
        } else if sender === editBox {
            session.setEditing(editBox.state == .on)
            pullControls()
        } else if sender === binaryBox {
            // Text and hex views are built from the files, so the files are read again.
            whenChangesAreSettled { [self] in
                session.forceBinary = binaryBox.state == .on
                jumpsToFirstDifference = true
                session.compare()
            }
            pullControls()
        } else {
            session.options = DiffOptions(
                ignoreCase: caseBox.state == .on,
                ignoreRepeatedSpaces: spacesBox.state == .on,
                ignoreLineEndings: endingsBox.state == .on
            )
            session.bytesPerLine =
                CompareSettingsKey.bytesPerLineChoices[max(0, min(3, bytesPopup.indexOfSelectedItem))]
            session.optionsChanged()
        }
    }

    /// Runs `action` unless there are unsaved changes the user wants to keep working on
    /// (spec 09 › Edit mode and saving: closing or re-comparing asks).
    internal func whenChangesAreSettled(_ action: @escaping () -> Void) {
        guard session.hasUnsavedChanges else {
            action()
            return
        }
        let choice = kernel.interaction.pick(
            "Save the changes?",
            detail: "The compared files were edited.",
            [("Save", 0), ("Don't Save", 1), ("Cancel", 2)],
            fallback: 2,
            style: .warning
        )
        if choice == 0 {
            session.save { saved in
                if saved {
                    action()
                }
            }
        } else if choice == 1 {
            action()
        }
    }

    /// Compares the files the two fields name.
    @objc
    internal func compare() {
        whenChangesAreSettled { [self] in
            let fileSystems = kernel.fileSystems
            @MainActor
            func location(_ field: NSTextField) -> URL? {
                let text = field.stringValue.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : fileSystems.location(from: text, relativeTo: base)
            }
            // A file whose address was typed into its field: the user's own choice of that server.
            kernel.userTyped(location: leftField.stringValue, relativeTo: base, proposal: session.displayPath(.left))
            kernel.userTyped(location: rightField.stringValue, relativeTo: base, proposal: session.displayPath(.right))
            session.leftURL = location(leftField)
            session.rightURL = location(rightField)
            jumpsToFirstDifference = true
            resyncMarks = (nil, nil)
            session.compare()
        }
    }

    /// Lets the user choose the left file.
    @objc
    internal func pickLeft() {
        pickFile(for: leftField)
    }

    /// Lets the user choose the right file.
    @objc
    internal func pickRight() {
        pickFile(for: rightField)
    }

    /// Puts the file the user chooses into `field`, and compares once both fields name a file.
    private func pickFile(for field: NSTextField) {
        effects.chooseFile(toolWindow) { [weak self] url in
            guard let self, let url else {
                return
            }
            field.stringValue = url.path
            if !leftField.stringValue.isEmpty, !rightField.stringValue.isEmpty {
                compare()
            }
        }
    }

    /// Shows the font panel, which sends `changeFont` back here.
    @objc
    internal func chooseFont() {
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        effects.showFontPanel(self)
    }

    /// Called by the font panel.
    @objc
    internal func changeFont(_ sender: NSFontManager?) {
        guard let sender else {
            return
        }
        font = sender.convert(font)
        settings.set(font.fontName, forKey: CompareSettingsKey.fontName)
        settings.set(String(Double(font.pointSize)), forKey: CompareSettingsKey.fontSize)
        refresh()
    }

    /// Redraws everything that follows the session.
    internal func refresh() {
        let selection = leftTable.selectedRowIndexes
        let rowHeight = ceil(font.ascender - font.descender + font.leading) + 3
        let characterWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        isMirroring = true
        for table in [leftTable, rightTable] {
            table.rowHeight = rowHeight
            table.tableColumns[0].width = characterWidth * 9
            table.tableColumns[1].width = min(30_000, max(400, CGFloat(session.width + 4) * characterWidth))
            table.reloadData()
            table.selectRowIndexes(
                selection.filteredIndexSet { row in row < session.rowCount },
                byExtendingSelection: false
            )
        }
        isMirroring = false
        statusLabel.stringValue = session.status
        let isText = !session.isBinary && session.rowCount > 0
        editBox.isEnabled = isText || session.isEditing
        for button in editButtons {
            button.isHidden = !session.isEditing
        }
        editButtons.last?.isEnabled = session.canUndo
        saveButton.isEnabled = session.hasUnsavedChanges
        for button in differenceButtons {
            button.isEnabled = !session.blocks.isEmpty
        }
        bytesPopup.isHidden = !session.isBinary
        for box in [caseBox, spacesBox, endingsBox] {
            box.isEnabled = !session.isBinary
        }
        if jumpsToFirstDifference, session.phase == .ready, session.rowCount > 0 {
            jumpsToFirstDifference = false
            if let first = session.blocks.first?.lowerBound {
                go(toRow: first)
            }
        }
    }

    /// Selects a row in both panes and shows it near the top.
    ///
    /// Rows come from the session's current rows: a search that the rows have changed under is
    /// dropped by the session.
    private func go(toRow row: Int) {
        leftTable.selectRowIndexes([row], byExtendingSelection: false)
        let top = leftTable.rect(ofRow: max(0, row - 3)).minY
        for table in [leftTable, rightTable] {
            table.scroll(NSPoint(x: table.visibleRect.minX, y: top))
        }
    }

    /// Goes to the next difference (Option+Down); beeps when there is none.
    @objc
    internal func nextDifference() {
        if let row = session.difference(from: currentRow, forward: true) {
            go(toRow: row)
        } else {
            effects.beep()
        }
    }

    /// Goes to the previous difference (Option+Up); beeps when there is none.
    @objc
    internal func previousDifference() {
        if let row = session.difference(from: currentRow, forward: false) {
            go(toRow: row)
        } else {
            effects.beep()
        }
    }

    /// Searches forward for the text of the search field (Return in the field).
    @objc
    internal func searchNext() {
        search(forward: true)
    }

    /// Searches for the text of the search field from the cursor on; with an empty field, puts the focus there.
    internal func search(forward: Bool) {
        let needle = searchField.stringValue
        guard !needle.isEmpty else {
            window?.makeFirstResponder(searchField)
            return
        }
        statusLabel.stringValue = "Searching for \"\(needle)\"…"
        session.find(needle, from: currentRow, forward: forward) { [weak self] row in
            self?.searchEnded(needle, at: row)
        }
    }

    /// Shows the row the search found, or says it found none.
    private func searchEnded(_ needle: String, at row: Int?) {
        if let row {
            statusLabel.stringValue = session.status
            go(toRow: row)
        } else {
            statusLabel.stringValue = "\"\(needle)\" was not found."
            effects.beep()
        }
    }

    /// One pane scrolled: the other follows.
    @objc
    internal func paneScrolled(_ notification: Notification) {
        guard !isMirroring, let moved = notification.object as? NSClipView else {
            return
        }
        isMirroring = true
        for table in [leftTable, rightTable] {
            guard let clip = table.enclosingScrollView?.contentView, clip !== moved,
                clip.bounds.origin != moved.bounds.origin
            else {
                continue
            }
            clip.scroll(to: moved.bounds.origin)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        isMirroring = false
    }

    /// The selection of one pane changed: the other pane selects the same rows.
    internal func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isMirroring, let changed = notification.object as? NSTableView else {
            return
        }
        isMirroring = true
        let other = changed === leftTable ? rightTable : leftTable
        other.selectRowIndexes(changed.selectedRowIndexes, byExtendingSelection: false)
        isMirroring = false
    }
}
