import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Properties of the order of lists and names (`Sorter`, `SortedFileList`), for random lists of
/// awkward names: sorting is a total order, stable, independent of how the list came in, and the
/// short cuts (resorting, merging, adding batches, long lists on all cores) give what a plain
/// sort gives.
@Suite
internal struct SortingProperties {
    /// A list and an order to put it in.
    private static let listAndOrder = KernelGenerators.items(KernelGenerators.name, lengths: 0...24)
        .flatMap { items in KernelGenerators.order.map { (items: items, order: $0) } }

    /// The locations of a list, which tell its entries apart.
    private static func locations(_ items: [FileItem]) -> [String] {
        items.map(\.url.path)
    }

    /// Whether neither entry has to come before the other.
    private static func areEqual(_ first: FileItem, _ second: FileItem, _ order: ListOrder) -> Bool {
        !panelsInOrder(first, second, by: order) && !panelsInOrder(second, first, by: order)
    }

    /// Whether no entry of the list belongs before one that comes earlier.
    private static func isInOrder(_ sorted: [FileItem], _ order: ListOrder) -> Bool {
        sorted.indices.allSatisfy { later in
            sorted[..<later].allSatisfy { !panelsInOrder(sorted[later], $0, by: order) }
        }
    }

    /// Whether entries that are equal for the order are in `sorted` in the order of `items`.
    private static func keepsEqualEntriesInPlace(
        _ items: [FileItem],
        _ sorted: [FileItem],
        _ order: ListOrder
    ) -> Bool {
        var place: [String: Int] = [:]
        for (index, item) in sorted.enumerated() {
            place[item.url.path] = index
        }
        return items.indices.allSatisfy { later in
            items[..<later]
                .allSatisfy { earlier in
                    !areEqual(earlier, items[later], order)
                        || place[earlier.url.path, default: 0] < place[items[later].url.path, default: 0]
                }
        }
    }

    /// Whether three entries are ordered without contradiction: at most one of two comes first,
    /// coming first carries over to a third, and so does being equal.
    private static func isConsistent(_ items: [FileItem], _ order: ListOrder) -> Bool {
        let (first, second, third) = (items[0], items[1], items[2])
        let before = { (one: FileItem, other: FileItem) in panelsInOrder(one, other, by: order) }
        let isStrict = !(before(first, second) && before(second, first))
        let isTransitive = !(before(first, second) && before(second, third)) || before(first, third)
        let equalIsTransitive =
            !(areEqual(first, second, order) && areEqual(second, third, order)) || areEqual(first, third, order)
        return isStrict && isTransitive && equalIsTransitive
    }

    /// Whether the order of three names has no contradiction and their keys compare like them.
    private static func namesAreConsistent(_ names: [String], numeric: Bool) -> Bool {
        let compare = { (one: String, other: String) in Sorter.compare(one, other, numeric: numeric) }
        let (first, second, third) = (names[0], names[1], names[2])
        let isReflexive = compare(first, first) == .orderedSame
        let isAntisymmetric = compare(first, second).rawValue == -compare(second, first).rawValue
        let isTransitive =
            !(compare(first, second) == .orderedAscending && compare(second, third) == .orderedAscending)
            || compare(first, third) == .orderedAscending
        let keys = (Sorter.key(of: first, numeric: numeric), Sorter.key(of: second, numeric: numeric))
        let keysAgree =
            (keys.0 < keys.1) == (compare(first, second) == .orderedAscending)
            && (keys.0 == keys.1) == (compare(first, second) == .orderedSame)
        return isReflexive && isAntisymmetric && isTransitive && keysAgree
    }

    /// The sorted list holds the same entries, and no entry comes after one it belongs before.
    @Test
    internal func sortingGivesTheSameEntriesInOrder() {
        expectProperty(Self.listAndOrder) { items, order in
            let sorted = Sorter.sort(items, by: order)
            return Self.locations(sorted).sorted() == Self.locations(items).sorted() && Self.isInOrder(sorted, order)
        }
    }

    /// The order is strict and transitive: of two entries at most one comes first, and what
    /// comes before something that comes before a third comes before the third.
    @Test
    internal func theOrderIsStrictAndTransitive() {
        let triple = KernelGenerators.items(KernelGenerators.name, lengths: 3...3)
            .flatMap { items in KernelGenerators.order.map { (items: items, order: $0) } }
        expectProperty(triple, count: 2_000) { items, order in Self.isConsistent(items, order) }
    }

    /// Entries that are equal for the order keep the order they came in.
    @Test
    internal func sortingIsStable() {
        expectProperty(Self.listAndOrder) { items, order in
            Self.keepsEqualEntriesInPlace(items, Sorter.sort(items, by: order), order)
        }
    }

