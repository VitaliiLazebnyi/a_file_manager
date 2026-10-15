import Foundation
import Testing

@testable import AFMKernel

/// Sorting by every key gives the order the comparison of two items defines, for names of
/// every kind, long lists sorted on all cores, every language, merging, adding in batches and
/// turning the direction round.
@Suite
internal struct SortingByKeyTests {
    /// Every key in both directions.
    private static let everyOrder = [SortKey.name, .ext, .size, .date, .unsorted]
        .flatMap { key in
            [ListOrder(key: key), ListOrder(key: key, descending: true)]
        }

    /// Plain ASCII and Danish, Swedish, German and Spanish letters, for the languages test.
    private static let syllables = [
        "aa", "a", "å", "ä", "ae", "æ", "ö", "ø", "o", "z", "y", "ü", "u", "w", "v", "ch", "c", "h", "Aa", "Z",
        "ll", "l", "ñ", "n"
    ]

    /// The comparisons of languages with ideas of their own, and of none.
    private static var collators: [NameCollator] {
        let languages = ["da", "sv", "de@collation=phonebook", "es@collation=traditional", "cs"]
        return languages.map { NameCollator(identifier: $0, numeric: false, library: .system) }
            + [NameCollator(identifier: "", numeric: false, library: nil)]
    }

    /// The order is defined by `exactOrder`; a stable sort with it is what sorting has to give.
    private static func reference(_ items: [FileItem], _ order: ListOrder) -> [FileItem] {
        items.sorted { Sorter.exactOrder($0, $1, by: order, collator: .current) < 0 }
    }

    /// Name and extension cut the slow way, character by character.
    private static func splitByCharacters(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// An entry in `/tmp`.
    private static func entry(_ name: String, folder: Bool = false, size: Int64 = 0, time: TimeInterval = 0)
        -> FileItem
    {
        TmpEntries.make(name, folder: folder, size: size, time: time)
    }

    /// Names of every kind the order has to cope with: case, digits, punctuation, accents
    /// written in one or two characters, other scripts, dots in odd places.
    private static func variedItems(_ count: Int, seed: UInt64) -> [FileItem] {
        var random = SeededNumbers(seed: seed)
        let words = [
            "report", "Report", "REPORT", "img_", "IMG-", "read me", "a", "B", "z", "data(1)", "x_y", "résumé",
            "re\u{301}sume\u{301}",
            "Übung", "übung", "uebung", "été", "naïve", "ñandú", "Ångström", "straße", "strasse", "İstanbul", "файл",
            "Файл", "отчёт",
            "写真", "資料", "ｆｕｌｌ", "full", "한국어", "ﬁle", "file", "e\u{301}", "é", "#tag", "~temp", "100", "20", "3"
        ]
        let extensions = ["txt", "TXT", "Txt", "md", "jpg", "JPG", "tar.gz", "", "", "c", "h", "é", "файл", "x."]
        return (0..<count)
            .map { _ in
                var name = words[random.next(words.count)]
                if random.next(3) > 0 {
                    name += String(random.next(max(count / 3, 4)))
                }
                if random.next(5) == 0 {
                    name = "." + name
                }
                let folder = random.next(8) == 0
                let ext = extensions[random.next(extensions.count)]
                if !ext.isEmpty, random.next(folder ? 4 : 1) == 0 {
                    name += "." + ext
                }
                return entry(name, folder: folder, size: Int64(random.next(40)), time: TimeInterval(random.next(60)))
            }
    }

    /// Checks that `sort` gives what a stable sort with the comparison gives, for every kind of name.
    @Test
    internal func everyKindOfNameComesOutInTheOrderOfTheComparison() {
        for (count, seed) in [(0, 1), (1, 2), (2, 3), (700, 4), (3_000, 5)] as [(Int, UInt64)] {
            let items = Self.variedItems(count, seed: seed)
            for order in Self.everyOrder {
                #expect(Sorter.sort(items, by: order) == Self.reference(items, order), "\(count) items by \(order)")
            }
        }
    }

    /// Checks that a list long enough to be dealt into buckets, with many names that are equal
    /// or nearly so, is sorted on all cores into the same order.
    @Test
    internal func aLongListOnAllCoresComesOutTheSame() {
        let items = Self.variedItems(12_000, seed: 6)
        for order in [
            ListOrder(key: .name), ListOrder(key: .ext, descending: true), ListOrder(key: .size),
            ListOrder(key: .unsorted)
        ] {
            #expect(
                Sorter.sort(items, by: order).map(\.name) == Self.reference(items, order).map(\.name),
                "by \(order)"
            )
        }
    }

