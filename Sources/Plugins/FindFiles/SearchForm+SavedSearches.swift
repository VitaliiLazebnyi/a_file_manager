import AFMKernel
import AppKit

/// The Load/Save tab: the list of saved searches and its buttons.
extension SearchForm {
    /// Reads the saved searches into the list again.
    internal func reloadSaved() {
        saved = store.searches
        savedTable.reloadData()
        updateEnabled()
    }

    /// "Load" (or a double click): the chosen search fills the form, which shows its first tab.
    @objc
    internal func loadSaved() {
        guard saved.indices.contains(savedTable.selectedRow) else {
            return
        }
        settings = saved[savedTable.selectedRow].settings.loaded(over: settings)
        tabView.selectTabViewItem(at: 0)
    }

    /// "Save": the form is saved under a name the user gives, the chosen search's by default.
    @objc
    internal func saveCurrent() {
        let proposal =
            saved.indices.contains(savedTable.selectedRow)
            ? saved[savedTable.selectedRow].name : searchForField.stringValue
        guard let name = interaction.prompt("Save search as:", value: proposal)?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty
        else {
            return
        }
        store.save(SavedSearch(name: name, settings: settings))
        reloadSaved()
    }

    /// "Delete": the chosen search is deleted.
    @objc
    internal func deleteSaved() {
        guard saved.indices.contains(savedTable.selectedRow) else {
            return
        }
        store.delete(named: saved[savedTable.selectedRow].name)
        reloadSaved()
    }

    /// One row per saved search.
    internal func numberOfRows(in _: NSTableView) -> Int { saved.count }

    /// The name or the summary of a saved search, by column.
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

    /// Load and Delete are offered while a search is chosen.
    internal func tableViewSelectionDidChange(_: Notification) {
        updateEnabled()
    }
}
