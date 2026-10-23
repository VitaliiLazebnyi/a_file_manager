import AFMKernel
import AppKit

/// The histories of the text fields, and the box that needs a selection.
extension SearchForm {
    /// Whether the panel has marked items, which "Only search in selected" needs.
    internal func setSelectionAvailable(_ available: Bool) {
        selectedBox.isEnabled = available
        if !available {
            selectedBox.state = .off
        }
    }

    /// Adds what the fields hold to their histories (spec 09 › "Search for").
    internal func rememberHistory(limit: Int) {
        store.remember(searchForField.stringValue, in: .searchFor, limit: limit)
        store.remember(searchInField.stringValue, in: .searchIn, limit: limit)
        if findTextBox.state == .on {
            store.remember(textField.stringValue, in: .text, limit: limit)
        }
        reloadHistories()
    }

    /// Fills the lists of the text fields from their histories.
    internal func reloadHistories() {
        for (field, kind) in [
            (searchForField, SearchStore.Field.searchFor), (searchInField, .searchIn), (textField, .text)
        ] {
            field.removeAllItems()
            field.addItems(withObjectValues: store.history(kind))
        }
    }
}
