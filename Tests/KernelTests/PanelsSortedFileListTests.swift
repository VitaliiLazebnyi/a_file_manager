import Foundation
import Testing

@testable import AFMKernel

/// A list collected in batches, as a directory that arrives in pieces is collected: always what
/// one sort of everything gives, and about as cheap as that sort, however many batches there are.
@Suite
internal struct PanelsSortedFileListTests {
    private static let orders = [
        ListOrder(), ListOrder(key: .ext, descending: true), ListOrder(key: .size), ListOrder(key: .date),
        ListOrder(key: .unsorted)
    ]

    private static func item(_ name: String, folder: Bool = false, size: Int64 = 0, in folderName: String = "a")
        -> FileItem
    {
        FileItem(url: URL(fileURLWithPath: "/sorted/\(folderName)/\(name)"), name: name, kind: .init(isDirectory: folder), stat: .init(size: size, modified: Date(timeIntervalSinceReferenceDate: TimeInterval(size % 7))))
    }

    /// Items of every kind, among them names that come more than once (from several folders),
    /// names that are equal for an order, and a name too long for a key.
    private static func items(_ count: Int) -> [FileItem] {
        (0..<count)
            .map { index in
                let name = index.isMultiple(of: 50) ? String(repeating: "я", count: 20_000) : "f\((index * 37) % 101)"
                return item(
                    index.isMultiple(of: 3) ? name + ".txt" : name,
                    folder: index.isMultiple(of: 13),
                    size: Int64(index % 5),
                    in: "d\(index)"
                )
            }
    }

    /// The time of the fastest of a few runs, which says most about the work itself on a
    /// machine that does other things as well.
    private static func fastest(_ runs: Int, _ work: () -> Void) -> TimeInterval {
        (0..<runs)
            .map { _ in
                let start = Date()
                work()
                return Date().timeIntervalSince(start)
            }
            .min() ?? 0
    }

    /// Whatever the size of the batches, the list is the one sort of everything gives.
    @Test(arguments: [1, 7, 64, 300])
    internal func batchesOfAnySizeGiveWhatOneSortGives(batch: Int) {
        let all = Self.items(900)
        for order in Self.orders {
            var list = SortedFileList(order: order)
            for start in stride(from: 0, to: all.count, by: batch) {
                list.add(Array(all[start..<min(start + batch, all.count)]))
            }
            // Equal items stay in the order they came: the same list, item for item.
            #expect(list.items == Sorter.sort(all, by: order), "\(order) in batches of \(batch)")
        }
    }

    /// Nothing added, or an empty batch, adds nothing.
    @Test
    internal func anEmptyListAndAnEmptyBatchHoldNothing() {
        var list = SortedFileList(order: ListOrder())
        #expect(list.items.isEmpty)
        list.add([])
        #expect(list.items.isEmpty && list.order == ListOrder())
        list.add([Self.item("one")])
        list.add([])
        #expect(list.items.map(\.name) == ["one"])
    }

    /// The list may be asked for after every batch, as the panel's loader does.
    @Test
    internal func theListCanBeReadBetweenBatches() {
        let all = Self.items(400)
        var list = SortedFileList(order: ListOrder(key: .size, descending: true))
        var added: [FileItem] = []
        for start in stride(from: 0, to: all.count, by: 30) {
            let batch = Array(all[start..<min(start + 30, all.count)])
            list.add(batch)
            added += batch
            #expect(list.items == Sorter.sort(added, by: list.order))
        }
    }

    /// A thousand batches take a few times as long as one sort of everything.
    ///
    /// Merging each batch into the whole list, as it once was, took about eighty times as long.
    @Test
    internal func manySmallBatchesCostAboutWhatOneSortCosts() {
        let all = (0..<60_000).map { Self.item("file\(($0 &* 7_919) % 60_000)", size: Int64($0 % 900)) }
        let batches = stride(from: 0, to: all.count, by: 60).map { Array(all[$0..<min($0 + 60, all.count)]) }
        let order = ListOrder(key: .name)
        var collected: [FileItem] = []
        let inBatches = Self.fastest(3) {
            var list = SortedFileList(order: order)
            for batch in batches { list.add(batch) }
            collected = list.items
        }
        var sorted: [FileItem] = []
        let once = Self.fastest(3) { sorted = Sorter.sort(all, by: order) }
        #expect(collected == sorted)
        #expect(inBatches < once * 25 + 0.05)
    }
}
