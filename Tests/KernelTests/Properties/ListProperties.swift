import Foundation
import TestSupport
import Testing

@testable import AFMKernel

/// Properties of the work on whole lists (`ListWork`, `NameIndex`, `Parallel`): filtering and
/// sorting in either order, the places a filter reports, finding every name, and the parts that
/// run on all cores giving what one thread gives.
@Suite
internal struct ListProperties {
    /// One step done to a set of places: its kind (see `apply`), a place, and the members of a
    /// second set.
    private struct SetStep {
        /// Which step.
        let kind: Int
        /// The place inserted, removed or asked about.
        let place: Int
        /// The members of the set that is joined, intersected or taken away.
        let others: [Int]
    }

    /// Display filters: file masks made of pieces that matter to matching.
    private static let filter =
        Generate.text(from: ["*", "?", ".", "a", "A", "b", "\u{E9}", "*.a", ";", " "], lengths: 0...5)
        .map { PanelFilter.mask($0) }

    /// Steps done to a set of places.
    private static let setStep = Generate.int(in: 0...6)
        .flatMap { kind in
            Generate.int(in: -2...200)
                .flatMap { place in
                    Generate.int(in: 0...200).array(0...20).map { SetStep(kind: kind, place: place, others: $0) }
                }
        }

    /// The locations of a list, which tell its entries apart.
    private static func locations(_ items: [FileItem]) -> [String] {
        items.map(\.url.path)
    }

    /// The places in a set, in rising order.
    private static func members(_ set: Bitset) -> [Int] {
        var members: [Int] = []
        let record = { (place: Int) in members.append(place) }
        set.forEach(record)
        return members
    }

    /// Every place of a list: what a filter that shows everything reports (as nil).
    private static func all(_ listed: [FileItem]) -> [UInt32] {
        listed.indices.map { UInt32($0) }
    }