    /// Danish sorts `aa` and the letters with rings and strokes after `z`; Swedish and German each have their own
    /// ideas.
    ///
    /// Whatever the language, the sorted list is the one its comparison of two items defines, and the comparison is an
    /// order: the same list comes out however the items were shuffled before.
    @Test
    internal func eachLanguageSortsByItsOwnKeysAndNothingElse() {
        var random = SeededNumbers(seed: 11)
        let items = (0..<2_500)
            .map { index -> FileItem in
                let name =
                    (0..<(1 + random.next(3))).map { _ in Self.syllables[random.next(Self.syllables.count)] }.joined()
                    + String(random.next(50)) + "-\(index)"
                return Self.entry(
                    index.isMultiple(of: 3) ? name + ".txt" : name,
                    folder: index.isMultiple(of: 11),
                    size: Int64(random.next(9))
                )
            }
        for order in [ListOrder(key: .name), ListOrder(key: .ext, descending: true), ListOrder(key: .size)] {
            for collator in Self.collators {
                let sorted = Sorter.sort(items, by: order, collator: collator)
                #expect(
                    sorted == items.sorted { Sorter.exactOrder($0, $1, by: order, collator: collator) < 0 },
                    "by \(order)"
                )
                #expect(
                    Sorter.sort(items.reversed(), by: order, collator: collator) == sorted,
                    "shuffled, by \(order)"
                )
            }
        }
    }

    /// Printable ASCII is the case the keys decide alone, without a check: every pair of short
    /// names made of characters that sort in surprising places, and longer ones, are in the
    /// order of the comparison.
    @Test
    internal func plainNamesAreDecidedByTheKeysAlone() {
        let characters = [
            "a", "A", "b", "Z", "0", "9", " ", ".", "-", "_", "~", "!", "(", "[", "{", "'", "+", "=", "@", "#"
        ]
        var names = characters + characters.flatMap { first in characters.map { first + $0 } }
        names += characters.flatMap { first in characters.map { "ab" + first + "c" + $0 + ".x" + first } }
        let items = names.enumerated().map { Self.entry($1, folder: $0.isMultiple(of: 7)) }
        for order in [ListOrder(key: .name), ListOrder(key: .ext), ListOrder(key: .name, descending: true)] {
            #expect(
                Sorter.sort(items, by: order).map(\.name) == Self.reference(items, order).map(\.name),
                "by \(order)"
            )
        }
    }

    /// Checks that merging two sorted halves, and adding batch after batch to a sorted list,
    /// both give the sorted whole.
    @Test
    internal func batchesMergedOrAddedGiveTheSortedList() {
        let items = Self.variedItems(1_500, seed: 7)
        for order in Self.everyOrder {
            let (first, second) = (Array(items[..<900]), Array(items[900...]))
            let merged = panelsCollected([Sorter.sort(first, by: order), Sorter.sort(second, by: order)], by: order)
            #expect(merged == Self.reference(first + second, order), "merge by \(order)")
            var list = SortedFileList(order: order)
            var added: [FileItem] = []
            for start in stride(from: 0, to: items.count, by: 400) {
                let batch = Array(items[start..<min(start + 400, items.count)])
                list.add(batch)
                added += batch
                #expect(list.items.count == added.count)
            }
            #expect(list.items == Self.reference(items, order), "batches by \(order)")
        }
    }

    /// Checks that turning a sorted list round, or sorting it by another key, gives what
    /// sorting gives, with names that are equal for the order (the same name twice) and without.
    @Test
    internal func resortingGivesWhatSortingGives() {
        let seeded = Self.variedItems(800, seed: 9)
        let unique = seeded.enumerated()
            .map { index, item in
                Self.entry("n\(index)-" + item.name, folder: item.isFolder, size: item.size)
            }
        for items in [Self.variedItems(800, seed: 8), unique] {
            for order in Self.everyOrder {
                let sorted = Sorter.sort(items, by: order)
                let turned = ListOrder(key: order.key, descending: !order.descending)
                #expect(
                    Sorter.resort(sorted, from: order, to: turned) == Sorter.sort(sorted, by: turned),
                    "\(order) turned round"
                )
                let other = ListOrder(key: order.key == .size ? .name : .size)
                #expect(Sorter.resort(sorted, from: order, to: other) == Sorter.sort(sorted, by: other))
            }
        }
    }

    /// Checks that cutting a name into name and extension by its bytes gives what cutting it by
    /// its characters gives, for accents, other scripts, emoji and dots in odd places.
    @Test
    internal func namesAreCutByTheirBytesAsByTheirCharacters() {
        let names =
            [
                "a.b", ".a", "a.", "a", "", ".", "..", "a..b", "é.é", "a.\u{301}b", "a.b.\u{301}", "a\u{301}.b",
                "写真.jpg", "x.写真", "\u{600}.a",
                "a.b\u{301}", "…", "a.b c.d", "🇯🇵.🇯🇵", "👨‍👩‍👧.txt"
            ] + Self.variedItems(300, seed: 10).map(\.name)
        for name in names {
            #expect(FileItem.split(name) == Self.splitByCharacters(name), "\(name.debugDescription)")
        }
    }
}
