import Foundation

/// What browsing an archive found.
internal struct BrowseResult {
    /// Whether the archive's top folder could be listed.
    internal var listed = false
    /// The contents of every member that could be read to its end, by URL path.
    internal var contents: [String: Data] = [:]
    /// How many items were listed.
    internal var count = 0
}
