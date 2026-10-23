import Foundation

/// What is typed into the quick-search field of the tree: the start of a folder's name, with
/// `*` and `?` as wildcards (`*test` finds names containing "test").
///
/// Case is ignored.
public struct TreeQuickSearch {
    /// The text in lower case, with a `*` after it when it has wildcards (so it matches the start of a name).
    private let pattern: String
    /// Whether the text has a `*` or `?`.
    internal let hasWildcards: Bool
    /// The typed text in lower case.
    internal var text: String { hasWildcards ? String(pattern.dropLast()) : pattern }

    /// Whether nothing was typed: nothing then matches.
    public var isEmpty: Bool { pattern.isEmpty }

    /// The search for what was typed.
    public init(_ typed: String) {
        let folded = typed.lowercased()
        hasWildcards = folded.contains("*") || folded.contains("?")
        pattern = hasWildcards ? folded + "*" : folded
    }

    /// Whether the folder name `name` fits, case ignored.
    public func matches(_ name: String) -> Bool {
        matches(folded: name.lowercased())
    }

    /// For a name that is in lower case already.
    internal func matches(folded name: String) -> Bool {
        hasWildcards ? fnmatch(pattern, name, 0) == 0 : name.hasPrefix(pattern)
    }
}
