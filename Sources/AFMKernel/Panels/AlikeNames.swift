/// The rows of a list's names that hold more than ASCII, found by the equality of strings, so
/// that a name finds an entry that reads the same though it is written differently.
///
/// A name of plain ASCII reads like no other writing than its own.
internal struct AlikeNames {
    /// The first row of each such name.
    private var rows: [String: Int] = [:]

    /// The index of the names of `shown`.
    internal init(_ shown: [FileItem]) {
        for (row, item) in shown.enumerated()
        where !item.name.utf8.allSatisfy({ $0 < 0x80 }) && rows[item.name] == nil {
            rows[item.name] = row
        }
    }

    /// The first row whose name reads like `name`.
    internal func row(of name: String) -> Int? {
        rows[name]
    }
}
