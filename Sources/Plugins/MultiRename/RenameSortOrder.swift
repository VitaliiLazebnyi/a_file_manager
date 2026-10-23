import AFMKernel
import Foundation

/// The order of the rename list when it is sorted by a column; pure, for any thread.
internal enum RenameSortOrder {
    /// What a row is sorted by, made once per row.
    private struct Keys {
        var name: Sorter.NameKey
        var ext: Sorter.NameKey
        var size: Int64
        var modified: Date
    }

    /// The old indexes of `entries` in their new order, the first row first.
    ///
    /// A stable sort: equal items keep their order, also when the direction turns. Names from anywhere
    /// are compared by the kernel's keys, made once per row (not by Foundation's localized comparison,
    /// which is no order and ends the program for some names).
    internal static func permutation(
        of entries: [RenameEntry],
        by key: MultiRenameSession.SortKey,
        ascending: Bool
    ) -> [Int] {
        let keys = entries.map { entry -> Keys in
            let item = entry.item
            return Keys(
                name: Sorter.key(of: entry.name, numeric: true),
                ext: Sorter.key(
                    of: key == .ext && !item.isFolder ? FileItem.split(entry.name).ext : "",
                    numeric: true
                ),
                size: item.size,
                modified: item.modified
            )
        }
        return keys.indices.sorted { first, second in
            if inOrder(keys[first], keys[second], by: key) {
                return ascending
            }
            if inOrder(keys[second], keys[first], by: key) {
                return !ascending
            }
            return first < second
        }
    }

    private static func inOrder(_ first: Keys, _ second: Keys, by key: MultiRenameSession.SortKey) -> Bool {
        switch key {
        case .name:
            return first.name < second.name

        case .ext:
            return first.ext == second.ext ? first.name < second.name : first.ext < second.ext

        case .size:
            return first.size < second.size

        case .date:
            return first.modified < second.modified
        }
    }
}
