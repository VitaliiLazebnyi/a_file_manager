/// Every path below a folder (relative to it), files and folders apart.
internal struct Listing: Sendable {
    /// The files (and whatever else is not a folder).
    internal var files: [String] = []
    /// The folders.
    internal var folders: [String] = []
}
