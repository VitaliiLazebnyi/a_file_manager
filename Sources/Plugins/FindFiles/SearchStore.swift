public import AFMKernel
import Foundation

/// The saved searches and the histories of the window's fields, kept in the plugin's corner
/// of the settings (spec 09 › What is remembered).
///
/// Main thread only.
public final class SearchStore {
    /// A field of the window that has a history; the raw value names it in the settings.
    public enum Field: String {
        /// "Search for".
        case searchFor = "searchFor"
        /// "Search in".
        case searchIn = "searchIn"
        /// "Find text".
        case text = "text"
    }

    private static let searchesKey = "searches"

    private let settings: any SettingsStore

    /// In name order.
    ///
    /// A search that cannot be read is left out; the others stay.
    public var searches: [SavedSearch] {
        (settings.value([StoredElement<SavedSearch>].self, forKey: Self.searchesKey) ?? [])
            .compactMap(\.value)
            .sorted { Sorter.compare($0.name, $1.name) == .orderedAscending }
    }

    /// The store in the `findFiles` corner of `settings`.
    public init(settings: any SettingsStore) {
        self.settings = settings.scoped(to: "findFiles")
    }

    /// Saves under a name; a search of that name is replaced.
    public func save(_ search: SavedSearch) {
        settings.set(
            searches.filter { $0.name.caseInsensitiveCompare(search.name) != .orderedSame } + [search],
            forKey: Self.searchesKey
        )
    }

    /// Deletes the search of that name (case ignored), if there is one.
    public func delete(named name: String) {
        settings.set(
            searches.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame },
            forKey: Self.searchesKey
        )
    }

    /// What was typed into a field before, newest first.
    public func history(_ field: Field) -> [String] {
        settings.value([String].self, forKey: "history." + field.rawValue) ?? []
    }

    /// Puts an entry at the front of a field's history, which keeps `limit` entries.
    public func remember(_ text: String, in field: Field, limit: Int = 20) {
        guard !text.isEmpty else {
            return
        }
        settings.set(
            Array(([text] + history(field).filter { $0 != text }).prefix(max(limit, 1))),
            forKey: "history." + field.rawValue
        )
    }

    /// Takes an entry out of a field's history.
    public func forget(_ text: String, in field: Field) {
        settings.set(history(field).filter { $0 != text }, forKey: "history." + field.rawValue)
    }

    /// The saved search of that name (case ignored); nil when there is none.
    public subscript(name: String) -> SavedSearch? {
        searches.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    deinit {
        // Nothing to release.
    }
}
