public import Foundation

/// Puts a file list in order.
///
/// Pure functions, safe on any thread: large lists are sorted in the background, on all cores,
/// before they reach the panel.
///
/// **The order of names** is the order of their collation keys: the bytes the system's
/// collator makes of a name for the user's language, with letters and accents counting and
/// case not. Names with equal keys (they differ in case, or in how an accent is written) are
/// in the order of their own bytes. Bytes compare one way only, so this is an order in the
/// strict sense: of two different names exactly one comes first, and what holds for a and b
/// and for b and c holds for a and c. The system's localized comparison of two strings is
/// not such an order for every pair of names, and it is never asked here: for some names it
/// answers "after" both ways round, and for some it stops the program.
///
/// Each item gets a compact record once (`SortKeys`) holding the keys of the parts of its
/// name the order looks at; sorting, merging and reversing compare those records as plain
/// bytes, on all cores. `exactOrder` gives the same answers for two items on their own.
public enum Sorter: Sendable {
    /// An item's name in the parts the comparison needs: the first decides, the second
    /// decides between items whose first parts are the same bytes.
    internal struct Parts {
        /// The part that is compared first.
        internal let first: String
        /// The part that decides between equal first parts.
        internal let second: String

        /// The parts are those of `SortKeys`: a folder's whole name; a file's extension and
        /// then the name without it when sorting by extension, otherwise the name without
        /// the extension and then the rest (the dot with the extension).
        internal init(_ item: FileItem, _ key: SortKey) {
            guard !item.isFolder else {
                (first, second) = (item.name, "")
                return
            }
            let (base, ext) = FileItem.split(item.name)
            if key == .ext {
                (first, second) = (ext, base)
            } else {
                (first, second) = (base, String(item.name.utf8.dropFirst(base.utf8.count)) ?? "")
            }
        }
    }

    /// Lists above this size are sorted on all cores.
    internal static let parallelThreshold = 8_000

    /// Two names in the order of names, for whoever sorts names outside a panel's list (the rows of
    /// a tool's window, the files of a job, the lines of a report).
    ///
    /// **For names from anywhere**: it is an order in the strict sense whatever the names hold, and
    /// it does not go through Foundation's localized comparisons, which are not one and which end
    /// the program for certain names (K001). Any thread.
    ///
    /// With `numeric`, runs of digits count by their value (`file2` before `file10`), as
    /// Finder shows names; without, the names stand as the panels' lists have them.
    public static func compare(_ lhs: String, _ rhs: String, numeric: Bool = false) -> ComparisonResult {
        compareNames(lhs, rhs, collator: numeric ? .currentNumeric : .current)
    }

    /// The key of a name for `compare(_:_:numeric:)`, for a caller that compares the same names
    /// many times: two names are in the order of their keys (`NameKey` is `Comparable`), which
    /// costs a comparison of bytes.
    ///
    /// Any thread.
    public static func key(of name: String, numeric: Bool = false) -> NameKey {
        let collator: NameCollator = numeric ? .currentNumeric : .current
        return NameKey(key: collator.withKey(of: name) { Array($0) }, name: name)
    }

    /// `items` by their names, in the order of `compare(_:_:numeric:)`; items of the same name stay
    /// in the order they came.
    ///
    /// The key of each name is made once. Any thread.
    public static func sorted<Element>(_ items: [Element], numeric: Bool = false, byName name: (Element) -> String)
        -> [Element]
    {
        guard items.count > 1 else {
            return items
        }
        let collator: NameCollator = numeric ? .currentNumeric : .current
        let names = items.map(name)
        let keys = names.map { name in collator.withKey(of: name) { Array($0) } }
        var order = Array(items.indices)
        order.sort { first, second in
            var result = keys[first]
                .withUnsafeBufferPointer { lhs in
                    keys[second].withUnsafeBufferPointer { SortKeys.bytewise(lhs, $0) }
                }
            if result == 0 { result = SortKeys.bytewise(names[first], names[second]) }
            return result != 0 ? result < 0 : first < second
        }
        return order.map { items[$0] }
    }

    /// The items in order: folders first and always by name, files by the chosen key (03 ›
    /// Directories); unsorted keeps files in the order they came.
    ///
    /// Any thread; a long list is sorted on all cores.
    public static func sort(_ items: [FileItem], by order: ListOrder) -> [FileItem] {
        sort(items, by: order, collator: .current)
    }

    /// Puts a list that is in `old` order into `new` order, with the result `sort` would give.
    ///
    /// Turning the direction of the same key round is one pass that reverses the files, unless two
    /// of them are equal for the order (they would have to keep their places); everything else is
    /// sorted.
    ///
    /// Sorting keeps files that are equal for the new order in the order the list has them,
    /// which for `unsorted` is every file: a list that was sorted by another key stays as that
    /// key left it. The order the files came in is known only to whoever read the directory;
    /// to show it again, the directory is read again.
    public static func resort(_ items: [FileItem], from old: ListOrder, to new: ListOrder) -> [FileItem] {
        let indexes = resortedIndexes(of: items, from: old, to: new)
        return indexes.isEmpty ? items : permute(items, by: indexes)
    }

