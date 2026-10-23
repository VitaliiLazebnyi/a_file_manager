/// How the rows of each folder are ordered: by which key, the files of which side, which way round.
internal struct SyncSort: Equatable {
    /// What the rows are sorted by.
    internal var key: SyncSortKey
    /// The side whose files give the key; a row without a file there takes the other side's.
    internal var side: SyncSide
    /// Whether the smallest key comes first.
    internal var ascending: Bool
}
