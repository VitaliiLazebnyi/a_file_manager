import Foundation
import Testing

@testable import AFMKernel

private func entry(_ name: String, folder: Bool = false, size: Int64 = 0) -> FileItem {
    FileItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, isDirectory: folder, size: size)
}

/// Review 2, K001/K002, K021-K024: the order of names is the order of their collation keys,
/// then of their bytes, and the system's comparison of two strings is never asked.
@Suite struct Review2KernelSorting {
    @Test func theNamesThatStoppedTheProgramAreSortedLikeAnyOthers() {
        // The pair for which the system's localized comparison frees memory it does not own.
        let long = String(repeating: "\u{15}", count: 128) + "\u{FFFD}a" + String(repeating: "0", count: 66)
        let names = [
            long, "\u{FFFD}", "a", long + "b", "\u{FFFD}\u{FFFD}", "", "\u{0}",
            String(repeating: "\u{15}", count: 300)
        ]
        for (a, b) in names.flatMap({ a in names.map { (a, $0) } }) {
            let forth = Sorter.compareNames(a, b, collator: .current)
            let back = Sorter.compareNames(b, a, collator: .current)
            #expect(forth.rawValue == -back.rawValue)
        }
        for order in [ListOrder(key: .name), ListOrder(key: .ext, descending: true), ListOrder(key: .size)] {
            let items = names.map { entry($0) } + names.map { entry($0 + ".x", folder: true) }
            let sorted = Sorter.sort(items, by: order)
            #expect(sorted.count == items.count)
            #expect(
                zip(sorted, sorted.dropFirst()).allSatisfy {
                    Sorter.exactOrder($1, $0, by: order, collator: .current) >= 0
                })
            #expect(Sorter.sort(items.reversed(), by: order).map(\.name) == sorted.map(\.name))
        }
    }

    /// Every pair of a set is ordered one way only, and three names never go round in a circle.
    private func isAnOrder(_ names: [String], collator: NameCollator) -> Bool {
        let sorted = names.sorted { Sorter.compareNames($0, $1, collator: collator) == .orderedAscending }
        for (index, a) in sorted.enumerated() {
            for b in sorted[(index + 1)...] {
                // Later in the sorted list means after, for every pair and not only for neighbours.
                guard Sorter.compareNames(a, b, collator: collator) == .orderedAscending,
                    Sorter.compareNames(b, a, collator: collator) == .orderedDescending
                else { return false }
            }
        }
        return true
    }

    @Test func cyrillicNamesHaveOneOrder() {
        // The letters for which the localized comparison says "after" both ways round.
        let letters = ["и", "й", "е", "ё", "И", "Е", "я", "а"]
        var names = letters
        names += letters.flatMap { a in letters.map { a + $0 } }
        names += ["ий", "ийтф", "й", "ёе", "её", "еёе", "ийи", "йий"].flatMap { a in letters.prefix(3).map { a + $0 } }
        names = Array(Set(names.map { Array($0.utf8) })).map { String(decoding: $0, as: UTF8.self) }.sorted {
            Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
        }
        #expect(isAnOrder(names, collator: .current))
        #expect(isAnOrder(names, collator: NameCollator(identifier: "ru")))
    }

    @Test func languagesWithLettersOfTwoCharactersHaveOneOrder() {
        // Danish `aa`, Welsh `dd`, Spanish `ch`, Hungarian `cs`, Croatian `lj`: names of
        // plain ASCII, mixed case, longer than the two characters an earlier check looked at.
        let pieces = ["a", "A", "B", "d", "D", "c", "h", "l", "j", "s", "1"]
        var names: [String] = []
        for a in pieces.prefix(6) { for b in pieces { for c in pieces.prefix(4) { names.append(a + b + c) } } }
        names += ["aBa", "AA", "aAB", "1aA", "1AA", "ddd", "ddf", "aa", "Aa", "aA"]
        names = Array(Set(names)).sorted()
        for identifier in ["da", "nb", "cy", "es@collation=traditional", "hu", "hr", "en"] {
            let collator = NameCollator(identifier: identifier)
            #expect(isAnOrder(names, collator: collator), "\(identifier)")
            // Sorting on all cores gives that order, with nothing checked or put right afterwards.
            let items = (0..<40).flatMap { round in names.map { entry($0 + (round == 0 ? "" : "-\(round)")) } }
            let sorted = Sorter.sort(items, by: ListOrder(key: .name), collator: collator)
            #expect(
                zip(sorted, sorted.dropFirst()).allSatisfy {
                    Sorter.exactOrder($0, $1, by: ListOrder(key: .name), collator: collator) < 0
                }, "\(identifier)")
        }
    }

    @Test func namesThatDifferOnlyInWritingAreOrderedByTheirBytes() {
        let (composed, decomposed) = ("caf\u{E9}", "cafe\u{301}")
        #expect(composed == decomposed)
        let forth = Sorter.compareNames(composed, decomposed, collator: .current)
        let back = Sorter.compareNames(decomposed, composed, collator: .current)
        #expect(forth != .orderedSame && forth.rawValue == -back.rawValue)
        #expect(Sorter.compareNames(composed, composed, collator: .current) == .orderedSame)
        let a = Sorter.sort([entry(composed), entry(decomposed)], by: ListOrder()).map { Array($0.name.utf8) }
        let b = Sorter.sort([entry(decomposed), entry(composed)], by: ListOrder()).map { Array($0.name.utf8) }
        #expect(a == b)
    }

    @Test func aLongListOfNamesInOtherScriptsIsSortedByItsKeys() {
        // Long enough for the buckets; names the old sorter put right on one thread afterwards.
        var state: UInt64 = 99
        func next(_ limit: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(limit))
        }
        let letters = Array("ийеёИЕяаåøæÅñžłъ")
        let items = (0..<24_000).map { index -> FileItem in
            let name =
                String((0..<(2 + next(5))).map { _ in letters[next(letters.count)] }) + (index % 4 == 0 ? ".txt" : "")
            return entry(name + "\(index % 7)", folder: index % 13 == 0, size: Int64(next(5)))
        }
        for order in [
            ListOrder(key: .name, descending: true), ListOrder(key: .ext), ListOrder(key: .size, descending: true)
        ] {
            let sorted = Sorter.sort(items, by: order)
            #expect(sorted.count == items.count)
            #expect(
                zip(sorted, sorted.dropFirst()).allSatisfy {
                    Sorter.exactOrder($1, $0, by: order, collator: .current) >= 0
                },
                "by \(order)")
            // Turning the direction round is the same list as sorting the other way.
            let turned = ListOrder(key: order.key, descending: !order.descending)
            #expect(
                Sorter.resort(sorted, from: order, to: turned).map(\.name)
                    == Sorter.sort(sorted, by: turned).map(\.name), "\(order) turned")
            // Merging two sorted halves is the sorted whole.
            var halves = SortedFileList(order: order)
            halves.add(Array(items[..<10_000]))
            halves.add(Array(items[10_000...]))
            let merged = halves.items
            #expect(
                zip(merged, merged.dropFirst()).allSatisfy {
                    Sorter.exactOrder($1, $0, by: order, collator: .current) >= 0
                },
                "merged by \(order)")
        }
    }

    @Test func aNameTooLongForAKeyIsStillInItsPlace() {
        let long = String(repeating: "я", count: 20_000)
        let items = [entry(long + "b"), entry("я"), entry(long + "a"), entry("яя"), entry(long), entry("a")]
        let sorted = Sorter.sort(items, by: ListOrder())
        #expect(
            zip(sorted, sorted.dropFirst()).allSatisfy {
                Sorter.exactOrder($0, $1, by: ListOrder(), collator: .current) < 0
            })
        #expect(sorted.first?.name == "a")
    }
}
