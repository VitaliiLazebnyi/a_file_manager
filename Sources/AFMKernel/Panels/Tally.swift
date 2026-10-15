/// What is counted of a list for the status line.
internal struct Tally: Sendable {
    /// The bytes of the entries; a folder counts with its calculated size, once it has one.
    internal var bytes: Int64 = 0
    /// How many entries are files.
    internal var files = 0
    /// How many entries are folders.
    internal var folders = 0
    /// No size below zero and no sum beyond the range of a number: the sum is then the same
    /// in whatever order it is made, and a part can be taken off again.
    internal var isPlain = true

    /// Counts one more entry.
    internal mutating func add(_ item: FileItem) {
        let size = item.isFolder ? (item.computedSize ?? 0) : item.size
        let (sum, overflow) = bytes.addingReportingOverflow(size)
        if size < 0 || overflow { isPlain = false }
        bytes = overflow ? (size < 0 ? .min : .max) : sum
        if item.isFolder { folders += 1 } else { files += 1 }
    }

    /// The sum of two parts counted apart; right when both are plain.
    internal func joined(with other: Self) -> Self {
        let (sum, overflow) = bytes.addingReportingOverflow(other.bytes)
        return Self(
            bytes: overflow ? .max : sum,
            files: files + other.files,
            folders: folders + other.folders,
            isPlain: isPlain && other.isPlain && !overflow
        )
    }
}
