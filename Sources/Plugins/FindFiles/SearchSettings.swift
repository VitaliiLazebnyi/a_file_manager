public import AFMKernel
public import Foundation

/// Everything the Find Files window holds in its four tabs, as the user entered it. This is
/// what a saved search stores and what a search is made from (spec 09 › Load/Save tab).
public struct SearchSettings: Codable, Equatable, Sendable {
    public var searchFor = ""
    /// One or more start directories, separated by `;`, as typed; empty means the panel's.
    public var searchIn = ""
    public var namesAreRegex = false
    public var onlySelected = false
    public var searchArchives = false
    /// Ask Spotlight's index instead of walking the folders (in place of the spec's
    /// *Everything*, which exists on Windows only).
    public var useSpotlight = false
    /// `nil` = all subdirectories, 0 = the start directory only.
    public var depth: Int?
    public var findText = false
    public var text = ""
    public var caseSensitive = false
    public var textOptions = TextSearchOptions()
    public var criteria = FileCriteria()
    public var fieldRules = FieldRules()
    public var duplicates = DuplicateOptions()

    public init() {}

    /// The start directories typed into "Search in"; relative ones count from `base`.
    public func directories(relativeTo base: URL, fileSystems: FileSystemRegistry) -> [URL] {
        let typed = searchIn.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                !$0.isEmpty
            }
        return typed.isEmpty ? [base] : typed.map { fileSystems.location(from: $0, relativeTo: base) }
    }

    /// The search these settings describe. `selected` are the panel's marked items, used with
    /// "Only search in selected directories/files". Works on the text alone.
    public func query(relativeTo base: URL, fileSystems: FileSystemRegistry, includeHidden: Bool, selected: [URL] = [])
        -> SearchQuery
    {
        let directories = directories(relativeTo: base, fileSystems: fileSystems)
        var query = SearchQuery(
            directory: directories[0],
            names: searchFor,
            text: findText ? text : "",
            caseSensitive: caseSensitive,
            includeHidden: includeHidden,
            maxDepth: depth.map { max($0, 0) }
        )
        query.moreDirectories = Array(directories.dropFirst())
        query.onlyItems = onlySelected && !selected.isEmpty ? selected : nil
        query.namesAreRegex = namesAreRegex
        query.textOptions = textOptions
        query.criteria = criteria
        query.fieldRules = fieldRules
        query.searchArchives = searchArchives
        query.duplicates = duplicates
        return query
    }

    /// The settings that differ from a plain search, in a few words, for the list of saved
    /// searches (spec 09 › Load/Save tab).
    public var summary: String {
        var parts: [String] = []
        if !searchFor.isEmpty { parts.append(searchFor) }
        if namesAreRegex { parts.append("regex") }
        if findText, !text.isEmpty { parts.append("text \"\(text)\"") }
        if criteria.dateFrom != nil || criteria.dateTo != nil || criteria.notOlderThan != nil
            || criteria.olderThan != nil
        {
            parts.append("date")
        }
        if searchArchives { parts.append("zip") }
        if criteria.size != nil { parts.append("size") }
        if criteria.hasAttributes { parts.append("attr") }
        if duplicates.isActive { parts.append("2x") }
        if let depth { parts.append("D<=\(depth)") }
        if fieldRules.isActive { parts.append("plugins") }
        if useSpotlight { parts.append("Spotlight") }
        return parts.joined(separator: ", ")
    }

    /// These settings as they are loaded into a window that holds `current`: a "Search for" or
    /// "Search in" saved with a leading `>` leaves the window's field as it is.
    public func loaded(over current: Self) -> Self {
        var result = self
        if searchFor.hasPrefix(">") { result.searchFor = current.searchFor }
        if searchIn.hasPrefix(">") { result.searchIn = current.searchIn }
        return result
    }
}

public struct SavedSearch: Codable, Equatable, Sendable {
    public var name: String
    public var settings: SearchSettings

    public init(name: String, settings: SearchSettings) {
        self.name = name
        self.settings = settings
    }
}

/// The saved searches and the histories of the window's fields, kept in the plugin's corner
/// of the settings (spec 09 › What is remembered). Main thread only.
public final class SearchStore {
    public enum Field: String {
        case searchFor, searchIn, text
    }

    private let settings: any SettingsStore
    private static let searchesKey = "searches"

    public init(settings: any SettingsStore) {
        self.settings = settings.scoped(to: "findFiles")
    }

    /// In name order. A search that cannot be read is left out; the others stay.
    public var searches: [SavedSearch] {
        (settings.value([StoredElement<SavedSearch>].self, forKey: Self.searchesKey) ?? []).compactMap(\.value)
            .sorted { Sorter.compare($0.name, $1.name) == .orderedAscending }
    }

    public subscript(name: String) -> SavedSearch? {
        searches.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Saves under a name; a search of that name is replaced.
    public func save(_ search: SavedSearch) {
        settings.set(
            searches.filter { $0.name.caseInsensitiveCompare(search.name) != .orderedSame } + [search],
            forKey: Self.searchesKey
        )
    }

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
        guard !text.isEmpty else { return }
        settings.set(
            Array(([text] + history(field).filter { $0 != text }).prefix(max(limit, 1))),
            forKey: "history." + field.rawValue
        )
    }

    public func forget(_ text: String, in field: Field) {
        settings.set(history(field).filter { $0 != text }, forKey: "history." + field.rawValue)
    }
}