    /// Whether the places a filter reports are those of the entries it shows, in `listed`.
    private static func placesFit(_ shown: [FileItem], at places: [UInt32], in listed: [FileItem]) -> Bool {
        places.count == shown.count
            && zip(places, shown).allSatisfy { listed[Int($0)].url == $1.url }
            && zip(places, places.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// Does one step to the set and to the model of it; false when an answer of the set differs
    /// from the model's.
    private static func apply(_ operation: SetStep, to set: inout Bitset, _ model: inout Set<Int>) -> Bool {
        let (kind, place) = (operation.kind, operation.place)
        let other = Set(operation.others.filter { $0 < set.size })
        var otherSet = Bitset(size: set.size)
        for member in other {
            otherSet.insert(member)
        }
        switch kind {
        case 0:
            return set.insert(place) == (place >= 0 && place < set.size && model.insert(place).inserted)

        case 1:
            return set.remove(place) == (model.remove(place) != nil)

        case 2:
            (set, model) = (.full(set.size), Set(0..<set.size))

        case 3:
            set.formUnion(otherSet)
            model.formUnion(other)

        case 4:
            set.formIntersection(otherSet)
            model.formIntersection(other)

        case 5:
            set.subtract(otherSet)
            model.subtract(other)

        default:
            return set.contains(place) == model.contains(place)
        }
        return true
    }

    /// Whether a set holds what its model holds, by every way of asking.
    private static func agrees(_ set: Bitset, with model: Set<Int>) -> Bool {
        let sorted = model.sorted()
        return members(set) == sorted && set.count == model.count && set.isEmpty == model.isEmpty
            && set.first { $0.isMultiple(of: 3) } == sorted.first { $0.isMultiple(of: 3) }
    }

    /// Whether the index, a finder and the index after a move find every place of every name.
    private static func findsEveryName(_ items: [FileItem], probes: [String]) -> Bool {
        let index = NameIndex(items)
        let finder = NameFinder(items)
        let shuffled = Array(items.indices.shuffled())
        var moves = [UInt32](repeating: 0, count: items.count)
        for (new, old) in shuffled.enumerated() {
            moves[old] = UInt32(new)
        }
        let moved = shuffled.map { items[$0] }
        let movedIndex = index.moved(by: moves)
        return (items.map(\.name) + probes)
            .allSatisfy { name in
                let expected = items.indices.filter { ExactName.areSame(items[$0].name, name) }
                // Asked three times, the finder switches from walking the list to an index.
                let byFinder = (0..<3).allSatisfy { _ in finder.places(of: name) == expected }
                return byFinder && index.places(of: name, in: items) == expected
                    && index.place(of: name, in: items) == expected.first
                    && movedIndex.places(of: name, in: moved)
                        == moved.indices.filter { ExactName.areSame(moved[$0].name, name) }
            }
    }

    /// Whether what is counted of a long list on all cores is what one walk over it gives.
    private static func countsLikeOneWalk(_ items: [FileItem], _ filter: PanelFilter) -> Bool {
        let sized = items.enumerated()
            .map { place, item in
                var item = item
                item.computedSize = place.isMultiple(of: 5) ? Int64(place) : nil
                return item
            }
        let matching = ListWork.matching(sized, among: nil, where: filter.matches)
        let expected = sized.indices.filter { filter.matches(sized[$0]) }
        var plain = Tally()
        for place in expected {
            plain.add(sized[place])
        }
        let tally = ListWork.tally(sized, at: matching)
        return members(matching) == expected && tally.bytes == plain.bytes && tally.files == plain.files
            && tally.folders == plain.folders
            && members(ListWork.sized(sized)) == sized.indices.filter { $0.isMultiple(of: 5) }
    }

    /// Filtering a sorted list gives what sorting the filtered list gives, and the places the
    /// filter reports are those of the entries it shows.
    @Test
    internal func filteringAndSortingCanBeDoneInEitherOrder() {
        let cases = KernelGenerators.items(KernelGenerators.name, lengths: 0...24)
            .flatMap { items in KernelGenerators.order.map { (items: items, order: $0) } }
            .flatMap { list in Self.filter.map { (items: list.items, order: list.order, filter: $0) } }
        expectProperty(cases) { items, order, filter in
            let sorted = Sorter.sort(items, by: order)
            let filteredSorted = ListWork.arrange(sorted, by: filter)
            let sortedFiltered = Sorter.sort(ListWork.arrange(items, by: filter).shown, by: order)
            return Self.locations(filteredSorted.shown) == Self.locations(sortedFiltered)
                && Self.placesFit(filteredSorted.shown, at: filteredSorted.places ?? Self.all(sorted), in: sorted)
                && Self.locations(PanelModel.filtered(sorted, by: filter)) == Self.locations(filteredSorted.shown)
        }
    }

    /// A long list is filtered on all cores, with the result one thread gives; narrowing what a
    /// filter shows by a second filter gives what both filters at once give.
    @Test
    internal func longListsAreFilteredLikeShortOnes() {
        let cases = KernelGenerators.longList(count: ListWork.pieceSize * 2 + 33)
            .flatMap { items in Self.filter.array(2...2).map { (items: items, filters: $0) } }
        expectProperty(cases, count: 4) { items, filters in
            let first = filters[0]
            let arranged = ListWork.arrange(items, by: first)
            let alone = items.filter(first.matches)
            let both = PanelFilter(title: "both") { first.matches($0) && filters[1].matches($0) }
            let narrowed = ListWork.narrow(arranged.shown, at: arranged.places, by: both)
            return Self.locations(arranged.shown) == Self.locations(alone)
                && Self.placesFit(arranged.shown, at: arranged.places ?? Self.all(items), in: items)
                && Self.locations(narrowed.shown) == Self.locations(items.filter(both.matches))
                && Self.placesFit(narrowed.shown, at: narrowed.places ?? Self.all(items), in: items)
        }
    }

    /// The index of names finds every entry of a name as it is written, byte for byte, and
    /// nothing else; after the entries move, the moved index finds them where they are.
    @Test
    internal func theIndexOfNamesFindsEveryName() {
        let cases = KernelGenerators.items(KernelGenerators.crowdedName, lengths: 0...40)
            .flatMap { items in KernelGenerators.crowdedName.array(0...4).map { (items: items, probes: $0) } }
        expectProperty(cases) { items, probes in Self.findsEveryName(items, probes: probes) }
    }

    /// The index of a long list, hashed on all cores, finds every name too.
    @Test
    internal func theIndexOfALongListFindsEveryName() {
        expectProperty(KernelGenerators.longList(count: ListWork.pieceSize * 2 + 5), count: 2) { items in
            let index = NameIndex(items)
            var expected: [String: [Int]] = [:]
            for (place, item) in items.enumerated() {
                expected[item.name, default: []].append(place)
            }
            return expected.allSatisfy { name, places in index.places(of: name, in: items) == places }
        }
    }

    /// The set of places behaves like a set of numbers below its size, whatever is done to it.
    @Test
    internal func theSetOfPlacesBehavesLikeASet() {
        let cases = Generate.int(in: 0...150)
            .flatMap { size in Self.setStep.array(0...30).map { (size: size, operations: $0) } }
        expectProperty(cases) { size, operations in
            var set = Bitset(size: size)
            var model = Set<Int>()
            return operations.allSatisfy { operation in
                Self.apply(operation, to: &set, &model) && Self.agrees(set, with: model)
            }
        }
    }

    /// A set made from whole words drops the bits beyond its size, and counts the rest.
    @Test
    internal func aSetMadeFromWordsKeepsOnlyItsPlaces() {
        let cases = Generate.int(in: 0...200)
            .flatMap { size in
                let words = (size + 63) / 64
                return Generate.int64
                    .map { UInt64(bitPattern: $0) }
                    .array(words...words)
                    .map { (size: size, words: $0) }
            }
        expectProperty(cases) { size, words in
            let set = Bitset(size: size, words: words)
            let expected = (0..<size).filter { words[$0 / 64] & (1 << UInt64($0 % 64)) != 0 }
            return Self.members(set) == expected && set.count == expected.count
                && set == Bitset(size: size, words: words)
        }
    }

    /// The places a mask selects, those with a calculated size and the totals of the status line
    /// are, for a long list worked on all cores, what one walk over the list gives.
    @Test
    internal func longListsAreCountedLikeShortOnes() {
        let cases = KernelGenerators.longList(count: ListWork.pieceSize * 2 + 77)
            .flatMap { items in Self.filter.map { (items: items, filter: $0) } }
        expectProperty(cases, count: 3) { items, filter in Self.countsLikeOneWalk(items, filter) }
    }

    /// Spreading work over the cores gives the results of doing it on one thread, in order.
    @Test
    internal func parallelMapGivesWhatMapGives() {
        let cases = Generate.int64.array(0...3_000)
            .flatMap { values in Generate.int(in: 0...64).map { (values: values, threshold: $0) } }
        expectProperty(cases, count: 50) { values, threshold in
            Parallel.map(values, serialBelow: threshold) { $0.addingSaturated(7) }
                == values.map { $0.addingSaturated(7) }
        }
    }

    /// Splitting a name at its extension: the parts put back together are the name, the
    /// extension holds no dot, and a name that starts with its only dot has no extension.
    @Test
    internal func splittingANameKeepsAllOfIt() {
        expectProperty(KernelGenerators.name, count: 2_000) { name in
            let (base, ext) = FileItem.split(name)
            let whole = ext.isEmpty ? base == name : base + "." + ext == name
            return whole && !ext.contains(".") && (ext.isEmpty || !base.isEmpty)
        }
    }
}
