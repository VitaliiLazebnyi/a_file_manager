import AFMKernel
import AFMShell
import AppKit

/// The menus, the buttons and the keys of the window.
extension MultiRenameWindowController {
    /// "F2 Load/save settings": the default settings, saving, deleting or loading saved ones.
    @objc
    internal func settingsChosen(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.representedObject as? String else {
            return
        }
        switch tag {
        case "default":
            loadedName = nil
            session.settings = .unchanged

        case "save":
            if let name = kernel.interaction.prompt(
                "Save settings",
                value: loadedName ?? "",
                detail: "Name of the settings:"
            ) {
                session.save(as: name)
                loadedName = name.trimmingCharacters(in: .whitespaces)
            }

        case "delete":
            deleteSavedSettings()

        default:
            let name = String(tag.dropFirst("load:".count))
            if session.load(name) {
                loadedName = name
            }
        }
        update()
    }

    /// "F10 Names": names from a file, edited by hand, or the masks again.
    @objc
    internal func namesChosen(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.representedObject as? String else {
            return
        }
        switch tag {
        case "load":
            let panel = NSOpenPanel()
            panel.message = "Load names from file: one name per line, in the order of the list"
            panel.allowsMultipleSelection = false
            presentOpenPanel(panel, toolWindow) { [weak self] response, urls in
                self?.namesFileChosen(response == .OK ? urls.first : nil)
            }

        case "edit":
            session.editNames()

        default:
            session.clearGivenNames()
        }
    }

    /// The file chosen with "Load names from file"; nil when the user chose none.
    internal func namesFileChosen(_ url: URL?) {
        if let url {
            session.loadNames(from: url, completion: nil)
        }
    }

    /// "Next step (F5)".
    @objc
    internal func nextStep() {
        session.nextStep()
    }

    /// "Start!": the fields as they are now, then the run.
    @objc
    internal func start() {
        guard !session.isBusy, toolWindow.makeFirstResponder(nil) else {
            return
        }
        session.settings = readFields()
        session.start { [weak self] _ in
            self?.update()
        }
        update()
    }

    /// "Undo".
    @objc
    internal func undo() {
        session.undo(completion: nil)
    }

    /// "Result list".
    @objc
    internal func showResultList() {
        session.showResultList()
    }

    /// "Close".
    @objc
    internal func closeWindow() {
        close()
    }

    /// F2, F5 and F10 (spec 09 › Keys), and Shift+Del to drop an entry from a field's history.
    internal func handleWindowKey(_ event: NSEvent) -> Bool {
        if Shortcut.f(2).matches(event) {
            clickPopUp(settingsPopup)
        } else if Shortcut.f(5).matches(event) {
            nextStep()
        } else if Shortcut.f(10).matches(event) {
            clickPopUp(namesPopup)
        } else if Shortcut(.forwardDelete, .shift).matches(event) || Shortcut(.backspace, .shift).matches(event) {
            return forgetHistoryEntry()
        } else {
            return false
        }
        return true
    }

    /// Shift+Up/Down move the marked items, Del takes them out of the list, 1 toggles "1x".
    internal func handleListKey(_ event: NSEvent) -> Bool {
        let selection = table.selectedRowIndexes
        if Shortcut(.upArrow, .shift).matches(event) || Shortcut(.downArrow, .shift).matches(event) {
            let moved = session.move(selection, by: Shortcut(.upArrow, .shift).matches(event) ? -1 : 1)
            table.selectRowIndexes(moved, byExtendingSelection: false)
            if let first = moved.first {
                table.scrollRowToVisible(first)
            }
        } else if Shortcut(.forwardDelete).matches(event) || Shortcut(.backspace).matches(event) {
            guard let first = selection.first else {
                return true
            }
            session.remove(selection)
            let next = min(first, session.rowCount - 1)
            if next >= 0 {
                table.selectRowIndexes([next], byExtendingSelection: false)
            }
        } else if Shortcut(.character("1")).matches(event) {
            onceBox.state = onceBox.state == .on ? .off : .on
            fieldsChanged()
        } else {
            return false
        }
        return true
    }

    /// "Delete entry": the saved settings the user picks are deleted.
    private func deleteSavedSettings() {
        let names = session.store.savedNames
        guard
            let row = kernel.interaction.pickRow(
                "Delete entry",
                rows: names,
                selected: loadedName.flatMap(names.firstIndex(of:)) ?? 0,
                button: "Delete"
            )
        else {
            return
        }
        session.deleteSaved(names[row])
        if loadedName == names[row] {
            loadedName = nil
        }
    }

    /// Shift+Del in a box with a history: the text of the box leaves the history, if it is there; false
    /// when the key is not for that.
    private func forgetHistoryEntry() -> Bool {
        guard let editor = toolWindow.firstResponder as? NSText, let combo = editor.delegate as? NSComboBox else {
            return false
        }
        let histories: [(NSComboBox, RenameStore.History)] = [
            (nameMaskBox, .nameMask), (searchBox, .search), (replaceBox, .replacement)
        ]
        guard let history = histories.first(where: { $0.0 === combo })?.1,
            session.store.history(history).contains(combo.stringValue)
        else {
            return false
        }
        session.store.forget(combo.stringValue, in: history)
        reloadHistories()
        return true
    }
}
