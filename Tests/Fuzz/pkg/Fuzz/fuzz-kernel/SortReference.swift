import Foundation
import FuzzCore

@testable import AFMKernel

/// The order `Sorter` defines, worked out from its comparison alone.
internal enum SortReference {
    /// An item with its position in the input.
    internal typealias Indexed = (offset: Int, element: FileItem)

    /// The defined order, by the definition alone: a stable sort with the comparison the kernel publishes.
    internal static func sorted(_ items: [FileItem], _ order: ListOrder, collator: NameCollator) -> [FileItem] {
        let indexed = Array(items.enumerated())
        return mergeSort(indexed[...], order, collator: collator).map(\.element)
    }

    /// The position of the first item that should come before the one in front of it, if any.
    internal static func firstOutOfOrder(_ items: [FileItem], _ order: ListOrder) -> Int? {
        for index in items.indices.dropFirst()
        where (Sorter.exactOrder(items[index], items[index - 1], by: order, collator: .current) < 0) {
            return index
        }
        return nil
    }

    /// Whether "before" is an order at all on these items: without that no sort has one answer.
    internal static func comparatorIsConsistent(
        _ items: [FileItem],
        _ order: ListOrder,
        collator: NameCollator
    ) -> Bool {
        let count = min(items.count, 14)
        let before = { (lhs: Int, rhs: Int) -> Bool in
            (Sorter.exactOrder(items[lhs], items[rhs], by: order, collator: collator) < 0)
        }
        for first in 0..<count {
            for second in 0..<count where !pairIsConsistent(first, second, count: count, before: before) {
                return false
            }
        }
        return true
    }

    /// The order of names as `Sorter` defines it.
    ///
    /// Of two names that are not the same bytes exactly one comes first (collation key, then the
    /// bytes), whatever the names are.
    internal static func checkNameOrder(_ items: [FileItem], collator: NameCollator, _ which: String) {
        let names = items.prefix(14).map(\.name)
        for lhs in names {
            for rhs in names {
                let forward = Sorter.compareNames(lhs, rhs, collator: collator)
                let backward = Sorter.compareNames(rhs, lhs, collator: collator)
                let same = Array(lhs.utf16) == Array(rhs.utf16)
                fzCheck(
                    (forward == .orderedSame) == same,
                    "sorter-names-equal-without-being-the-same" + which,
                    "\(Array(lhs.utf16)) \(Array(rhs.utf16)): \(forward.rawValue)"
                )
                fzCheck(
                    forward.rawValue == -backward.rawValue,
                    "sorter-names-order-not-antisymmetric" + which,
                    "\(Array(lhs.utf16)) \(Array(rhs.utf16)): \(forward.rawValue) and \(backward.rawValue)"
                )
            }
        }
    }

    /// Whether one pair is in at most one order, and the order and the equivalence are transitive for it.
    private static func pairIsConsistent(
        _ first: Int,
        _ second: Int,
        count: Int,
        before: (Int, Int) -> Bool
    ) -> Bool {
        let forward = before(first, second)
        let backward = before(second, first)
        if forward, backward {
            return false
        }
        for third in 0..<count where forward && before(second, third) && !before(first, third) {
            return false
        }
        // Equivalence is transitive as well.
        guard !forward, !backward else {
            return true
        }
        for third in 0..<count {
            let secondThird = before(second, third)
            let thirdSecond = before(third, second)
            let firstThird = before(first, third)
            let thirdFirst = before(third, first)
            if !secondThird, !thirdSecond, firstThird || thirdFirst {
                return false
            }
        }
        return true
    }

    /// A merge sort that never asks for more than "a before b".
    private static func mergeSort(
        _ slice: ArraySlice<Indexed>,
        _ order: ListOrder,
        collator: NameCollator
    ) -> [Indexed] {
        if slice.count <= 1 {
            return Array(slice)
        }
        let mid = slice.startIndex + slice.count / 2
        return merge(
            mergeSort(slice[..<mid], order, collator: collator),
            mergeSort(slice[mid...], order, collator: collator),
            order,
            collator: collator
        )
    }

    /// Two sorted runs as one; of equal items the one of `left` comes first.
    private static func merge(
        _ left: [Indexed],
        _ right: [Indexed],
        _ order: ListOrder,
        collator: NameCollator
    ) -> [Indexed] {
        var out: [Indexed] = []
        out.reserveCapacity(left.count + right.count)
        var (leftIndex, rightIndex) = (0, 0)
        while leftIndex < left.count, rightIndex < right.count {
            let (later, earlier) = (right[rightIndex].element, left[leftIndex].element)
            if Sorter.exactOrder(later, earlier, by: order, collator: collator) < 0 {
                out.append(right[rightIndex])
                rightIndex += 1
            } else {
                out.append(left[leftIndex])
                leftIndex += 1
            }
        }
        out.append(contentsOf: left[leftIndex...])
        out.append(contentsOf: right[rightIndex...])
        return out
    }
}
