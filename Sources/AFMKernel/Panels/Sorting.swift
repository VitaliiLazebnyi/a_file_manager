public import Foundation

/// Sort keys of the Show menu; raw values match `sortorder=` in the spec (03 › Sort keys).
public enum SortKey: Int, Sendable {
    case name = 0
    case ext = 1
    case size = 2
    case date = 3
    case unsorted = 4

    /// Time and Size start descending (newest / largest first), the others ascending.
    public var startsDescending: Bool { self == .date || self == .size }
}

public struct ListOrder: Equatable, Sendable {
    public var key: SortKey
    public var descending: Bool

    public init(key: SortKey = .name, descending: Bool = false) {
        self.key = key
        self.descending = descending
    }
}

/// Puts a file list in order. Pure functions, safe on any thread: large lists are sorted in
/// the background, on all cores, before they reach the panel.
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
/// bytes, on all cores. `areInOrder` gives the same answers for two items on their own.
public enum Sorter: Sendable {
    /// An item with the parts of its name the comparison needs: the first decides, the
    /// second decides between items whose first parts are the same bytes.
    fileprivate struct Keyed {
        let first: String
        let second: String

        /// The parts are those of `SortKeys`: a folder's whole name; a file's extension and
        /// then the name without it when sorting by extension, otherwise the name without
        /// the extension and then the rest (the dot with the extension).
        init(_ item: FileItem, _ key: SortKey) {
            if item.isFolder {
                (first, second) = (item.name, "")
            } else {
                let (base, ext) = FileItem.split(item.name)
                if key == .ext {
                    (first, second) = (ext, base)
                } else {
                    (first, second) = (base, String(item.name.utf8.dropFirst(base.utf8.count)) ?? "")
                }
            }
        }
    }

    /// Two names in the order of names (see the type): by collation key, then by bytes.
    static func compareNames(_ a: String, _ b: String, collator: NameCollator) -> ComparisonResult {
        if ExactName.areSame(a, b) { return .orderedSame }
        var result = collator.withKey(of: a) { first in collator.withKey(of: b) { SortKeys.bytewise(first, $0) } }
        if result == 0 { result = SortKeys.bytewise(a, b) }
        return result < 0 ? .orderedAscending : (result > 0 ? .orderedDescending : .orderedSame)
    }

    /// Two names in the order of names, for whoever sorts names outside a panel's list (the
    /// rows of a tool's window, the files of a job, the lines of a report). **For names from
    /// anywhere**: it is an order in the strict sense whatever the names hold, and it does not
    /// go through Foundation's localized comparisons, which are not one and which end the
    /// program for certain names (K001). Any thread.
    ///
    /// With `numeric`, runs of digits count by their value (`file2` before `file10`), as
    /// Finder shows names; without, the names stand as the panels' lists have them.
    public static func compare(_ a: String, _ b: String, numeric: Bool = false) -> ComparisonResult {
        compareNames(a, b, collator: numeric ? .currentNumeric : .current)
    }

    /// The key of a name for `compare(_:_:numeric:)`, for a caller that compares the same
    /// names many times: two names are in the order of their keys (`NameKey` is
    /// `Comparable`), which costs a comparison of bytes. Any thread.
    public static func key(of name: String, numeric: Bool = false) -> NameKey {
        let collator: NameCollator = numeric ? .currentNumeric : .current
        return NameKey(key: collator.withKey(of: name) { Array($0) }, name: name)
    }

    /// See `Sorter.key(of:numeric:)`.
    public struct NameKey: Comparable, Sendable {
        fileprivate let key: [UInt8]
        fileprivate let name: String

        public static func == (a: Self, b: Self) -> Bool { ExactName.areSame(a.name, b.name) }

        public static func < (a: Self, b: Self) -> Bool {
            if ExactName.areSame(a.name, b.name) { return false }
            var result = a.key.withUnsafeBufferPointer { first in
                b.key.withUnsafeBufferPointer { SortKeys.bytewise(first, $0) }
            }
            if result == 0 { result = SortKeys.bytewise(a.name, b.name) }
            return result < 0
        }
    }

    /// `items` by their names, in the order of `compare(_:_:numeric:)`; items of the same
    /// name stay in the order they came. The key of each name is made once. Any thread.
    public static func sorted<Element>(_ items: [Element], numeric: Bool = false, byName name: (Element) -> String)
        -> [Element]
    {
        guard items.count > 1 else { return items }
        let collator: NameCollator = numeric ? .currentNumeric : .current
        let names = items.map(name)
        let keys = names.map { name in collator.withKey(of: name) { Array($0) } }
        var order = Array(items.indices)
        order.sort { first, second in
            var result = keys[first].withUnsafeBufferPointer { a in
                keys[second].withUnsafeBufferPointer { SortKeys.bytewise(a, $0) }
            }
            if result == 0 { result = SortKeys.bytewise(names[first], names[second]) }
            return result != 0 ? result < 0 : first < second
        }
        return order.map { items[$0] }
    }

