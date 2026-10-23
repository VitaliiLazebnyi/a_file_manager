/// What a mask is asked about: one entry of a list, with the folders that lead to it from the
/// directory the list belongs to (empty for an entry of that directory itself).
internal struct MaskEntry {
    /// The name the mask is tried against.
    internal var name: String
    /// Whether the entry is a folder, which masks with a trailing `/` ask for.
    internal var isFolder = false
    /// The folders from the list's directory down to the entry, outermost first.
    internal var directory: [String] = []
}