    /// Two names in the order of names (see the type): by collation key, then by bytes.
    internal static func compareNames(_ lhs: String, _ rhs: String, collator: NameCollator) -> ComparisonResult {
        if ExactName.areSame(lhs, rhs) {
            return .orderedSame
        }
        var result = collator.withKey(of: lhs) { first in collator.withKey(of: rhs) { SortKeys.bytewise(first, $0) } }
        if result == 0 { result = SortKeys.bytewise(lhs, rhs) }
        return result < 0 ? .orderedAscending : (result > 0 ? .orderedDescending : .orderedSame)
    }

    /// The comparison that defines the order, for two items without records: negative when
    /// `lhs` belongs before `rhs`, zero when neither has to come first (two files in the order
    /// they came, or two items of the same name, byte for byte).
    internal static func exactOrder(_ lhs: FileItem, _ rhs: FileItem, by order: ListOrder, collator: NameCollator)
        -> Int
    {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder ? -1 : 1
        }
        if !lhs.isFolder {
            if order.key == .unsorted {
                return 0
            }
            let (first, second) = (SortKeys.primary(of: lhs, order.key), SortKeys.primary(of: rhs, order.key))
            if first != second {
                return (first < second) != order.descending ? -1 : 1
            }
        }
        let (first, second) = (Parts(lhs, order.key), Parts(rhs, order.key))
        var result = compareNames(first.first, second.first, collator: collator).rawValue
        if result == 0 { result = compareNames(first.second, second.second, collator: collator).rawValue }
        return order.descending && !lhs.isFolder ? -result : result
    }

    /// Sorting by the keys of a given collator: the order of that collator's language.
    internal static func sort(_ items: [FileItem], by order: ListOrder, collator: NameCollator) -> [FileItem] {
        guard items.count > 1 else {
            return items
        }
        return permute(items, by: sortedIndexes(of: items, keys: SortKeys(items, order: order, collator: collator)))
    }

    /// Where each item of the list `resort` gives is in `items`; empty when the list stays as
    /// it is (a list of two items or more always has places).
    internal static func resortedIndexes(of items: [FileItem], from old: ListOrder, to new: ListOrder) -> [UInt32] {
        guard items.count > 1 else {
            return []
        }
        let folderCount = items.firstIndex { !$0.isFolder } ?? items.count
        let files = items[folderCount...]
        let sorted = { sortedIndexes(of: items, keys: SortKeys(items, order: new, collator: .current)) }
        guard old.key == new.key, old.descending != new.descending, !files.contains(where: \.isFolder) else {
            return sorted()
        }
        // Files in the order they came have no direction.
        guard new.key != .unsorted else {
            return []
        }
        guard !hasTwins(files) else {
            return sorted()
        }
        return (0..<folderCount).map { UInt32($0) } + (folderCount..<items.count).reversed().map { UInt32($0) }
    }

    /// Whether two neighbours of a sorted run of files have the same name, byte for byte:
    /// only such files are equal for the order, and in a sorted list they lie next to each other.
    internal static func hasTwins(_ files: ArraySlice<FileItem>) -> Bool {
        zip(files, files.dropFirst()).contains { ExactName.areSame($0.name, $1.name) }
    }

    /// The positions of the items in sorted order.
    internal static func sortedIndexes(of items: [FileItem], keys: SortKeys) -> [UInt32] {
        let order = keys.order
        // Folders come first and are always in ascending order of their names; the files
        // follow in the chosen order. Both groups start in the order the items came in.
        let folders = keys.records.indices.filter { keys.records[$0].isFolder }.map { UInt32($0) }
        var indexes = folders + keys.records.indices.filter { !keys.records[$0].isFolder }.map { UInt32($0) }
        keys.records.withUnsafeBufferPointer { buffer in
            // The records are only read, while the call lasts.
            nonisolated(unsafe) let records = buffer
            // Equal items keep the order they came in, which also makes any two items
            // different: the result does not depend on how the sorting is cut into pieces.
            @Sendable
            func isBefore(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
                var result = SortKeys.quick(records[Int(lhs)], records[Int(rhs)], order)
                // A name too long for a record: the same comparison, worked out for the pair.
                if result == SortKeys.unknown {
                    result = exactOrder(items[Int(lhs)], items[Int(rhs)], by: order, collator: keys.collator)
                }
                return result < 0 || (result == 0 && lhs < rhs)
            }
            indexes.withUnsafeMutableBufferPointer { indexes in
                BucketSort.sort(UnsafeMutableBufferPointer(rebasing: indexes[..<folders.count]), by: isBefore)
                if order.key != .unsorted {
                    BucketSort.sort(UnsafeMutableBufferPointer(rebasing: indexes[folders.count...]), by: isBefore)
                }
            }
        }
        return indexes
    }

    /// The items in the order of `indexes`.
    ///
    /// Copying an item counts its references, which is worth spreading over the cores for a long
    /// list.
    internal static func permute<Element: Sendable>(_ items: [Element], by indexes: [UInt32]) -> [Element] {
        guard indexes.count > parallelThreshold else {
            return indexes.map { items[Int($0)] }
        }
        return [Element](unsafeUninitializedCapacity: indexes.count) { buffer, count in
            // Each piece writes its own positions and only reads the items.
            nonisolated(unsafe) let target = buffer
            let pieces = ListWork.evenPieces(indexes.count, ProcessInfo.processInfo.activeProcessorCount * 4)
            _ = Parallel.map(pieces) { piece in
                for position in piece { target.initializeElement(at: position, to: items[Int(indexes[position])]) }
            }
            count = indexes.count
        }
    }
}