    /// The comparison that defines the order, for two items without records: negative when
    /// `a` belongs before `b`, zero when neither has to come first (two files in the order
    /// they came, or two items of the same name, byte for byte).
    static func exactOrder(_ a: FileItem, _ b: FileItem, by order: ListOrder, collator: NameCollator) -> Int
    {
        if a.isFolder != b.isFolder { return a.isFolder ? -1 : 1 }
        if !a.isFolder {
            if order.key == .unsorted { return 0 }
            let (x, y) = (SortKeys.primary(of: a, order.key), SortKeys.primary(of: b, order.key))
            if x != y { return (x < y) != order.descending ? -1 : 1 }
        }
        let (first, second) = (Keyed(a, order.key), Keyed(b, order.key))
        var result = compareNames(first.first, second.first, collator: collator).rawValue
        if result == 0 { result = compareNames(first.second, second.second, collator: collator).rawValue }
        return order.descending && !a.isFolder ? -result : result
    }

    /// Lists above this size are sorted on all cores.
    static let parallelThreshold = 8_000

    public static func sort(_ items: [FileItem], by order: ListOrder) -> [FileItem] {
        sort(items, by: order, collator: .current)
    }

    /// Sorting by the keys of a given collator: the order of that collator's language.
    static func sort(_ items: [FileItem], by order: ListOrder, collator: NameCollator) -> [FileItem] {
        guard items.count > 1 else { return items }
        return permute(items, by: sortedIndexes(of: items, keys: SortKeys(items, order: order, collator: collator)))
    }

    /// Where each item of the sorted list is in `items`.
    static func sortedIndexes(of items: [FileItem], by order: ListOrder) -> [UInt32] {
        sortedIndexes(of: items, keys: SortKeys(items, order: order))
    }

    /// Puts a list that is in `old` order into `new` order, with the result `sort` would
    /// give. Turning the direction of the same key round is one pass that reverses the files,
    /// unless two of them are equal for the order (they would have to keep their places);
    /// everything else is sorted.
    ///
    /// Sorting keeps files that are equal for the new order in the order the list has them,
    /// which for `unsorted` is every file: a list that was sorted by another key stays as that
    /// key left it. The order the files came in is known only to whoever read the directory;
    /// to show it again, the directory is read again.
    public static func resort(_ items: [FileItem], from old: ListOrder, to new: ListOrder) -> [FileItem] {
        guard let indexes = resortedIndexes(of: items, from: old, to: new) else { return items }
        return permute(items, by: indexes)
    }

    /// Where each item of the list `resort` gives is in `items`; nil when the list stays as it is.
    static func resortedIndexes(of items: [FileItem], from old: ListOrder, to new: ListOrder) -> [UInt32]? {
        guard items.count > 1 else { return nil }
        guard old.key == new.key, old.descending != new.descending else { return sortedIndexes(of: items, by: new) }
        let folderCount = items.firstIndex { !$0.isFolder } ?? items.count
        let files = items[folderCount...]
        guard !files.contains(where: \.isFolder) else { return sortedIndexes(of: items, by: new) }
        // Files in the order they came have no direction.
        if new.key == .unsorted { return nil }
        // Only files of the same name, byte for byte, are equal for the order, and in a
        // sorted list those lie next to each other.
        for index in files.indices.dropFirst() where ExactName.areSame(files[index - 1].name, files[index].name) {
            return sortedIndexes(of: items, by: new)
        }
        // An empty array is never made with `unsafeUninitializedCapacity`: for a capacity of zero
        // the standard library writes the count into the storage all empty arrays share, a write
        // that races with any other thread reading an empty array.
        guard !items.isEmpty else { return [] }
        return [UInt32](unsafeUninitializedCapacity: items.count) { buffer, count in
            for index in 0..<folderCount { buffer[index] = UInt32(index) }
            for index in folderCount..<items.count { buffer[index] = UInt32(items.count - 1 - (index - folderCount)) }
            count = items.count
        }
    }

    // MARK: Sorting by keys

