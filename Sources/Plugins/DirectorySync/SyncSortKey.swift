/// What the rows of a folder are sorted by.
internal enum SyncSortKey: Int, Codable {
    /// The modification date.
    case date = 2
    /// The name, as the comparison delivers the rows.
    case name = 0
    /// The size.
    case size = 1
}
