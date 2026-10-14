/// What a move left at both ends, counted over the files of the tree.
internal struct MoveTally {
    /// Files at neither end.
    internal var lost = 0
    /// Files with other bytes at either end.
    internal var damaged = 0
    /// Files intact at both ends.
    internal var both = 0
    /// Files still where the move came from.
    internal var notMoved = 0
    /// The index of the first lost or damaged file.
    internal var example: Int?

    /// Counts the file at `index`, found as `atSource` and `atMoved` (0 missing, 1 identical,
    /// 2 different); `back` when it moved from the moved place to the source.
    internal mutating func count(index: Int, atSource: UInt8, atMoved: UInt8, back: Bool) {
        if atSource == 2 || atMoved == 2 {
            damaged += 1
            example = example ?? index
        }
        if atSource == 0, atMoved == 0 {
            lost += 1
            example = example ?? index
        }
        if atSource == 1, atMoved == 1 {
            both += 1
        }
        if (back ? atMoved : atSource) != 0 {
            notMoved += 1
        }
    }
}