    /// The positions of the items in sorted order.
    fileprivate static func sortedIndexes(of items: [FileItem], keys: SortKeys) -> [UInt32] {
        // An empty array is never made with `unsafeUninitializedCapacity`: for a capacity of zero
        // the standard library writes the count into the storage all empty arrays share, a write
        // that races with any other thread reading an empty array.
        guard !keys.records.isEmpty else { return [] }
        let order = keys.order
        return keys.records.withUnsafeBufferPointer { records in
            // Folders come first and are always in ascending order of their names; the files
            // follow in the chosen order. Both groups start in the order the items came in.
            var folderCount = 0
            var indexes = [UInt32](unsafeUninitializedCapacity: records.count) { buffer, count in
                for index in 0..<records.count where records[index].isFolder {
                    buffer[folderCount] = UInt32(index)
                    folderCount += 1
                }
                var next = folderCount
                for index in 0..<records.count where !records[index].isFolder {
                    buffer[next] = UInt32(index)
                    next += 1
                }
                count = records.count
            }
            items.withUnsafeBufferPointer { items in
                // Both lists are only read, while the call lasts.
                nonisolated(unsafe) let (items, records) = (items, records)
                // Equal items keep the order they came in, which also makes any two items
                // different: the result does not depend on how the sorting is cut into pieces.
                @Sendable func isBefore(_ a: UInt32, _ b: UInt32) -> Bool {
                    var result = SortKeys.quick(records[Int(a)], records[Int(b)], order)
                    // A name too long for a record: the same comparison, worked out for the pair.
                    if result == SortKeys.unknown {
                        result = exactOrder(items[Int(a)], items[Int(b)], by: order, collator: keys.collator)
                    }
                    return result < 0 || (result == 0 && a < b)
                }
                indexes.withUnsafeMutableBufferPointer { indexes in
                    sort(UnsafeMutableBufferPointer(rebasing: indexes[..<folderCount]), by: isBefore)
                    if order.key != .unsorted {
                        sort(UnsafeMutableBufferPointer(rebasing: indexes[folderCount...]), by: isBefore)
                    }
                }
            }
            return indexes
        }
    }

    /// Sorts in place. A long list is dealt into buckets of neighbouring values, which are
    /// then sorted at the same time; nothing is left to merge on a single thread.
    private static func sort(
        _ indexes: UnsafeMutableBufferPointer<UInt32>, by isBefore: @Sendable (UInt32, UInt32) -> Bool
    ) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard indexes.count > parallelThreshold, cores > 1 else {
            var run = indexes
            run.sort(by: isBefore)
            return
        }
        let bucketCount = min(256, cores * 8)
        // The boundaries between the buckets come from a sample spread over the list.
        let oversampling = 16
        let sampleCount = bucketCount * oversampling
        let sample = (0..<sampleCount).map { indexes[$0 * indexes.count / sampleCount] }.sorted(by: isBefore)
        nonisolated(unsafe) let splitters = UnsafeMutablePointer<UInt32>.allocate(capacity: bucketCount - 1)
        for bucket in 1..<bucketCount { splitters[bucket - 1] = sample[bucket * oversampling] }

