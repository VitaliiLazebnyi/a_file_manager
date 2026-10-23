import Foundation

/// What the system says about the item at a location, for tests that look at rights and flags.
extension URL {
    /// The item's `lstat` (the item itself, not what a link points to); all zero when there is none.
    internal var itemStatus: stat {
        var status = stat()
        lstat(path, &status)
        return status
    }
}
