/// For each shown row of a filtered list the place of its entry in the whole list, rising.
///
/// A list that shows every entry has none: its rows are its places.
internal struct ShownPlaces: Sendable {
    /// The places, rising.
    internal let values: [UInt32]

    /// How many rows are shown.
    internal var count: Int { values.count }

    /// The places of the shown rows, rising.
    internal init(_ values: [UInt32]) {
        self.values = values
    }

    /// The row an entry at a place of the whole list is shown at; nil when it is not shown.
    internal func row(ofPlace place: Int) -> Int? {
        var (low, high) = (0, values.count)
        while low < high {
            let middle = (low + high) / 2
            if Int(values[middle]) < place { low = middle + 1 } else { high = middle }
        }
        return low < values.count && Int(values[low]) == place ? low : nil
    }

    /// The shown places as a set, for a list of `size` entries.
    internal func bits(size: Int) -> Bitset {
        var bits = Bitset(size: size)
        for place in values { bits.insert(Int(place)) }
        return bits
    }

    /// The place of the entry shown at a row.
    internal subscript(row: Int) -> Int { Int(values[row]) }
}