        let pieceCount = cores * 4
        let pieces = (0..<pieceCount).map {
            ($0 * indexes.count / pieceCount)..<(($0 + 1) * indexes.count / pieceCount)
        }
        // Every piece below reads the splitters and the copy and writes its own positions
        // (its own buckets, in the last step) of the rest.
        nonisolated(unsafe) let bucketOf = UnsafeMutablePointer<UInt8>.allocate(capacity: indexes.count)
        nonisolated(unsafe) let copy = UnsafeMutablePointer<UInt32>.allocate(capacity: indexes.count)
        nonisolated(unsafe) let indexes = indexes
        defer {
            bucketOf.deallocate()
            copy.deallocate()
            splitters.deallocate()
        }
        copy.initialize(from: indexes.baseAddress!, count: indexes.count)
        let counts = Parallel.map(pieces) { piece -> [Int] in
            var counts = [Int](repeating: 0, count: bucketCount)
            for position in piece {
                // The first boundary that lies after the value names its bucket.
                let value = copy[position]
                var (low, high) = (0, bucketCount - 1)
                while low < high {
                    let middle = (low + high) / 2
                    if isBefore(value, splitters[middle]) { high = middle } else { low = middle + 1 }
                }
                bucketOf[position] = UInt8(truncatingIfNeeded: low)
                counts[low] += 1
            }
            return counts
        }
        // Where each piece puts its share of each bucket.
        var starts = [[Int]](repeating: [Int](repeating: 0, count: bucketCount), count: pieceCount)
        var buckets: [Range<Int>] = []
        var position = 0
        for bucket in 0..<bucketCount {
            let start = position
            for piece in 0..<pieceCount {
                starts[piece][bucket] = position
                position += counts[piece][bucket]
            }
            buckets.append(start..<position)
        }
        _ = Parallel.map(Array(0..<pieceCount)) { [starts] piece in
            var next = starts[piece]
            for position in pieces[piece] {
                let bucket = Int(bucketOf[position])
                indexes[next[bucket]] = copy[position]
                next[bucket] += 1
            }
        }
        _ = Parallel.map(buckets) { bucket in
            var run = UnsafeMutableBufferPointer(rebasing: indexes[bucket])
            run.sort(by: isBefore)
        }
    }

    /// The items in the order of `indexes`. Copying an item counts its references, which is
    /// worth spreading over the cores for a long list.
    static func permute<Element: Sendable>(_ items: [Element], by indexes: [UInt32]) -> [Element] {
        guard indexes.count > parallelThreshold else { return indexes.map { items[Int($0)] } }
        return [Element](unsafeUninitializedCapacity: indexes.count) { buffer, count in
            // Each piece writes its own positions and only reads the items.
            nonisolated(unsafe) let target = buffer.baseAddress!
            items.withUnsafeBufferPointer { items in
                nonisolated(unsafe) let items = items
                let pieceCount = ProcessInfo.processInfo.activeProcessorCount * 4
                let pieces = (0..<pieceCount).map {
                    ($0 * indexes.count / pieceCount)..<(($0 + 1) * indexes.count / pieceCount)
                }
                _ = Parallel.map(pieces) { piece in
                    for position in piece { (target + position).initialize(to: items[Int(indexes[position])]) }
                }
            }
            count = indexes.count
        }
    }
}

/// A list that stays sorted while batches are added to it: what a directory that arrives in
/// pieces is collected in, on a background thread. Each batch is sorted on its own and merged
/// in, so adding costs one pass instead of a new sort.
public struct SortedFileList: Sendable {
    /// A sorted part of the list: the places of its items in `arrived`, in order, with their keys
    /// in the same order.
    private struct Run: Sendable {
        let places: [UInt32]
        let keys: SortKeys
    }

    public let order: ListOrder
    /// Every item added, in the order they came.
    private var arrived: [FileItem] = []
    /// The sorted parts, in the order they came, each longer than the one after it. A batch is
    /// merged only with parts of its own length or shorter, so every item takes part in a number
    /// of merges that grows with the logarithm of the list, not with the number of batches. A
    /// merge moves keys and places, never the items themselves.
    private var runs: [Run] = []

    /// The items in order: the parts merged, the earlier ones ahead of equal items of later ones.
    public var items: [FileItem] {
        guard var merged = runs.last else { return [] }
        for run in runs.dropLast().reversed() { merged = self.merged(run, merged) }
        return Sorter.permute(arrived, by: merged.places)
    }

    public init(order: ListOrder) {
        self.order = order
    }

    public mutating func add(_ batch: [FileItem]) {
        guard !batch.isEmpty else { return }
        let keys = SortKeys(batch, order: order)
        let indexes = Sorter.sortedIndexes(of: batch, keys: keys)
        let start = UInt32(arrived.count)
        arrived += batch
        runs.append(Run(places: indexes.map { $0 + start }, keys: keys.permuted(by: indexes)))
        while runs.count > 1, runs[runs.count - 2].places.count <= runs[runs.count - 1].places.count {
            let last = runs.removeLast()
            runs[runs.count - 1] = merged(runs[runs.count - 1], last)
        }
    }

    /// Two sorted parts as one, in one pass; items of `first` stay ahead of equal items of `second`.
    private func merged(_ first: Run, _ second: Run) -> Run {
        let (x, y) = (first.keys.records, second.keys.records)
        var fromSecond: [Bool] = []
        var places: [UInt32] = []
        fromSecond.reserveCapacity(x.count + y.count)
        places.reserveCapacity(x.count + y.count)
        var (i, j) = (0, 0)
        while i < x.count, j < y.count {
            var result = SortKeys.quick(y[j], x[i], order)
            if result == SortKeys.unknown {
                result = Sorter.exactOrder(
                    arrived[Int(second.places[j])], arrived[Int(first.places[i])], by: order,
                    collator: first.keys.collator)
            }
            fromSecond.append(result < 0)
            if result < 0 {
                places.append(second.places[j])
                j += 1
            } else {
                places.append(first.places[i])
                i += 1
            }
        }
        fromSecond.append(contentsOf: repeatElement(false, count: x.count - i))
        places.append(contentsOf: first.places[i...])
        fromSecond.append(contentsOf: repeatElement(true, count: y.count - j))
        places.append(contentsOf: second.places[j...])
        return Run(places: places, keys: SortKeys(merging: first.keys, second.keys, fromSecond: fromSecond))
    }
}

