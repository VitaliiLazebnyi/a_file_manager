import Foundation
import Testing

@testable import AFMKernel

/// The order of names is the order of their collation keys, then of their bytes, and the
/// system's comparison of two strings is never asked (review 2, K001/K002, K021-K024).
@Suite
internal struct NameOrderTests {
    /// An entry in `/tmp`.
    private static func entry(_ name: String, folder: Bool = false, size: Int64 = 0) -> FileItem {
        TmpEntries.make(name, folder: folder, size: size, time: 0)
    }

    /// Whether no entry of `items` comes after the one that follows it.
    private static func isSorted(_ items: [FileItem], by order: ListOrder) -> Bool {
        zip(items, items.dropFirst()).allSatisfy { Sorter.exactOrder($1, $0, by: order, collator: .current) >= 0 }
    }

    /// Every pair of a set is ordered one way only, and three names never go round in a circle.
    private static func isAnOrder(_ names: [String], collator: NameCollator) -> Bool {
        let sorted = names.sorted { Sorter.compareNames($0, $1, collator: collator) == .orderedAscending }
        for (index, first) in sorted.enumerated() {
            for second in sorted[(index + 1)...] {
                // Later in the sorted list means after, for every pair and not only for neighbours.
                guard Sorter.compareNames(first, second, collator: collator) == .orderedAscending,
                    Sorter.compareNames(second, first, collator: collator) == .orderedDescending
                else {
                    return false
                }
            }
        }
        return true
    }

    /// 24,000 entries named in Cyrillic and Scandinavian letters, some with an extension,
    /// some folders, with sizes that repeat.
    private static func namesInOtherScripts() -> [FileItem] {
        var random = SeededNumbers(seed: 99)
        let letters = Array("ийеёИЕяаåøæÅñžłъ")
        return (0..<24_000)
            .map { index -> FileItem in
                let name =
                    String((0..<(2 + random.next(5))).map { _ in letters[random.next(letters.count)] })
                    + (index.isMultiple(of: 4) ? ".txt" : "")
                return entry(name + "\(index % 7)", folder: index.isMultiple(of: 13), size: Int64(random.next(5)))
            }
    }

    /// Checks that the names for which the system's localized comparison freed memory it did
    /// not own are compared in both directions alike and sorted like any others, in every order.
    @Test
    internal func theNamesThatStoppedTheProgramAreSortedLikeAnyOthers() {
        let long = String(repeating: "\u{15}", count: 128) + "\u{FFFD}a" + String(repeating: "0", count: 66)
        let names = [
            long, "\u{FFFD}", "a", long + "b", "\u{FFFD}\u{FFFD}", "", "\u{0}",
            String(repeating: "\u{15}", count: 300)
        ]
        for (first, second) in names.flatMap({ first in names.map { (first, $0) } }) {
            let forth = Sorter.compareNames(first, second, collator: .current)
            let back = Sorter.compareNames(second, first, collator: .current)
            #expect(forth.rawValue == -back.rawValue)
        }
        for order in [ListOrder(key: .name), ListOrder(key: .ext, descending: true), ListOrder(key: .size)] {
            let items = names.map { Self.entry($0) } + names.map { Self.entry($0 + ".x", folder: true) }
            let sorted = Sorter.sort(items, by: order)
            #expect(sorted.count == items.count)
            #expect(Self.isSorted(sorted, by: order))
            #expect(Sorter.sort(items.reversed(), by: order).map(\.name) == sorted.map(\.name))
        }
    }

    /// Checks that names of the Cyrillic letters for which the localized comparison says
    /// "after" both ways round have one order, with the current language and with Russian.
    @Test
    internal func cyrillicNamesHaveOneOrder() {
        let letters = ["и", "й", "е", "ё", "И", "Е", "я", "а"]
        var names = letters
        names += letters.flatMap { first in letters.map { first + $0 } }
        names += ["ий", "ийтф", "й", "ёе", "её", "еёе", "ийи", "йий"]
            .flatMap { first in letters.prefix(3).map { first + $0 } }
        names = Set(names.map { Array($0.utf8) })
            .compactMap { String(bytes: $0, encoding: .utf8) }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        #expect(Self.isAnOrder(names, collator: .current))
        #expect(Self.isAnOrder(names, collator: NameCollator(identifier: "ru", numeric: false, library: .system)))
    }

