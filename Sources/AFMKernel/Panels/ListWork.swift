import Foundation

/// The work on whole lists that a panel needs: pure functions for any thread, which use all
/// cores for long lists.
internal enum ListWork {
    /// Lists are cut into pieces of this many entries, and shorter ones are not cut at all.
    internal static let pieceSize = 8_192

    /// A run of `count` places cut into pieces of `size` places, the last one shorter.
    internal static func pieces(_ count: Int, of size: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }

    /// A run of `count` places cut into `pieceCount` pieces of nearly the same length.
    internal static func evenPieces(_ count: Int, _ pieceCount: Int) -> [Range<Int>] {
        (0..<pieceCount).map { ($0 * count / pieceCount)..<(($0 + 1) * count / pieceCount) }
    }

    /// The parts as one list.
    ///
    /// The copying is spread over the cores: every entry copied is a handful of reference counts.
    internal static func joined<Element: Sendable>(_ parts: [[Element]]) -> [Element] {
        let total = parts.reduce(0) { $0 + $1.count }
        guard total > pieceSize * 2 else {
            return Array(parts.joined())
        }
        var starts: [Int] = []
        var next = 0
        for part in parts {
            starts.append(next)
            next += part.count
        }
        return [Element](unsafeUninitializedCapacity: total) { [starts] buffer, count in
            // Each part is copied to its own places.
            nonisolated(unsafe) let target = buffer
            _ = Parallel.map(Array(parts.indices)) { index in
                let start = starts[index]
                _ = UnsafeMutableBufferPointer(rebasing: target[start..<start + parts[index].count])
                    .initialize(fromContentsOf: parts[index])
            }
            count = total
        }
    }

    /// What a filter shows of a list, with the place of every shown entry; nil places when
    /// everything is shown, and the list itself is then what is shown.
    internal static func arrange(_ listed: [FileItem], by filter: PanelFilter?)
        -> (shown: [FileItem], places: ShownPlaces?)
    {
        guard let filter else {
            return (listed, nil)
        }
        var shown: [FileItem] = []
        var places: [UInt32] = []
        if listed.count > pieceSize * 2 {
            let parts = Parallel.map(pieces(listed.count, of: pieceSize)) { piece in
                var passed: (items: [FileItem], places: [UInt32]) = ([], [])
                for place in piece where filter.matches(listed[place]) {
                    passed.items.append(listed[place])
                    passed.places.append(UInt32(place))
                }
                return passed
            }
            (shown, places) = (joined(parts.map(\.items)), joined(parts.map(\.places)))
        } else {
            for place in listed.indices where filter.matches(listed[place]) {
                shown.append(listed[place])
                places.append(UInt32(place))
            }
        }
        return shown.count == listed.count ? (listed, nil) : (shown, ShownPlaces(places))
    }

    /// The same for a filter that lets through only what is shown already: those entries
    /// alone are looked at.
    internal static func narrow(_ shown: [FileItem], at places: ShownPlaces?, by filter: PanelFilter)
        -> (shown: [FileItem], places: ShownPlaces?)
    {
        let (kept, among) = arrange(shown, by: filter)
        guard let among else {
            return (shown, places)
        }
        guard let places else {
            return (kept, among)
        }
        return (kept, ShownPlaces(among.values.map { places.values[Int($0)] }))
    }

    /// The entries at the given places.
    internal static func picked(_ items: [FileItem], at places: [UInt32]) -> [FileItem] {
        Sorter.permute(items, by: places)
    }

    /// The table that undoes a reordering: `indexes[new]` is an entry's old place, the result
    /// at that old place its new one.
    internal static func inverse(of indexes: [UInt32]) -> [UInt32] {
        var table = [UInt32](repeating: 0, count: indexes.count)
        for (new, old) in indexes.enumerated() { table[Int(old)] = UInt32(new) }
        return table
    }

    /// Whether two lists hold the same entries in the same order, apart from calculated folder
    /// sizes: what a refresh that changed nothing brings.
    ///
    /// A long list is compared on all cores.
    internal static func areSameEntries(_ items: [FileItem], _ others: [FileItem]) -> Bool {
        guard items.count == others.count else {
            return false
        }
        guard items.count > pieceSize * 2 else {
            return zip(items, others).allSatisfy(isSameEntry)
        }
        let differs = CancellationFlag()
        return
            Parallel.map(pieces(items.count, of: pieceSize * 2)) { piece in
                // One difference settles it for every piece.
                guard !differs.isCancelled, piece.allSatisfy({ isSameEntry(items[$0], others[$0]) }) else {
                    differs.cancel()
                    return false
                }
                return true
            }
            .allSatisfy(\.self)
    }

