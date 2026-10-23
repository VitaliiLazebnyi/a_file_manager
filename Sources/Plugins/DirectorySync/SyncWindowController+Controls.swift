import AFMKernel
import AppKit

/// Controls and session: what the controls say, the buttons, and redrawing what follows the session.
extension SyncWindowController {
    /// Fills the controls from the session.
    internal func pullControls() {
        leftField.stringValue = session.leftPath
        rightField.stringValue = session.rightPath
        let options = session.options
        maskField.stringValue = options.mask
        subdirsBox.state = options.subdirectories ? .on : .off
        byContentBox.state = options.byContent ? .on : .off
        ignoreDateBox.state = options.ignoreDate ? .on : .off
        asymmetricBox.state = options.asymmetric ? .on : .off
        emptyDirectoriesBox.state = options.emptyDirectories ? .on : .off
        oneHourBox.state = options.ignoreOneHourDifference ? .on : .off
        onlySelectedBox.state = session.onlySelected ? .on : .off
        onlySelectedBox.isEnabled = !session.selectedNames.isEmpty
        tolerancePopup.selectItem(at: Self.tolerances.firstIndex(of: options.toleranceSeconds) ?? 2)
        offsetField.stringValue = String(options.timeOffsetHours)
        for (button, part) in showButtons {
            button.state = session.show.contains(part) ? .on : .off
        }
    }

    /// Takes what the controls say into the session.
    internal func pushControls() {
        // A path that was typed into its field (not the one the window was opened with, nor
        // one a saved set brought) is the user's own choice of a server, if it names one.
        for (typed, known) in [
            (leftField.stringValue, session.leftPath), (rightField.stringValue, session.rightPath)
        ] {
            kernel.userTyped(location: typed, relativeTo: session.base, proposal: known)
        }
        session.leftPath = leftField.stringValue
        session.rightPath = rightField.stringValue
        var options = session.options
        options.mask =
            maskField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "*.*" : maskField.stringValue
        options.subdirectories = subdirsBox.state == .on
        options.byContent = byContentBox.state == .on
        options.ignoreDate = ignoreDateBox.state == .on
        options.asymmetric = asymmetricBox.state == .on
        options.emptyDirectories = emptyDirectoriesBox.state == .on
        options.ignoreOneHourDifference = oneHourBox.state == .on
        options.toleranceSeconds = Self.tolerances[max(0, min(2, tolerancePopup.indexOfSelectedItem))]
        options.timeOffsetHours = Int(offsetField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        session.options = options
        session.onlySelected = onlySelectedBox.state == .on
    }

    /// A box or the tolerance was changed.
    @objc
    internal func optionChanged() {
        pushControls()
    }

    /// A Show button was pressed.
    @objc
    internal func showChanged() {
        session.show = SyncShow(showButtons.filter { shown in shown.button.state == .on }.map(\.part))
    }

    /// Turns a part of the Show filter on or off, and the buttons follow.
    internal func toggleShow(_ part: SyncShow) {
        session.show.formSymmetricDifference(part)
        pullControls()
    }

    /// Return in a field: compares, unless a comparison or a run is going on.
    @objc
    internal func compareFromField() {
        if session.phase != .comparing, session.phase != .synchronizing {
            compareOrAbort()
        }
    }

    /// "Compare" compares what the controls say; "Abort" stops the comparison.
    @objc
    internal func compareOrAbort() {
        if session.phase == .comparing {
            session.cancelComparison()
        } else if session.phase != .synchronizing {
            pushControls()
            session.compare()
        }
    }

    /// "Synchronize…".
    @objc
    internal func synchronize() {
        session.synchronize()
    }

    /// "Close".
    @objc
    internal func closeWindow() {
        close()
    }

    /// Lets the user choose the left folder.
    @objc
    internal func pickLeft() {
        pickFolder(for: leftField)
    }

    /// Lets the user choose the right folder.
    @objc
    internal func pickRight() {
        pickFolder(for: rightField)
    }

    /// Puts the folder the user chooses into `field`.
    private func pickFolder(for field: NSTextField) {
        guard let window else {
            return
        }
        effects.chooseFolder(window) { url in
            if let url {
                field.stringValue = url.path
            }
        }
    }

    /// Redraws everything that follows the session.
    internal func refresh() {
        let selection = table.selectedRowIndexes
        let sameLength = table.numberOfRows == session.entries.count
        table.reloadData()
        if sameLength {
            table.selectRowIndexes(selection, byExtendingSelection: false)
        }
        statusLabel.stringValue = session.status
        compareButton.title = session.phase == .comparing ? "Abort" : "Compare"
        compareButton.isEnabled = session.phase != .synchronizing
        synchronizeButton.isEnabled = session.canSynchronize
        progressBar.isHidden = session.fraction == nil
        progressBar.doubleValue = session.fraction ?? 0
        updateIndicator()
    }

    /// Redraws just the rows whose action changed, and the Synchronize button.
    internal func refreshRows(_ rows: [Int]) {
        let positions = IndexSet(
            rows.compactMap { row in
                session.positions.indices.contains(row) && session.positions[row] >= 0 ? session.positions[row] : nil
            }
        )
        if !positions.isEmpty {
            table.reloadData(forRowIndexes: positions, columnIndexes: IndexSet(0..<table.numberOfColumns))
        }
        synchronizeButton.isEnabled = session.canSynchronize
    }

    /// Shows which subdirectory the selection (or the top of the list) is in.
    internal func updateIndicator() {
        let position = table.selectedRow >= 0 ? table.selectedRow : max(0, table.rows(in: table.visibleRect).location)
        indicatorLabel.stringValue = session.groupIndicator(atEntry: position)
    }

    /// A click on the middle column changes the row's action.
    @objc
    internal func rowClicked() {
        guard table.clickedRow >= 0, session.entries.indices.contains(table.clickedRow), table.clickedColumn >= 0,
            table.tableColumns[table.clickedColumn].identifier.rawValue == "action",
            case .row(let index) = session.entries[table.clickedRow]
        else {
            return
        }
        session.cycle(row: index)
    }

    /// A double click outside the middle column compares the row's files by content.
    @objc
    internal func rowDoubleClicked() {
        guard table.clickedColumn < 0 || table.tableColumns[table.clickedColumn].identifier.rawValue != "action" else {
            return
        }
        session.compareContents(row: selectedRows.first)
    }

    /// Selects the first row of the next or previous subdirectory, and shows its caption.
    internal func jumpToHeader(forward: Bool) {
        guard let position = session.header(after: max(0, table.selectedRow), forward: forward) else {
            return
        }
        let target = min(position + 1, session.entries.count - 1)
        table.selectRowIndexes([target], byExtendingSelection: false)
        table.scrollRowToVisible(min(position + 12, session.entries.count - 1))
        table.scrollRowToVisible(position)
    }
}
