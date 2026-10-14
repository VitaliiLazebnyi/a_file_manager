import Foundation
import Testing

@testable import AFMKernel

/// The collator and the records made of its keys, in the cases the system's library never brings.
@Suite
internal struct PanelsCollatorTests {
    private static let names = ["b.txt", "A.md", "c", "a.txt", "Ä.txt", "dir"]

    private static func item(_ name: String, folder: Bool = false) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/collator/\(name)"), name: name, isDirectory: folder, size: 1)
    }

    private static func records(_ mode: String) -> [SortKeys.Record] {
        let items = names.map { item($0, folder: $0 == "dir") }
        return SortKeys(items, order: ListOrder(), collator: PanelsFakeCollationLibrary.collator(mode)).records
    }

    /// The system's library is found; a library that is not there, or lacks the functions, is not.
    @Test
    internal func theLibraryIsLoadedOnlyWhenItHasEveryFunction() {
        #expect(CollationLibrary.system != nil)
        #expect(CollationLibrary.load("/no/such/library.dylib") == nil)
        #expect(CollationLibrary.load("/usr/lib/libz.1.dylib") == nil)
    }

    /// A collator that cannot be made, or whose settings fail, orders names by their lowercase forms.
    @Test
    internal func aCollatorThatCannotBeMadeFallsBackToLowercase() {
        for collator in ["missing", "status"].map(PanelsFakeCollationLibrary.collator) {
            #expect(Sorter.compareNames("B", "a", collator: collator) == .orderedDescending)
            #expect(Sorter.compareNames("a", "A", collator: collator) == .orderedDescending)
            #expect(collator.withKey(of: "AbC") { Array($0) } == Array("abc".utf8))
        }
        let defaultLanguage = NameCollator(identifier: nil, numeric: true, library: .system)
        #expect(Sorter.compareNames("file2", "file10", collator: defaultLanguage) == .orderedAscending)
    }

    /// A key longer than the room it was offered is made again with room for it.
    @Test
    internal func aKeyThatDoesNotFitIsMadeAgain() {
        let collator = PanelsFakeCollationLibrary.collator("grow")
        #expect(collator.withKey(of: "name") { $0.count } == 300)
        #expect(Self.records("grow").allSatisfy { $0.flags & SortKeys.Record.keyless == 0 && $0.firstKey == 300 })
        #expect(collator.withKey(of: "") { $0.count } == 0)
    }

    /// Without a key, a key too long for a record, or one that never fits: the record has none,
    /// and sorting works the comparison out from the names.
    @Test
    internal func recordsWithoutKeysAreSortedFromTheNames() {
        for mode in ["empty", "huge", "tight"] {
            #expect(Self.records(mode).allSatisfy { $0.flags & SortKeys.Record.keyless != 0 }, "\(mode)")
        }
        // Only the second part fails: the extension of a file sorted by name.
        let partly = Self.records("dotless")
        #expect(partly.contains { $0.flags & SortKeys.Record.keyless != 0 })
        #expect(partly.contains { $0.flags & SortKeys.Record.keyless == 0 })
        for mode in ["empty", "huge", "dotless", "plain"] {
            let collator = PanelsFakeCollationLibrary.collator(mode)
            let items = Self.names.map { Self.item($0, folder: $0 == "dir") }
            let sorted = Sorter.sort(items, by: ListOrder(), collator: collator)
            let expected = items.sorted { Sorter.exactOrder($0, $1, by: ListOrder(), collator: collator) < 0 }
            #expect(sorted == expected, "\(mode)")
        }
    }

    /// A name too long for a record has none; it still sorts in its place.
    @Test
    internal func aNameTooLongForARecordHasNone() {
        let long = String(repeating: "x", count: 20_000)
        let keys = SortKeys([Self.item(long), Self.item("a")], order: ListOrder(), collator: .current)
        #expect(keys.records[0].flags & SortKeys.Record.keyless != 0)
        #expect(keys.records[1].flags & SortKeys.Record.keyless == 0)
    }
}
