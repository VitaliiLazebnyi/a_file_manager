import Foundation
import Testing

@testable import AFMKernel

/// The comparison of names that plugins use in place of Foundation's localized one (review 2,
/// integration: K001 outside the panels' sorter, K023).
@Suite
internal struct NameComparisonTests {
    /// The pair of names Foundation's localized comparison ends the program for (K001,
    /// `Tests/Fuzz/repro/misc/sorter-cfcompare-abort.bin`).
    private var fatalPair: (String, String) {
        (String(repeating: "\u{15}", count: 128) + "\u{FFFD}a" + String(repeating: "0", count: 66), "\u{FFFD}")
    }

    /// The pair compares one way each way round, equal to itself, and sorts the same from either order.
    @Test
    internal func theNamesFoundationsComparisonDiesOfAreComparedLikeAnyOthers() {
        let (first, second) = fatalPair
        for numeric in [false, true] {
            let forward = Sorter.compare(first, second, numeric: numeric)
            let backward = Sorter.compare(second, first, numeric: numeric)
            #expect(forward != .orderedSame && forward.rawValue == -backward.rawValue)
            #expect(Sorter.compare(first, first, numeric: numeric) == .orderedSame)
            let sorted = Sorter.sorted([first, second, "plain", second, first], numeric: numeric) { $0 }
            #expect(sorted.count == 5 && Sorter.sorted(sorted.reversed(), numeric: numeric) { $0 } == sorted)
        }
    }

    /// For letters the localized comparison calls "descending" both ways round, the comparison
    /// is antisymmetric, equal only for equal names, agrees with the keys and is transitive.
    @Test
    internal func theOrderIsOneInTheStrictSenseWhereTheLocalizedOneIsNot() {
        let names = [
            "й", "ий", "и", "е", "ё", "ž", "z", "ñ", "n", "å", "a", "aa", "Й", "ИЙ", "A", "Z", "file2", "file10",
            "File1"
        ]
        for numeric in [false, true] {
            for left in names {
                for right in names {
                    checkPair(left, right, among: names, numeric: numeric)
                }
            }
        }
    }

    /// Digits count by their value only with `numeric`; otherwise names compare character by
    /// character, and items of one name keep the order they came in.
    @Test
    internal func digitsCountByTheirValueOnlyWhenThatIsAskedFor() {
        let names = ["file10.txt", "file2.txt", "File1.txt", "file1000000000000000000000.txt", "file9.txt"]
        #expect(
            Sorter.sorted(names, numeric: true) { $0 } == [
                "File1.txt", "file2.txt", "file9.txt", "file10.txt", "file1000000000000000000000.txt"
            ]
        )
        // As the panels' lists have names: character by character.
        #expect(
            Sorter.sorted(names) { $0 } == [
                "File1.txt", "file10.txt", "file1000000000000000000000.txt", "file2.txt", "file9.txt"
            ]
        )
        let pairs = [("b", 1), ("a", 2), ("b", 3), ("a", 4)]
        #expect(Sorter.sorted(pairs) { $0.0 }.map(\.1) == [2, 4, 1, 3])
    }

    /// The checks of one pair: one way each way round, equal only when the names are, the keys
    /// saying the same, and no circle with any third name.
    private func checkPair(_ left: String, _ right: String, among names: [String], numeric: Bool) {
        let forward = Sorter.compare(left, right, numeric: numeric)
        let backward = Sorter.compare(right, left, numeric: numeric)
        #expect(forward.rawValue == -backward.rawValue, "\(left) \(right)")
        #expect((forward == .orderedSame) == (left == right), "\(left) \(right)")
        // The keys say what the comparison says.
        let (leftKey, rightKey) = (Sorter.key(of: left, numeric: numeric), Sorter.key(of: right, numeric: numeric))
        #expect((leftKey < rightKey) == (forward == .orderedAscending), "\(left) \(right)")
        #expect((leftKey == rightKey) == (forward == .orderedSame), "\(left) \(right)")
        guard forward == .orderedAscending else {
            return
        }
        for third in names where Sorter.compare(right, third, numeric: numeric) == .orderedAscending {
            #expect(Sorter.compare(left, third, numeric: numeric) == .orderedAscending, "\(left) \(right) \(third)")
        }
    }
}