    /// Whether two entries are the same, apart from a calculated folder size.
    internal static func isSameEntry(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        ExactName.areSame(lhs.name, rhs.name) && lhs.size == rhs.size && lhs.modified == rhs.modified
            && lhs.isDirectory == rhs.isDirectory && lhs.isSymlink == rhs.isSymlink && lhs.isPackage == rhs.isPackage
            && lhs.isHidden == rhs.isHidden && lhs.permissions == rhs.permissions && lhs.isSpecial == rhs.isSpecial
    }

    /// The places whose entries have a calculated size.
    internal static func sized(_ items: [FileItem]) -> Bitset {
        matching(items, among: nil) { $0.computedSize != nil }
    }

    /// The places among `candidates` (all places when nil) whose entries `matches` holds for.
    ///
    /// `matches` is called from several threads at once for a long list.
    internal static func matching(
        _ items: [FileItem],
        among candidates: Bitset?,
        where matches: @Sendable (FileItem) -> Bool
    ) -> Bitset {
        let wordCount = (items.count + 63) / 64
        @Sendable
        func words(_ range: Range<Int>) -> [UInt64] {
            var result = [UInt64](repeating: 0, count: range.count)
            func take(_ place: Int) {
                if matches(items[place]) { result[place >> 6 - range.lowerBound] |= 1 << UInt64(place & 63) }
            }
            if let candidates {
                candidates.forEach(inWords: range, take)
            } else {
                for place in (range.lowerBound * 64)..<min(range.upperBound * 64, items.count) { take(place) }
            }
            return result
        }
        guard items.count > pieceSize * 2 else {
            return Bitset(size: items.count, words: words(0..<wordCount))
        }
        return Bitset(size: items.count, words: joined(Parallel.map(pieces(wordCount, of: pieceSize / 64), words)))
    }

    /// Counts the entries of a list.
    internal static func tally(_ items: [FileItem]) -> Tally {
        tally(items, at: nil)
    }

    /// Counts the entries at `places` of a list (all of it when nil).
    ///
    /// The result is what counting them one after the other gives, sizes that fit no number
    /// included.
    internal static func tally(_ items: [FileItem], at places: Bitset?) -> Tally {
        @Sendable
        func count(_ range: Range<Int>) -> Tally {
            var tally = Tally()
            if let places {
                places.forEach(inWords: range) { tally.add(items[$0]) }
            } else {
                for place in range { tally.add(items[place]) }
            }
            return tally
        }
        let whole = places.map { 0..<$0.wordCount } ?? 0..<items.count
        guard items.count > pieceSize * 2 else {
            return count(whole)
        }
        let parts = Parallel.map(pieces(whole.count, of: places == nil ? pieceSize : pieceSize / 64), count)
        // Sums with sizes below zero or beyond all numbers depend on their order: those are
        // made again in the list's own.
        guard parts.allSatisfy(\.isPlain) else {
            return count(whole)
        }
        return parts.reduce(Tally()) { $0.joined(with: $1) }
    }

    /// Of several entries with the very same name (`found`, their places in `items`), the one
    /// that `item` is: at the same location and looking the same, else at the same location,
    /// else the first.
    internal static func twin(of item: FileItem, among found: [Int], in items: [FileItem]) -> Int? {
        guard found.count > 1 else {
            return found.first
        }
        let looksTheSame = found.first { place in
            items[place].url == item.url && items[place].size == item.size && items[place].modified == item.modified
        }
        return looksTheSame ?? found.first { items[$0].url == item.url } ?? found.first
    }

    /// The place in `items` of an entry that was at `hint`, or near it, in another list: the
    /// entry of the same name there, else wherever the name is (`placesOfName`); of several
    /// entries with the name, the one at the same location.
    internal static func place(
        of item: FileItem,
        near hint: Int,
        in items: [FileItem],
        placesOfName: (String) -> [Int]
    ) -> Int? {
        if items.indices.contains(hint), ExactName.areSame(items[hint].name, item.name) {
            return hint
        }
        return twin(of: item, among: placesOfName(item.name), in: items)
    }

    /// Where every entry of `old` is in the list of `finder`: `UInt32.max` for one that is not
    /// there.
    ///
    /// Lists that differ little are walked side by side; names are looked up only where the two
    /// part ways.
    internal static func moves(from old: [FileItem], to finder: NameFinder) -> [UInt32] {
        @Sendable
        func walk(_ range: Range<Int>, _ place: (FileItem, Int) -> Int?) -> [UInt32] {
            var shift = 0
            return range.map { index in
                guard let found = place(old[index], index + shift) else {
                    return UInt32.max
                }
                shift = found - index
                return UInt32(found)
            }
        }
        guard old.count > pieceSize * 2 else {
            return walk(0..<old.count, finder.place(of:near:))
        }
        // The index is made first, so that the pieces only read it.
        let index = finder.prepare()
        let items = finder.items
        return joined(
            Parallel.map(pieces(old.count, of: pieceSize)) { piece in
                walk(piece) { item, hint in
                    place(of: item, near: hint, in: items) { index.places(of: $0, in: items) }
                }
            }
        )
    }
}
