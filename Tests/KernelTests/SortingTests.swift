import AFMKernel
import Foundation
import Testing

/// The basic rules of sorting: folders first and by name, by extension, in arrival order,
/// header clicks, merging, lists collected in batches and long lists sorted on all cores.
@Suite
internal struct SortingTests {
    /// An entry in `/tmp`.
    private static func item(_ name: String, folder: Bool = false, size: Int64 = 0, time: TimeInterval = 0)
        -> FileItem
    {
        TmpEntries.make(name, folder: folder, size: size, time: time)
    }

    /// The entry number `index` of batch `batch`: names, kinds, sizes and dates mixed.
    private static func batchItem(_ index: Int, batch: Int) -> FileItem {
        item(
            "f\((index * 17 + batch * 5) % 97)-\(batch).\(["txt", "md"][index % 2])",
            folder: index.isMultiple(of: 9),
            size: Int64(index % 4),
            time: TimeInterval((index * 31 + batch) % 13)
        )
    }

    /// Checks that folders come first and stay by name when files are sorted by size.
    @Test
    internal func foldersFirstAndAlwaysByName() {
        let items = [
            Self.item("b.txt", size: 1), Self.item("zeta", folder: true), Self.item("a.txt", size: 9),
            Self.item("Alpha", folder: true)
        ]
        let sorted = Sorter.sort(items, by: ListOrder(key: .size, descending: true))
        #expect(sorted.map(\.name) == ["Alpha", "zeta", "a.txt", "b.txt"])
    }

    /// Checks that equal extensions fall back to the name.
    @Test
    internal func sortsByExtensionThenName() {
        let items = [Self.item("b.txt"), Self.item("a.txt"), Self.item("c.md")]
        #expect(Sorter.sort(items, by: ListOrder(key: .ext)).map(\.name) == ["c.md", "a.txt", "b.txt"])
    }

    /// Checks that Unsorted still puts folders first, by name, and leaves the files as they came.
    @Test
    internal func unsortedKeepsFilesInArrivalOrder() {
        let items = [Self.item("b.txt"), Self.item("z", folder: true), Self.item("a.txt"), Self.item("m", folder: true)]
        #expect(Sorter.sort(items, by: ListOrder(key: .unsorted)).map(\.name) == ["m", "z", "b.txt", "a.txt"])
    }

    /// Clicking the header of the current key turns its direction round; another key starts
    /// in its own direction (dates newest first, extensions ascending).
    @Test
    internal func timeAndSizeStartDescending() {
        #expect(SortKey.date.startsDescending && SortKey.size.startsDescending)
        #expect(!SortKey.name.startsDescending && !SortKey.ext.startsDescending && !SortKey.unsorted.startsDescending)
    }

    /// Checks that merging a sorted batch into a sorted list gives the sorted whole, also with
    /// an empty side.
    @Test
    internal func mergingABatchEqualsSortingEverything() {
        let order = ListOrder(key: .size, descending: true)
        let first = (0..<40).map { Self.item("a\($0).txt", folder: $0.isMultiple(of: 7), size: Int64($0 * 37 % 11)) }
        let second = (0..<25).map { Self.item("b\($0).txt", folder: $0.isMultiple(of: 5), size: Int64($0 * 13 % 11)) }
        let merged = panelsCollected([Sorter.sort(first, by: order), Sorter.sort(second, by: order)], by: order)
        #expect(merged.map(\.name) == Sorter.sort(first + second, by: order).map(\.name))
        #expect(panelsCollected([[], second], by: order).count == 25)
        #expect(panelsCollected([first, []], by: order).count == 40)
    }

    /// Checks that a list that grows batch by batch is sorted after every batch, in every order.
    @Test
    internal func aListCollectedInBatchesIsAlwaysSorted() {
        for order in [
            ListOrder(), ListOrder(key: .ext), ListOrder(key: .date, descending: true), ListOrder(key: .unsorted)
        ] {
            var list = SortedFileList(order: order)
            var all: [FileItem] = []
            for batch in 0..<6 {
                let items = (0..<30).map { Self.batchItem($0, batch: batch) }
                list.add(items)
                all += items
                #expect(list.items.map(\.name) == Sorter.sort(all, by: order).map(\.name))
            }
            #expect(list.items.count == 180)
        }
    }

    /// Above the threshold the list is sorted in parallel runs and merged; the result is what
    /// the simple sort gives.
    @Test
    internal func aLongListSortedOnAllCoresEqualsTheSimpleSort() {
        let count = 60_000
        let items = (0..<count)
            .map { index in
                Self.item(
                    "file\((index &* 7_919) % count)-\(index % 3).\(["txt", "md", "swift"][index % 3])",
                    folder: index.isMultiple(of: 97),
                    size: Int64((index &* 31) % 5_000),
                    time: TimeInterval((index &* 17) % 9_000)
                )
            }
        for order in [
            ListOrder(), ListOrder(key: .size, descending: true), ListOrder(key: .date), ListOrder(key: .unsorted)
        ] {
            let simple = items.sorted { panelsInOrder($0, $1, by: order) }
            #expect(Sorter.sort(items, by: order).map(\.name) == simple.map(\.name))
        }
    }
}