// MARK: - Keys

/// One compact record per item, made once: what sorting compares instead of the names.
///
/// A record holds, for each part of the name that the order looks at, the part's collation
/// key (the bytes the system's collator makes of it for the user's language) and the part
/// itself. Two records are compared part by part: by key, then by the part's own bytes.
/// That is the order of names, not an approximation of it (see `Sorter`). Only a name too
/// long for a record has none; `quick` then says so and the caller works the same
/// comparison out for the pair.
///
/// Unchecked: the records point into `blocks`, which the keys own and which nobody writes
/// once the keys are made, so the keys may be read on any number of threads.
struct SortKeys: @unchecked Sendable {
    /// The answer of `quick` when a record is missing.
    static let unknown = 2

    fileprivate struct Record {
        /// Size or date of a file, mapped so that integers compare like the values.
        var primary: Int64 = 0
        /// The bytes of the key: first part's collation key, first part, then the second part's.
        var bytes: UnsafePointer<UInt8>?
        var firstKey: UInt16 = 0, first: UInt16 = 0, secondKey: UInt16 = 0, second: UInt16 = 0
        var flags: UInt16 = 0

        static let folder: UInt16 = 1
        /// No key could be made: the comparison is worked out from the names.
        static let keyless: UInt16 = 4

        var isFolder: Bool { flags & Self.folder != 0 }
    }

    /// The memory the records point into.
    fileprivate final class Block: @unchecked Sendable {
        let bytes: UnsafeMutablePointer<UInt8>
        init(_ bytes: UnsafeMutablePointer<UInt8>) { self.bytes = bytes }
        deinit { free(bytes) }
    }

    let order: ListOrder
    /// Whose keys these are.
    let collator: NameCollator
    fileprivate private(set) var records: [Record]
    private var blocks: [Block]

    /// What files are ordered by before their names: the size, or the date as a number that
    /// compares like it (the bits of a floating-point number, turned round where negative).
    static func primary(of item: FileItem, _ key: SortKey) -> Int64 {
        switch key {
        case .size: return item.size

        case .date:
            let bits = Int64(bitPattern: (item.modified.timeIntervalSinceReferenceDate + 0).bitPattern)
            return bits < 0 ? bits ^ Int64.max : bits

        default: return 0
        }
    }

    /// The first part is the extension when sorting by it, otherwise the name without it;
    /// folders have their whole name as the only part. The second part is what is compared
    /// when the first parts are the same text: the base name after the extension, or the
    /// rest of the name (`.ext`) after the base name.
    init(_ items: [FileItem], order: ListOrder, collator: NameCollator = .current) {
        self.order = order
        self.collator = collator
        guard !items.isEmpty else {
            (records, blocks) = ([], [])
            return
        }
        let pieceCount = items.count > Sorter.parallelThreshold ? ProcessInfo.processInfo.activeProcessorCount * 4 : 1
        let pieces = (0..<pieceCount).map { ($0 * items.count / pieceCount)..<(($0 + 1) * items.count / pieceCount) }
        var blocks: [Block] = []
        records = [Record](unsafeUninitializedCapacity: items.count) { buffer, count in
            // Each piece writes the records of its own items.
            nonisolated(unsafe) let records = buffer.baseAddress!
            blocks = items.withUnsafeBufferPointer { items in
                nonisolated(unsafe) let items = items
                return Parallel.map(pieces) { piece in
                    Self.build(items, piece, into: records, order: order, collator: collator)
                }
            }
            count = items.count
        }
        self.blocks = blocks
    }

    private init(order: ListOrder, collator: NameCollator, records: [Record], blocks: [Block]) {
        (self.order, self.collator, self.records, self.blocks) = (order, collator, records, blocks)
    }

    /// The keys of the same items in another order.
    func permuted(by indexes: [UInt32]) -> Self {
        Self(order: order, collator: collator, records: indexes.map { records[Int($0)] }, blocks: blocks)
    }

    /// The keys of two lists merged: each place takes the next key of the first or second list.
    init(merging first: Self, _ second: Self, fromSecond: [Bool]) {
        var records: [Record] = []
        records.reserveCapacity(fromSecond.count)
        var (i, j) = (0, 0)
        for isSecond in fromSecond {
            if isSecond {
                records.append(second.records[j])
                j += 1
            } else {
                records.append(first.records[i])
                i += 1
            }
        }
        self.init(order: first.order, collator: first.collator, records: records, blocks: first.blocks + second.blocks)
    }

