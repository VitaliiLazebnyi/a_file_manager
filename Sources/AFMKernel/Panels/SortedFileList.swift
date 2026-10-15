/// A list that stays sorted while batches are added to it: what a directory that arrives in pieces
/// is collected in, on a background thread.
///
/// Each batch is sorted on its own and merged in, with parts of its own length only, so collecting
/// a directory in many batches costs about as much as one sort of it.
public struct SortedFileList: Sendable {
    /// A sorted part of the list: the places of its items in `arrived`, in order, with their keys
    /// in the same order.
    private struct Run: Sendable {
        /// The places of the items in `arrived`.
        let places: [UInt32]
        /// The keys of the items, in the same order.
        let keys: SortKeys
    }

    /// The order the items are kept in.
    public let order: ListOrder
    /// Every item added, in the order they came.
    private var arrived: [FileItem] = []
    /// The sorted parts, in the order they came, each longer than the one after it.
    ///
    /// A batch is merged only with parts of its own length or shorter, so every item takes part in
    /// a number of merges that grows with the logarithm of the list, not with the number of
    /// batches. A merge moves keys and places, never the items themselves.
    private var runs: [Run] = []

    /// The items in order: the parts merged, the earlier ones ahead of equal items of later ones.
    public var items: [FileItem] {
        guard var merged = runs.last else {
            return []
        }
        for run in runs.dropLast().reversed() { merged = self.merged(run, merged) }
        return Sorter.permute(arrived, by: merged.places)
    }

    /// An empty list that keeps its items in `order`.
    public init(order: ListOrder) {
        self.order = order
    }

    /// Adds a batch of items, in any order.
    public mutating func add(_ batch: [FileItem]) {
        guard !batch.isEmpty else {
            return
        }
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
        let (older, newer) = (first.keys.records, second.keys.records)
        var fromSecond: [Bool] = []
        var places: [UInt32] = []
        fromSecond.reserveCapacity(older.count + newer.count)
        places.reserveCapacity(older.count + newer.count)
        var (nextOlder, nextNewer) = (0, 0)
        while nextOlder < older.count, nextNewer < newer.count {
            var result = SortKeys.quick(newer[nextNewer], older[nextOlder], order)
            if result == SortKeys.unknown {
                result = Sorter.exactOrder(
                    arrived[Int(second.places[nextNewer])],
                    arrived[Int(first.places[nextOlder])],
                    by: order,
                    collator: first.keys.collator
                )
            }
            fromSecond.append(result < 0)
            if result < 0 {
                places.append(second.places[nextNewer])
                nextNewer += 1
            } else {
                places.append(first.places[nextOlder])
                nextOlder += 1
            }
        }
        fromSecond.append(contentsOf: repeatElement(false, count: older.count - nextOlder))
        places.append(contentsOf: first.places[nextOlder...])
        fromSecond.append(contentsOf: repeatElement(true, count: newer.count - nextNewer))
        places.append(contentsOf: second.places[nextNewer...])
        return Run(places: places, keys: SortKeys(merging: first.keys, second.keys, fromSecond: fromSecond))
    }
}
