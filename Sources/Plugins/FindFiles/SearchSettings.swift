public import AFMKernel
public import Foundation

/// Everything the Find Files window holds in its four tabs, as the user entered it.
///
/// This is what a saved search stores and what a search is made from (spec 09 › Load/Save tab).
public struct SearchSettings: Codable, Equatable, Sendable {
    /// "Search for": the masks, or one regular expression.
    public var searchFor = ""
    /// One or more start directories, separated by `;`, as typed; empty means the panel's.
    public var searchIn = ""
    /// "Search for" is one regular expression.
    public var namesAreRegex = false
    /// "Only search in selected directories/files".
    public var onlySelected = false
    /// "Search archives": archives are searched like folders.
    public var searchArchives = false
    /// Ask Spotlight's index instead of walking the folders (in place of the spec's
    /// *Everything*, which exists on Windows only).
    public var useSpotlight = false
    /// `nil` = all subdirectories, 0 = the start directory only.
    public var depth: Int?
    /// "Find text" is ticked: the files are searched for `text`.
    public var findText = false
    /// The text to find, kept while "Find text" is off.
    public var text = ""
    /// "Case sensitive" of the text.
    public var caseSensitive = false
    /// The other options of the text.
    public var textOptions = TextSearchOptions()
    /// The Advanced tab, except the duplicate finder.
    public var criteria = FileCriteria()
    /// The Plugins tab.
    public var fieldRules = FieldRules()
    /// "Find duplicate files" of the Advanced tab.
    public var duplicates = DuplicateOptions()

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

    /// The settings of a fresh window: everything found in the panel's folder and below.
    public init() {
        // Every field starts out as declared.
    }

    /// The start directories typed into "Search in"; relative ones count from `base`.
    public func directories(relativeTo base: URL, fileSystems: FileSystemRegistry) -> [URL] {
        let typed = searchIn.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return typed.isEmpty ? [base] : typed.map { fileSystems.location(from: $0, relativeTo: base) }
    }

    /// The search these settings describe.
    ///
    /// `selected` are the panel's marked items, used with "Only search in selected
    /// directories/files". Works on the text alone.
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
        query.scope = onlySelected && !selected.isEmpty ? .only(selected) : .startDirectories
        query.namesAreRegex = namesAreRegex
        query.textOptions = textOptions
        query.criteria = criteria
        query.fieldRules = fieldRules
        query.searchArchives = searchArchives
        query.duplicates = duplicates
        return query
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
