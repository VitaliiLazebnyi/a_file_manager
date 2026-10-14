import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// The pieces the panel's lists are made of: marks, names as they are written, filtered lists,
/// counts, and the pairing of entries that share a name.
@Suite
internal struct PanelsListWorkTests {
    private static func item(_ name: String, size: Int64 = 1, folder: Bool = false, in parent: String = "/w")
        -> FileItem
    {
        FileItem(url: URL(fileURLWithPath: "\(parent)/\(name)"), name: name, isDirectory: folder, size: size)
    }

    /// A string the system bridged, whose UTF-8 is not in one piece.
    private static func bridged(_ text: String) -> String {
        let units = Array(text.utf16)
        return CFStringCreateWithCharacters(nil, units, units.count) as String
    }

    /// Places outside the set's list are neither added nor taken away; an empty set has none.
    @Test
    internal func aBitsetKeepsToItsList() {
        var bits = Bitset(size: 70)
        #expect(!bits.insert(-1) && !bits.insert(70) && !bits.remove(-1) && !bits.remove(70))
        #expect(bits.insert(69) && !bits.insert(69) && bits.remove(69) && !bits.remove(69))
        #expect(Array(Bitset()).isEmpty && Bitset().isEmpty && Array(Bitset(size: 200)).isEmpty)
        #expect(Array(Bitset.full(130)) == Array(0..<130) && !bits.contains(-5) && !bits.contains(500))
    }

    /// A name the system bridged is the same name as the one written in Swift, byte for byte.
    @Test
    internal func aBridgedNameIsTheSameName() {
        for name in ["é-file", "日本語.txt"] {
            let other = Self.bridged(name)
            #expect(other.utf8.withContiguousStorageIfAvailable { _ in true } == nil)
            #expect(ExactName.areSame(name, other) && ExactName.areSame(other, name))
            #expect(ExactName(name) == ExactName(other) && Set([ExactName(name), ExactName(other)]).count == 1)
            #expect(!ExactName.areSame(other, name + "x"))
            var first = Hasher()
            var second = Hasher()
            ExactName.combine(name, into: &first)
            ExactName.combine(other, into: &second)
            #expect(first.finalize() == second.finalize())
        }
        let items = ["a", "é-file", "b"].map { Self.item(Self.bridged($0)) }
        #expect(NameIndex(items).places(of: "é-file", in: items) == [1])
    }

    /// The rows of the shown entries, and what is not shown.
    @Test
    internal func shownPlacesFindTheirRows() {
        let places = ShownPlaces([1, 4, 9])
        #expect(places.row(ofPlace: 4) == 1 && places.row(ofPlace: 5) == nil && places.row(ofPlace: 10) == nil)
        #expect(places[2] == 9 && places.count == 3 && Array(places.bits(size: 12)) == [1, 4, 9])
    }

    /// Narrowing a filter looks only at what is shown, and keeps the places in the whole list.
    @Test
    internal func narrowingKeepsThePlacesOfTheWholeList() {
        let listed = (0..<10).map { Self.item("f\($0)", size: Int64($0)) }
        let even = PanelFilter(title: "even") { $0.size.isMultiple(of: 2) }
        let all = PanelFilter(title: "all") { _ in true }
        let (shown, places) = ListWork.arrange(listed, by: even)
        // A narrower filter that lets everything shown through changes nothing.
        let same = ListWork.narrow(shown, at: places, by: all)
        #expect(same.shown == shown && same.places?.values == places?.values)
        // From a list that showed everything.
        let fromAll = ListWork.narrow(listed, at: nil, by: even)
        #expect(fromAll.places?.values == [0, 2, 4, 6, 8])
        let small = PanelFilter(title: "small") { $0.size < 5 }
        #expect(ListWork.narrow(shown, at: places, by: small).places?.values == [0, 2, 4])
    }

    /// Of several entries of one name, the one at the same location that looks the same.
    @Test
    internal func twinsArePairedByLocationAndLooks() {
        let items = [
            Self.item("a", size: 1, in: "/x"), Self.item("a", size: 2, in: "/y"), Self.item("a", size: 3, in: "/y")
        ]
        #expect(ListWork.twin(of: Self.item("a", size: 3, in: "/y"), among: [0, 1, 2], in: items) == 2)
        #expect(ListWork.twin(of: Self.item("a", size: 9, in: "/y"), among: [0, 1, 2], in: items) == 1)
        #expect(ListWork.twin(of: Self.item("a", size: 9, in: "/z"), among: [0, 1, 2], in: items) == 0)
        #expect(ListWork.twin(of: Self.item("a"), among: [], in: items) == nil)
    }

    /// A long list whose sizes go below zero is counted in its own order, as one count would be.
    @Test
    internal func aLongListWithNegativeSizesIsCountedInOrder() {
        let items = (0..<40_000).map { Self.item("f\($0)", size: $0 == 20_000 ? -5 : Int64.max / 30_000) }
        var expected = Tally()
        for item in items { expected.add(item) }
        let counted = ListWork.tally(items)
        #expect(!counted.isPlain && counted.bytes == expected.bytes && counted.files == 40_000)
    }

    /// Names that read alike are found by an index once they keep being asked for.
    @Test
    internal func namesThatReadAlikeAreIndexed() {
        let shown = (0..<100).map { Self.item("e\u{301}\($0)") } + [Self.item("plain")]
        var lookups = NameLookups()
        for _ in 0..<5 {
            #expect(lookups.row(alike: "\u{E9}7", in: shown) == 7)
            #expect(lookups.row(alike: "absent", in: shown) == nil)
        }
        lookups.shownChanged()
        #expect(lookups.row(alike: "\u{E9}7", in: shown) == 7)
    }

    /// The tops of trees are remembered by a cache of their own, which lets go of them.
    @Test
    internal func aRootCacheCanBeLetGo() {
        let memory = MemoryFileSystem()
        var cache: RootCache? = RootCache()
        let deep = URL(fileURLWithPath: "/a/b/c")
        #expect(cache?.root(of: deep, parent: deep.deletingLastPathComponent(), in: memory).path == "/")
        #expect(cache?.root(of: deep.appendingPathComponent("d"), parent: deep, in: memory).path == "/")
        cache = nil
        #expect(cache == nil)
    }
}
