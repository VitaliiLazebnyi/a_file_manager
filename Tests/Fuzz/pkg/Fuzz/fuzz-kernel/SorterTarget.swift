import FuzzCore

@testable import AFMKernel

/// The `sorter` target: `Sorter.sort`, `resort`, `merge` and `SortedFileList` against the defined order.
@MainActor
internal enum SorterTarget {
    /// The target.
    internal static func make() -> FuzzTarget {
        FuzzTarget(
            "sorter",
            maxLen: 2_048,
            seeds: {
                [
                    Array(0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) },
                    [1, 0, 30] + Array(repeating: UInt8(1), count: 120), [3, 1, 40] + (0..<160).map { UInt8($0) },
                    [0x10, 2, 12] + (0..<90).map { UInt8(truncatingIfNeeded: 255 - $0) }
                ]
            },
            run: run
        )
    }

    /// Sorts the items of one input every way there is and compares.
    private static func run(_ bytes: [UInt8]) {
        FuzzState.uniqueNames = false
        var choices = Choices(bytes)
        let mode = choices.byte()
        let order = nextOrder(&choices)
        var items = nextItems(&choices, max: 48, besides: [])
        if mode & 0x0F == 0, !items.isEmpty {
            items = grown(items, mode: mode)
        }
        items = tagged(items)
        let (sorted, reference) = checkSort(items, order)
        guard items.count <= 200 else {
            return
        }
        checkResortAndMerge(&choices, items: items, order: order, sorted: sorted)
        checkSortedList(&choices, items: items, order: order, reference: reference)
    }

    /// Long enough for the parallel path: the same names again and again, with a counter in some.
    private static func grown(_ basis: [FileItem], mode: UInt8) -> [FileItem] {
        var grown: [FileItem] = []
        grown.reserveCapacity(9_000)
        var counter = 0
        while grown.count < 8_200 + Int(mode >> 4) * 40 {
            let item = basis[counter % basis.count]
            let name = (counter / basis.count).isMultiple(of: 3) ? item.name : item.name + String(counter % 97)
            grown.append(
                FileItem(
                    url: item.url,
                    name: name,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage,
                    size: item.size &+ Int64(counter % 5),
                    modified: item.modified
                )
            )
            counter += 1
        }
        return grown
    }

    /// The suffix of a finding's key when "before" is no order on these items (checked up to 60 items).
    private static func consistencyKey(_ items: [FileItem], _ order: ListOrder) -> String {
        items.count > 60 || SortReference.comparatorIsConsistent(items, order, collator: .current)
            ? "" : "-inconsistent-comparator"
    }

    /// `Sorter.sort` with and without the system's collator; returns the sort with it and the defined order.
    private static func checkSort(
        _ items: [FileItem],
        _ order: ListOrder
    ) -> (sorted: [FileItem], reference: [FileItem]) {
        let sorted = Sorter.sort(items, by: order)
        fzCheck(
            ids(sorted).sorted() == Array(items.indices),
            "sorter-not-a-permutation",
            "\(order) \(describe(items))"
        )
        let plain = Sorter.sort(items, by: order, collator: .unavailable)
        fzCheck(
            ids(plain).sorted() == Array(items.indices),
            "sorter-not-a-permutation-nokeys",
            "\(order) \(describe(items))"
        )
        let reference = SortReference.sorted(items, order, collator: .current)
        checkComparison(items, order)
        if let index = SortReference.firstOutOfOrder(sorted, order) {
            fzFail(
                "sorter-out-of-order" + consistencyKey(items, order),
                "\(order) at \(index): \(describe(Array(sorted[(index - 1)...index]))) of \(describe(items))"
            )
        }
        fzCheck(
            ids(sorted) == ids(reference),
            "sorter-differs-from-definition" + consistencyKey(items, order),
            "\(order)\n got \(ids(sorted).prefix(60))\nwant \(ids(reference).prefix(60))\n\(describe(items))"
        )
        // Without the system's collator the order is that of the fallback keys: its own definition.
        // (A second slow sort of the 8,000-item lists would take the time of the run: they are compared up
        // to 1,000.)
        let plainReference =
            items.count <= 1_000 ? SortReference.sorted(items, order, collator: .unavailable) : plain
        fzCheck(
            ids(plain) == ids(plainReference),
            "sorter-nokeys-differs-from-definition" + consistencyKey(items, order),
            "\(order)\n got \(ids(plain).prefix(60))\nwant \(ids(plainReference).prefix(60))\n\(describe(items))"
        )
        return (sorted, reference)
    }

    /// "Before" is an order and names compare as defined, with the system's collator and the fallback keys.
    private static func checkComparison(_ items: [FileItem], _ order: ListOrder) {
        // The order is defined by collation keys and then bytes, so "before" is an order in the strict
        // sense for any names, with the system's collator and with the fallback keys alike.
        fzCheck(
            SortReference.comparatorIsConsistent(items, order, collator: .current),
            "sorter-comparison-is-not-an-order",
            "\(order) \(describe(items))"
        )
        fzCheck(
            SortReference.comparatorIsConsistent(items, order, collator: .unavailable),
            "sorter-comparison-is-not-an-order-nokeys",
            "\(order) \(describe(items))"
        )
        SortReference.checkNameOrder(items, collator: .current, "")
        SortReference.checkNameOrder(items, collator: .unavailable, "-nokeys")
    }

    /// Turning the order round, and batches merged into a sorted list.
    private static func checkResortAndMerge(
        _ choices: inout Choices,
        items: [FileItem],
        order: ListOrder,
        sorted: [FileItem]
    ) {
        // Turning the order round gives what sorting anew gives.
        let other = choices.bool() ? ListOrder(key: order.key, descending: !order.descending) : nextOrder(&choices)
        let resorted = Sorter.resort(sorted, from: order, to: other)
        fzCheck(
            ids(resorted) == ids(Sorter.sort(sorted, by: other)),
            "resort-differs-from-sort" + consistencyKey(items, order),
            "\(order) -> \(other) \(describe(sorted))"
        )
        // Batches merged into a sorted list.
        let cut = items.isEmpty ? 0 : choices.int(items.count + 1)
        let first = Sorter.sort(Array(items[..<cut]), by: order)
        let second = Sorter.sort(Array(items[cut...]), by: order)
        let merged = Sorter.merge(first, with: second, by: order)
        fzCheck(
            ids(merged).sorted() == Array(items.indices),
            "merge-not-a-permutation",
            "\(order) cut \(cut) \(describe(items))"
        )
        if let index = SortReference.firstOutOfOrder(merged, order) {
            fzFail(
                "merge-out-of-order" + consistencyKey(items, order),
                "\(order) cut \(cut) at \(index): \(describe(Array(merged[(index - 1)...index]))) of \(describe(items))"
            )
        }
    }

    /// A `SortedFileList` filled in batches of one to nine.
    private static func checkSortedList(
        _ choices: inout Choices,
        items: [FileItem],
        order: ListOrder,
        reference: [FileItem]
    ) {
        var list = SortedFileList(order: order)
        var start = 0
        while start < items.count {
            let count = 1 + choices.int(9)
            list.add(Array(items[start..<min(items.count, start + count)]))
            start += count
        }
        fzCheck(
            ids(list.items).sorted() == Array(items.indices),
            "sortedlist-not-a-permutation",
            "\(order) \(describe(items))"
        )
        if let index = SortReference.firstOutOfOrder(list.items, order) {
            fzFail(
                "sortedlist-out-of-order" + consistencyKey(items, order),
                "\(order) at \(index): \(describe(Array(list.items[(index - 1)...index]))) of \(describe(items))"
            )
        }
        if order.key != .unsorted {
            fzCheck(
                ids(list.items) == ids(reference),
                "sortedlist-differs-from-definition" + consistencyKey(items, order),
                "\(order)\n got \(ids(list.items).prefix(60))\nwant \(ids(reference).prefix(60))\n\(describe(items))"
            )
        }
    }
}