    /// Negative when the first item comes before the second, positive when after, zero when
    /// neither has to come first, `unknown` when one of them has no key.
    fileprivate static func quick(_ x: Record, _ y: Record, _ order: ListOrder) -> Int {
        if (x.flags ^ y.flags) & Record.folder != 0 { return x.flags & Record.folder != 0 ? -1 : 1 }
        if x.flags & Record.folder != 0 { return names(x, y) }
        if order.key == .unsorted { return 0 }
        if x.primary != y.primary { return (x.primary < y.primary) != order.descending ? -1 : 1 }
        let result = names(x, y)
        return order.descending && result != unknown ? -result : result
    }

    private static func names(_ x: Record, _ y: Record) -> Int {
        guard (x.flags | y.flags) & Record.keyless == 0, let xBytes = x.bytes, let yBytes = y.bytes else {
            return unknown
        }
        let result = part(xBytes, Int(x.firstKey), Int(x.first), yBytes, Int(y.firstKey), Int(y.first))
        if result != 0 { return result }
        return part(
            xBytes + Int(x.firstKey) + Int(x.first), Int(x.secondKey), Int(x.second),
            yBytes + Int(y.firstKey) + Int(y.first), Int(y.secondKey), Int(y.second))
    }

    /// One part of two names: by collation key, and by the part's own bytes if those are equal.
    @inline(__always)
    private static func part(
        _ x: UnsafePointer<UInt8>, _ xKey: Int, _ xText: Int,
        _ y: UnsafePointer<UInt8>, _ yKey: Int, _ yText: Int
    ) -> Int {
        let keys = bytewise(x, xKey, y, yKey)
        return keys != 0 ? keys : bytewise(x + xKey, xText, y + yKey, yText)
    }

    @inline(__always)
    private static func bytewise(_ x: UnsafePointer<UInt8>, _ xCount: Int, _ y: UnsafePointer<UInt8>, _ yCount: Int)
        -> Int
    {
        let common = memcmp(x, y, min(xCount, yCount))
        if common != 0 { return common < 0 ? -1 : 1 }
        return xCount == yCount ? 0 : (xCount < yCount ? -1 : 1)
    }

    /// Two runs of bytes in the order of their bytes; the shorter of two that start alike first.
    static func bytewise(_ x: UnsafeBufferPointer<UInt8>, _ y: UnsafeBufferPointer<UInt8>) -> Int {
        guard let first = x.baseAddress, let second = y.baseAddress else {
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        }
        return bytewise(first, x.count, second, y.count)
    }

    /// Two texts in the order of their UTF-8 bytes.
    static func bytewise(_ a: String, _ b: String) -> Int {
        var (a, b) = (a, b)
        return a.withUTF8 { first in b.withUTF8 { bytewise(first, $0) } }
    }

    // MARK: Making keys

