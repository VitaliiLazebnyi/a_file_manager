import AFMKernel
public import Foundation

/// Everything a search is told (spec 09 › General tab, Advanced tab, Plugins tab).
///
/// All criteria that are set must hold.
public struct SearchQuery: Sendable {
    /// The first (and usually only) start directory.
    public var directory: URL
    /// Further start directories: "Search in" takes several, separated by `;`.
    public var moreDirectories: [URL] = []
    /// What the search covers; the start directories unless it is limited to chosen items.
    public var scope = SearchScope.startDirectories
    /// "Search for"; empty finds everything.
    public var names: String
    /// "Search for" is one regular expression.
    public var namesAreRegex = false
    /// "Find text"; empty means no content search.
    public var text: String
    /// Whether the text is found only in the case it is written in.
    public var caseSensitive: Bool
    /// How the text is looked for: whole words, a regular expression, hex, "not containing", the encodings.
    public var textOptions = TextSearchOptions()
    /// Hidden files are found, and hidden folders searched, only while the panels show them.
    public var includeHidden: Bool
    /// `nil` = all subdirectories, 0 = the start directory only.
    public var maxDepth: Int?
    /// The date, size and attribute criteria of the Advanced tab.
    public var criteria = FileCriteria()
    /// The rules of the Plugins tab, on the values of the columns.
    public var fieldRules = FieldRules()
    /// Archives are searched like folders, as far as a file system offers their contents.
    public var searchArchives = false
    /// "Find duplicate files": the hits are shown in groups of equal files.
    public var duplicates = DuplicateOptions()
    /// The most hits a run reports; it stops there and says so (`FileSearch.reachedResultLimit`).
    ///
    /// `nil` takes all. A search of a whole disk with an open mask would otherwise keep every file
    /// of it in memory.
    public var resultLimit: Int?

    /// The start directories without those that are searched anyway: a repeated one, and, when
    /// all subdirectories are searched, one that lies inside another.
    public var directories: [URL] {
        let all = [directory] + moreDirectories
        return all.enumerated()
            .filter { index, url in
                !all.enumerated()
                    .contains { other, outer in
                        other != index
                            && (url.isSameLocation(as: outer) ? other < index : maxDepth == nil && url.isInside(outer))
                    }
            }
            .map(\.element)
    }

    /// A search of `directory` for the names `names` (all, when empty) and the text `text` (none, when empty).
    public init(
        directory: URL,
        names: String = "",
        text: String = "",
        caseSensitive: Bool = false,
        includeHidden: Bool = false,
        maxDepth: Int? = nil
    ) {
        self.directory = directory
        self.names = names
        self.text = text
        self.caseSensitive = caseSensitive
        self.includeHidden = includeHidden
        self.maxDepth = maxDepth
    }
}
