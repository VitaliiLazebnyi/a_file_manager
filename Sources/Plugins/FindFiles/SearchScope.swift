public import Foundation

/// What a search covers: the start directories, or only chosen items ("Only search in selected
/// directories/files", "Search in found files").
public enum SearchScope: Equatable, Sendable {
    /// Only these items: files are tested themselves; folders are searched inside, or, with a depth of 0,
    /// tested themselves.
    ///
    /// An empty list finds nothing.
    case only([URL])
    /// The start directories of the query, as deep as its depth allows.
    case startDirectories
}