    /// Makes the records of a run of items and returns the memory they point into.
    private static func build(
        _ items: UnsafeBufferPointer<FileItem>, _ piece: Range<Int>, into records: UnsafeMutablePointer<Record>,
        order: ListOrder, collator: NameCollator
    ) -> Block {
        var capacity = max(256, piece.count * 48)
        var bytes = malloc(capacity)!.assumingMemoryBound(to: UInt8.self)
        var used = 0
        var offsets = [Int](repeating: 0, count: piece.count)
        var units: [UInt16] = []
        let limit = Int(UInt16.max)

        func reserve(_ more: Int) {
            guard capacity - used < more else { return }
            capacity = max(capacity * 2, used + more)
            bytes = realloc(bytes, capacity)!.assumingMemoryBound(to: UInt8.self)
        }
        /// Appends the collation key of UTF-16 text and returns its length; nil when there
        /// is none to be had.
        func appendKey(_ text: UnsafePointer<UInt16>, _ count: Int) -> Int? {
            guard count > 0 else { return 0 }
            var length = collator.writeKey(of: text, count, into: bytes + used, capacity: capacity - used)
            if length > capacity - used {
                reserve(length)
                length = collator.writeKey(of: text, count, into: bytes + used, capacity: capacity - used)
            }
            guard length > 0, length <= limit, length <= capacity - used else { return nil }
            used += length
            return length
        }
        /// UTF-16 units in a run of valid UTF-8: one for every character's first byte, two
        /// for a character of four bytes.
        func unitCount(_ text: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
            var count = 0
            for index in range where text[index] & 0xC0 != 0x80 { count += text[index] >= 0xF0 ? 2 : 1 }
            return count
        }

        for index in piece {
            let item = items[index]
            var record = Record()
            let isFolder = item.isFolder
            if isFolder { record.flags |= Record.folder }
            if !isFolder { record.primary = primary(of: item, order.key) }
            offsets[index - piece.lowerBound] = used
            // Files in the order they came need no key at all.
            guard isFolder || order.key != .unsorted else {
                records[index] = record
                continue
            }
            var name = item.name
            name.makeContiguousUTF8()
            let start = used
            let made: Bool =
                name.utf8.withContiguousStorageIfAvailable { text -> Bool in
                    guard text.count <= limit / 4 else { return false }
                    let isPlain = text.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
                    // Where the name is cut, as `FileItem.split` cuts it.
                    var baseCount = text.count
                    if !isFolder {
                        if let cut = FileItem.splitPoint(text) {
                            baseCount = cut == FileItem.noExtension ? text.count : cut
                        } else {
                            baseCount = FileItem.split(name).base.utf8.count
                        }
                    }
                    let hasExtension = baseCount < text.count
                    // The parts as ranges of the name's bytes.
                    let first: Range<Int>
                    let second: Range<Int>
                    if isFolder {
                        (first, second) = (0..<text.count, 0..<0)
                    } else if order.key == .ext {
                        (first, second) = (hasExtension ? (baseCount + 1)..<text.count : 0..<0, 0..<baseCount)
                    } else {
                        (first, second) = (0..<baseCount, baseCount..<text.count)
                    }
                    // The collator wants UTF-16; a part's place in it is found by counting.
                    units.removeAll(keepingCapacity: true)
                    if isPlain {
                        units.append(contentsOf: text.lazy.map(UInt16.init))
                    } else {
                        units.append(contentsOf: name.utf16)
                    }
                    func unitRange(_ range: Range<Int>) -> Range<Int> {
                        if isPlain { return range }
                        let lower = unitCount(text, 0..<range.lowerBound)
                        return lower..<(lower + unitCount(text, range))
                    }
                    return units.withUnsafeBufferPointer { units -> Bool in
                        reserve(text.count * 2 + 64)
                        let (firstUnits, secondUnits) = (unitRange(first), unitRange(second))
                        guard let firstKey = appendKey(units.baseAddress! + firstUnits.lowerBound, firstUnits.count)
                        else { return false }
                        reserve(text.count * 2 + 64)
                        (bytes + used).update(from: text.baseAddress! + first.lowerBound, count: first.count)
                        used += first.count
                        guard let secondKey = appendKey(units.baseAddress! + secondUnits.lowerBound, secondUnits.count)
                        else { return false }
                        reserve(text.count)
                        (bytes + used).update(from: text.baseAddress! + second.lowerBound, count: second.count)
                        used += second.count
                        (record.firstKey, record.first) = (UInt16(firstKey), UInt16(first.count))
                        (record.secondKey, record.second) = (UInt16(secondKey), UInt16(second.count))
                        return true
                    }
                } ?? false
            if !made {
                used = start
                record.flags |= Record.keyless
            }
            records[index] = record
        }
        // The memory has stopped moving: the records can point into it.
        for index in piece { records[index].bytes = UnsafePointer(bytes + offsets[index - piece.lowerBound]) }
        return Block(bytes)
    }
}

/// The system's collator for the user's language, which makes the collation keys that define
/// the order of names. It is reached directly, because Foundation offers a comparison of two
/// strings but not the keys, and that comparison is not an order (see `Sorter`). Should the
/// collator be missing, names are ordered by their lowercase forms: still an order in the
/// strict sense, only not the language's.
///
/// Immutable after `init`, and the collator may make keys on several threads at once.
final class NameCollator: @unchecked Sendable {
    /// The functions of the system's collation library (ICU) that a collator uses.
    struct Library {
        typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> OpaquePointer?
        typealias SetAttribute = @convention(c) (OpaquePointer, Int32, Int32, UnsafeMutablePointer<Int32>) -> Void
        typealias SortKey =
            @convention(c) (OpaquePointer, UnsafePointer<UInt16>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
        typealias Close = @convention(c) (OpaquePointer) -> Void

        let open: Open
        let setAttribute: SetAttribute
        let sortKey: SortKey
        let close: Close

        /// The system's library; nil when it cannot be reached.
        static let system: Self? = {
            guard let handle = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY),
                let open = dlsym(handle, "ucol_open"),
                let setAttribute = dlsym(handle, "ucol_setAttribute"),
                let sortKey = dlsym(handle, "ucol_getSortKey"),
                let close = dlsym(handle, "ucol_close")
            else { return nil }
            return Self(
                open: unsafeBitCast(open, to: Open.self),
                setAttribute: unsafeBitCast(setAttribute, to: SetAttribute.self),
                sortKey: unsafeBitCast(sortKey, to: SortKey.self),
                close: unsafeBitCast(close, to: Close.self))
        }()
    }