    /// Danish `aa`, Welsh `dd`, Spanish `ch`, Hungarian `cs`, Croatian `lj`: names of plain
    /// ASCII, mixed case, longer than the two characters an earlier check looked at, have one
    /// order, and sorting on all cores gives it with nothing put right afterwards.
    @Test
    internal func languagesWithLettersOfTwoCharactersHaveOneOrder() {
        let pieces = ["a", "A", "B", "d", "D", "c", "h", "l", "j", "s", "1"]
        var names: [String] = []
        for first in pieces.prefix(6) {
            for second in pieces {
                names += pieces.prefix(4).map { first + second + $0 }
            }
        }
        names += ["aBa", "AA", "aAB", "1aA", "1AA", "ddd", "ddf", "aa", "Aa", "aA"]
        names = Array(Set(names)).sorted()
        for identifier in ["da", "nb", "cy", "es@collation=traditional", "hu", "hr", "en"] {
            let collator = NameCollator(identifier: identifier, numeric: false, library: .system)
            #expect(Self.isAnOrder(names, collator: collator), "\(identifier)")
            let items = (0..<40).flatMap { round in names.map { Self.entry($0 + (round == 0 ? "" : "-\(round)")) } }
            let sorted = Sorter.sort(items, by: ListOrder(key: .name), collator: collator)
            #expect(
                zip(sorted, sorted.dropFirst())
                    .allSatisfy { first, second in
                        panelsInOrder(first, second, by: ListOrder(key: .name), collator: collator)
                    },
                "\(identifier)"
            )
        }
    }

    /// Checks that names that differ only in how an accent is written are two names, ordered
    /// by their bytes the same way whichever comes first.
    @Test
    internal func namesThatDifferOnlyInWritingAreOrderedByTheirBytes() {
        let (composed, decomposed) = ("caf\u{E9}", "cafe\u{301}")
        #expect(composed == decomposed)
        let forth = Sorter.compareNames(composed, decomposed, collator: .current)
        let back = Sorter.compareNames(decomposed, composed, collator: .current)
        #expect(forth != .orderedSame && forth.rawValue == -back.rawValue)
        #expect(Sorter.compareNames(composed, composed, collator: .current) == .orderedSame)
        let one = Sorter.sort([Self.entry(composed), Self.entry(decomposed)], by: ListOrder())
            .map { Array($0.name.utf8) }
        let two = Sorter.sort([Self.entry(decomposed), Self.entry(composed)], by: ListOrder())
            .map { Array($0.name.utf8) }
        #expect(one == two)
    }

    /// A list long enough for the buckets, of names the old sorter put right on one thread
    /// afterwards, is sorted by its keys; turning it round and merging two halves agree.
    @Test
    internal func aLongListOfNamesInOtherScriptsIsSortedByItsKeys() {
        let items = Self.namesInOtherScripts()
        for order in [
            ListOrder(key: .name, descending: true), ListOrder(key: .ext), ListOrder(key: .size, descending: true)
        ] {
            let sorted = Sorter.sort(items, by: order)
            #expect(sorted.count == items.count)
            #expect(Self.isSorted(sorted, by: order), "by \(order)")
            let turned = ListOrder(key: order.key, descending: !order.descending)
            #expect(
                Sorter.resort(sorted, from: order, to: turned).map(\.name)
                    == Sorter.sort(sorted, by: turned).map(\.name),
                "\(order) turned"
            )
            let halves = [items[..<10_000], items[10_000...]].map { Sorter.sort(Array($0), by: order) }
            let merged = panelsCollected(halves, by: order)
            #expect(Self.isSorted(merged, by: order), "merged by \(order)")
        }
    }

    /// Checks that a name too long for a collation key still sorts into its place.
    @Test
    internal func aNameTooLongForAKeyIsStillInItsPlace() {
        let long = String(repeating: "я", count: 20_000)
        let items = [
            Self.entry(long + "b"), Self.entry("я"), Self.entry(long + "a"), Self.entry("яя"), Self.entry(long),
            Self.entry("a")
        ]
        let sorted = Sorter.sort(items, by: ListOrder())
        #expect(zip(sorted, sorted.dropFirst()).allSatisfy { panelsInOrder($0, $1, by: ListOrder()) })
        #expect(sorted.first?.name == "a")
    }
}
