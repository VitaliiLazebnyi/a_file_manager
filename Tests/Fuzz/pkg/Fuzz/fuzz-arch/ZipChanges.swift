/// What the modify round changed in a ZIP before it wrote it.
internal struct ZipChanges {
    /// Whether the new member was written.
    internal var changed = false
    /// The member that was renamed: its URL path before and after.
    internal var renamed: (from: String, to: String)?
    /// The URL path of the member whose date was changed.
    internal var dated: String?

    /// Where the member that was at `path` is now.
    internal func pathNow(of path: String) -> String {
        if let renamed, renamed.from == path {
            return renamed.to
        }
        return path
    }

    /// Whether `path` is the new name of a renamed member (and so not where a member was before).
    internal func isRenameTarget(_ path: String) -> Bool {
        guard let renamed else {
            return false
        }
        return renamed.to == path && renamed.from != path
    }
}