    /// The library's collator and the library; nil when there is none, and names are ordered
    /// by their lowercase forms. Making keys with one collator from several threads is safe as
    /// long as nobody changes its settings, which nothing does after `init`.
    private let collator: (handle: OpaquePointer, library: Library)?

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var cache: [String: NameCollator] = [:]

    /// The collator of the user's language as it is now.
    static var current: NameCollator {
        let identifier = Locale.current.collatorIdentifier ?? ""
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[identifier] { return known }
        let made = NameCollator(identifier: identifier)
        cache[identifier] = made
        return made
    }

    /// The same collator with runs of digits ordered by their value (`file2` before
    /// `file10`): the order of `Sorter.compare(_:_:numeric:)`, not of the panels' lists.
    static var currentNumeric: NameCollator {
        let identifier = Locale.current.collatorIdentifier ?? ""
        lock.lock()
        defer { lock.unlock() }
        if let known = numericCache[identifier] { return known }
        let made = NameCollator(identifier: identifier, numeric: true)
        numericCache[identifier] = made
        return made
    }

    /// Guarded by `lock`.
    nonisolated(unsafe) private static var numericCache: [String: NameCollator] = [:]

    /// The collator of a language (an ICU collator identifier such as `ru`), from `library`.
    /// Without the library, or when it cannot make the collator, names are ordered by their
    /// lowercase forms.
    init(identifier: String, numeric: Bool = false, library: Library? = .system) {
        var status: Int32 = 0
        guard let library, let handle = library.open(identifier, &status) else {
            collator = nil
            return
        }
        // Letters and accents count, case does not, punctuation counts like any character.
        let (alternateHandling, normalization, strength): (Int32, Int32, Int32) = (1, 4, 5)
        let (secondary, on, nonIgnorable): (Int32, Int32, Int32) = (1, 17, 21)
        library.setAttribute(handle, alternateHandling, nonIgnorable, &status)
        library.setAttribute(handle, normalization, on, &status)
        library.setAttribute(handle, strength, secondary, &status)
        if numeric {
            let numericCollation: Int32 = 7
            library.setAttribute(handle, numericCollation, on, &status)
        }
        guard status <= 0 else {
            library.close(handle)
            collator = nil
            return
        }
        collator = (handle, library)
    }

    /// Writes the key of a text given in UTF-16 into `buffer` and returns the key's length. A
    /// length above `capacity` means the key did not fit and nothing usable was written; the
    /// caller comes again with more room.
    func writeKey(
        of text: UnsafePointer<UInt16>, _ count: Int, into buffer: UnsafeMutablePointer<UInt8>, capacity: Int
    ) -> Int {
        if let (handle, library) = collator {
            return Int(library.sortKey(handle, text, Int32(clamping: count), buffer, Int32(min(capacity, Int(Int32.max)))))
        }
        // Without the system's collator: the lowercase form, which at least ignores case.
        let lowercase = Array(
            String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF16.self).lowercased().utf8)
        if lowercase.count <= capacity {
            lowercase.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: $0.count) }
        }
        return lowercase.count
    }

    /// Hands `body` the key of a name or of a part of one; an empty key for the empty text.
    /// The key lives in memory of the call's own, on the stack for names of ordinary length.
    func withKey<Result>(of text: String, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        // As the records of a list take it: in UTF-8, where a broken half of a character
        // (a name can come from the system with one) has become the replacement character.
        var text = text
        text.makeContiguousUTF8()
        let unitCount = text.utf16.count
        guard unitCount > 0 else { return body(UnsafeBufferPointer(start: nil, count: 0)) }
        return withUnsafeTemporaryAllocation(of: UInt16.self, capacity: unitCount) { units in
            _ = units.initialize(from: text.utf16)
            var capacity = unitCount * 6 + 32
            while true {
                let result: Result? = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity) { key in
                    let length = writeKey(
                        of: units.baseAddress!, unitCount, into: key.baseAddress!, capacity: capacity)
                    if length > capacity {
                        capacity = length
                        return nil
                    }
                    return body(UnsafeBufferPointer(start: key.baseAddress, count: max(length, 0)))
                }
                if let result { return result }
            }
        }
    }

    deinit {
        if let (handle, library) = collator { library.close(handle) }
    }
}