    /// The order of the names does not depend on the order the list came in (except for files
    /// left unsorted, which keep it by definition).
    @Test
    internal func sortingDoesNotDependOnTheOrderTheListCameIn() {
        expectProperty(Self.listAndOrder) { items, order in
            let names = { (list: [FileItem]) in Sorter.sort(list, by: order).map { "\($0.isFolder) \($0.name)" } }
            return order.key == .unsorted
                || (names(items) == names(items.reversed()) && names(items) == names(items.shuffled()))
        }
    }

    /// A long list, sorted on all cores in buckets, is in the order a plain stable sort that
    /// compares two entries at a time gives.
    @Test
    internal func longListsAreSortedLikeShortOnes() {
        let long = KernelGenerators.longList(count: Sorter.parallelThreshold * 2 + 17)
            .flatMap { items in KernelGenerators.order.map { (items: items, order: $0) } }
        expectProperty(long, count: 3) { items, order in
            let reference = items.indices.sorted { first, second in
                panelsInOrder(items[first], items[second], by: order)
                    || (!panelsInOrder(items[second], items[first], by: order) && first < second)
            }
            return Self.locations(Sorter.sort(items, by: order)) == reference.map { items[$0].url.path }
        }
    }

    /// Resorting a sorted list gives what sorting it gives.
    @Test
    internal func resortingGivesWhatSortingGives() {
        let lists = Self.listAndOrder.flatMap { list in KernelGenerators.order.map { (list: list, new: $0) } }
        expectProperty(lists) { list, new in
            let sorted = Sorter.sort(list.items, by: list.order)
            return Self.locations(Sorter.resort(sorted, from: list.order, to: new))
                == Self.locations(Sorter.sort(sorted, by: new))
        }
    }

    /// Merging two sorted lists gives the sorted list of both, the first list's entries ahead of
    /// equal entries of the second.
    @Test
    internal func mergingGivesWhatSortingBothGives() {
        let pairs = Self.listAndOrder.flatMap { first in
            KernelGenerators.items(KernelGenerators.name, lengths: 0...24)
                .map { (first: first, second: KernelGenerators.numbered($0, from: 1_000)) }
        }
        expectProperty(pairs) { first, second in
            let order = first.order
            let halves = [Sorter.sort(first.items, by: order), Sorter.sort(second, by: order)]
            let merged = panelsCollected(halves, by: order)
            return Self.locations(merged) == Self.locations(Sorter.sort(first.items + second, by: order))
        }
    }

    /// A list collected in batches is the sorted list of all of them.
    @Test
    internal func aListCollectedInBatchesIsSorted() {
        let batches = KernelGenerators.items(KernelGenerators.name, lengths: 0...8)
            .array(0...5)
            .flatMap { batches in KernelGenerators.order.map { (batches: batches, order: $0) } }
        expectProperty(batches) { batches, order in
            var first = 0
            var all: [FileItem] = []
            var list = SortedFileList(order: order)
            for batch in batches {
                let numbered = KernelGenerators.numbered(batch, from: first)
                first += batch.count
                all += numbered
                list.add(numbered)
            }
            return Self.locations(list.items) == Self.locations(Sorter.sort(all, by: order))
        }
    }

    /// The order of two names: one way round only, never in a circle, a name equal to itself;
    /// the keys of names compare as the names do; with and without counting digits by value.
    @Test
    internal func theOrderOfNamesIsAnOrder() {
        let names = KernelGenerators.name.array(3...3)
            .flatMap { names in Generate.bool.map { (names: names, numeric: $0) } }
        expectProperty(names, count: 2_000) { names, numeric in Self.namesAreConsistent(names, numeric: numeric) }
    }

    /// Sorting by name keeps entries of the same name in the order they came, and puts the rest
    /// in the order of names.
    @Test
    internal func sortingByNameIsStableAndInOrder() {
        let names = KernelGenerators.crowdedName.array(0...30)
            .flatMap { names in Generate.bool.map { (names: names, numeric: $0) } }
        expectProperty(names) { names, numeric in
            let sorted = Sorter.sorted(Array(names.enumerated()), numeric: numeric) { $0.element }
            let inOrder = zip(sorted, sorted.dropFirst())
                .allSatisfy { earlier, later in
                    let result = Sorter.compare(earlier.element, later.element, numeric: numeric)
                    return result == .orderedAscending || (result == .orderedSame && earlier.offset < later.offset)
                }
            return inOrder && sorted.count == names.count
        }
    }
}
