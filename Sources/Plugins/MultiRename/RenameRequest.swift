/// What the new names of a list are computed from: the rows, the settings, what the masks need
/// besides the items, and the names given in place of the masks.
internal struct RenameRequest {
    /// The rows of the list, in list order.
    internal var entries: [RenameEntry]
    /// The masks, Search & Replace and case.
    internal var settings: RenameSettings
    /// What the masks need besides the items.
    internal var context: RenameContext
    /// Names that take the place of the masks, in list order (a shorter list leaves the rest to the
    /// masks); empty: none.
    internal var given: [String] = []
}
