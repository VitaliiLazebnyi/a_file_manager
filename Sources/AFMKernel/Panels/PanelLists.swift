import Foundation

/// A set of places in a list, one bit each: what a panel keeps its marks in. Marking
/// everything, nothing or the opposite touches a sixty-fourth of the list's length, and a
/// mark belongs to one entry even when another has the same name.
struct Bitset: Equatable {
    private var words: [UInt64]
    /// The length of the list the places are in.
    private(set) var size: Int
    /// How many places are in the set.
    private(set) var count = 0

    init(size: Int = 0) {
        self.size = size
        words = [UInt64](repeating: 0, count: (size + 63) / 64)
    }

    /// From whole words, as work on several threads makes them; bits beyond `size` are dropped.
    init(size: Int, words: [UInt64]) {
        precondition(words.count == (size + 63) / 64)
        self.size = size
        self.words = words
        trim()
        recount()
    }

    static func full(_ size: Int) -> Self {
        Self(size: size, words: [UInt64](repeating: .max, count: (size + 63) / 64))
    }

    private mutating func trim() {
        if size & 63 != 0, !words.isEmpty { words[words.count - 1] &= (1 << UInt64(size & 63)) - 1 }
    }

    private mutating func recount() {
        count = words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    var isEmpty: Bool { count == 0 }
    var wordCount: Int { words.count }

    func contains(_ place: Int) -> Bool {
        place >= 0 && place < size && words[place >> 6] & (1 << UInt64(place & 63)) != 0
    }

    /// Returns whether the place was not in the set before.
    @discardableResult
    mutating func insert(_ place: Int) -> Bool {
        guard place >= 0, place < size else { return false }
        let bit: UInt64 = 1 << UInt64(place & 63)
        guard words[place >> 6] & bit == 0 else { return false }
        words[place >> 6] |= bit
        count += 1
        return true
    }

    /// Returns whether the place was in the set.
    @discardableResult
    mutating func remove(_ place: Int) -> Bool {
        guard place >= 0, place < size else { return false }
        let bit: UInt64 = 1 << UInt64(place & 63)
        guard words[place >> 6] & bit != 0 else { return false }
        words[place >> 6] &= ~bit
        count -= 1
        return true
    }

    mutating func formUnion(_ other: Self) {
        precondition(other.size == size)
        for index in words.indices { words[index] |= other.words[index] }
        recount()
    }

    mutating func formIntersection(_ other: Self) {
        precondition(other.size == size)
        for index in words.indices { words[index] &= other.words[index] }
        recount()
    }

    mutating func subtract(_ other: Self) {
        precondition(other.size == size)
        for index in words.indices { words[index] &= ~other.words[index] }
        recount()
    }

    /// The places in rising order.
    func forEach(_ body: (Int) -> Void) {
        forEach(inWords: 0..<words.count, body)
    }

    /// The places that lie in a run of words, for work that is cut into pieces.
    func forEach(inWords range: Range<Int>, _ body: (Int) -> Void) {
        for index in range {
            var word = words[index]
            while word != 0 {
                body(index << 6 + word.trailingZeroBitCount)
                word &= word - 1
            }
        }
    }

    /// The first place for which `matches` holds.
    func first(where matches: (Int) -> Bool) -> Int? {
        for index in words.indices {
            var word = words[index]
            while word != 0 {
                let place = index << 6 + word.trailingZeroBitCount
                if matches(place) { return place }
                word &= word - 1
            }
        }
        return nil
    }
}

/// Finds an entry of a list by its name as it is written, byte for byte. Made in one pass over
/// the list, the hashing on all cores; a value that can be made on any thread and handed on.
///
/// The hash is the standard library's, keyed anew for every run of the program, so names
/// chosen by somebody else (an archive, a server) cannot be made to collide.
struct NameIndex {
    /// The upper half holds a part of the name's hash, the lower the place plus one; zero is free.
    private var slots: [UInt64]
    private let mask: Int
    /// For a name that occurs more than once: the further places, by the first.
    private(set) var twins: [UInt32: [UInt32]] = [:]

    private static let tag: UInt64 = 0xFFFF_FFFF_0000_0000

    init(_ items: [FileItem]) {
        var capacity = 16
        while capacity < items.count * 2 { capacity <<= 1 }
        mask = capacity - 1
        let hashes = Self.hashes(of: items)
        var slots = [UInt64](repeating: 0, count: capacity)
        var twins: [UInt32: [UInt32]] = [:]
        let mask = self.mask
        slots.withUnsafeMutableBufferPointer { slots in
            items.withUnsafeBufferPointer { items in
                for place in 0..<items.count {
                    let hash = hashes[place]
                    var slot = Int(truncatingIfNeeded: hash) & mask
                    while true {
                        let held = slots[slot]
                        if held == 0 {
                            slots[slot] = hash & Self.tag | UInt64(place + 1)
                            break
                        }
                        if held & Self.tag == hash & Self.tag {
                            let other = Int(held & ~Self.tag) - 1
                            if ExactName.areSame(items[other].name, items[place].name) {
                                twins[UInt32(other), default: []].append(UInt32(place))
                                break
                            }
                        }
                        slot = (slot + 1) & mask
                    }
                }
            }
        }
        (self.slots, self.twins) = (slots, twins)
    }

    private init(slots: [UInt64], mask: Int, twins: [UInt32: [UInt32]]) {
        (self.slots, self.mask, self.twins) = (slots, mask, twins)
    }

    private static func hash(_ name: String) -> UInt64 {
        var hasher = Hasher()
        if name.utf8.withContiguousStorageIfAvailable({ hasher.combine(bytes: UnsafeRawBufferPointer($0)) }) == nil {
            Array(name.utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private static func hashes(of items: [FileItem]) -> [UInt64] {
        guard items.count > ListWork.pieceSize * 2 else { return items.map { hash($0.name) } }
        return [UInt64](unsafeUninitializedCapacity: items.count) { buffer, count in
            // Each piece writes its own places and only reads the list.
            nonisolated(unsafe) let target = buffer.baseAddress!
            items.withUnsafeBufferPointer { items in
                nonisolated(unsafe) let items = items
                _ = Parallel.map(ListWork.pieces(items.count)) { piece in
                    for place in piece { (target + place).initialize(to: hash(items[place].name)) }
                }
            }
            count = items.count
        }
    }

    /// The first place of the name in `items`, which must be the list the index was made of.
    func place(of name: String, in items: [FileItem]) -> Int? {
        let hash = Self.hash(name)
        var slot = Int(truncatingIfNeeded: hash) & mask
        while true {
            let held = slots[slot]
            if held == 0 { return nil }
            if held & Self.tag == hash & Self.tag {
                let other = Int(held & ~Self.tag) - 1
                if ExactName.areSame(items[other].name, name) { return other }
            }
            slot = (slot + 1) & mask
        }
    }

    /// Every place of the name, in rising order.
    func places(of name: String, in items: [FileItem]) -> [Int] {
        guard let first = place(of: name, in: items) else { return [] }
        guard !twins.isEmpty, let others = twins[UInt32(first)] else { return [first] }
        return [first] + others.map(Int.init)
    }

    /// The index of the same entries after they changed places: `moves[old]` is the new place.
    func moved(by moves: [UInt32]) -> Self {
        var slots = slots
        slots.withUnsafeMutableBufferPointer { slots in
            for slot in slots.indices where slots[slot] != 0 {
                let held = slots[slot]
                slots[slot] = held & Self.tag | UInt64(moves[Int(held & ~Self.tag) - 1] + 1)
            }
        }
        guard !twins.isEmpty else { return Self(slots: slots, mask: mask, twins: [:]) }
        // The lowest place of a name stands for it, as in an index made afresh.
        var moved: [UInt32: [UInt32]] = [:]
        var firsts: [UInt32: UInt32] = [:]
        for (first, others) in twins {
            let places = ([first] + others).map { moves[Int($0)] }.sorted()
            moved[places[0]] = Array(places.dropFirst())
            firsts[moves[Int(first)]] = places[0]
        }
        for slot in slots.indices where slots[slot] != 0 {
            let place = UInt32(slots[slot] & ~Self.tag) - 1
            if let first = firsts[place] { slots[slot] = slots[slot] & Self.tag | UInt64(first + 1) }
        }
        return Self(slots: slots, mask: mask, twins: moved)
    }
}

/// Looks names up in one list, with an index once it has been asked a few times: a single
/// question walks the list, which is cheaper than making the index. For one thread.
final class NameFinder {
    let items: [FileItem]
    private(set) var index: NameIndex?
    private var lookups = 0

    init(_ items: [FileItem], index: NameIndex? = nil) {
        (self.items, self.index) = (items, index)
    }

    /// Makes the index now: lookups from several threads may follow.
    func prepare() -> NameIndex {
        if let index { return index }
        let made = NameIndex(items)
        index = made
        return made
    }

    /// Every place of the name as it is written.
    func places(of name: String) -> [Int] {
        if index == nil {
            lookups += 1
            if lookups > 2, items.count > 64 { index = NameIndex(items) }
        }
        if let index { return index.places(of: name, in: items) }
        return items.indices.filter { ExactName.areSame(items[$0].name, name) }
    }

    /// The place of an entry that was at `hint` or near it in another list: the entry of the
    /// same name there, else wherever the name is; of several entries with the name, the one
    /// at the same location.
    func place(of item: FileItem, near hint: Int) -> Int? {
        if items.indices.contains(hint), ExactName.areSame(items[hint].name, item.name) { return hint }
        return ListWork.twin(of: item, among: places(of: item.name), in: items)
    }
}

/// What is counted of a list for the status line.
struct Tally {
    var bytes: Int64 = 0
    var files = 0, folders = 0
    /// No size below zero and no sum beyond the range of a number: the sum is then the same
    /// in whatever order it is made, and a part can be taken off again.
    var isPlain = true

    mutating func add(_ item: FileItem) {
        let size = item.isFolder ? (item.computedSize ?? 0) : item.size
        let (sum, overflow) = bytes.addingReportingOverflow(size)
        if size < 0 || overflow { isPlain = false }
        bytes = overflow ? (size < 0 ? .min : .max) : sum
        if item.isFolder { folders += 1 } else { files += 1 }
    }

    /// The sum of two parts counted apart; right when both are plain.
    func joined(with other: Self) -> Self {
        let (sum, overflow) = bytes.addingReportingOverflow(other.bytes)
        return Self(
            bytes: overflow ? .max : sum, files: files + other.files, folders: folders + other.folders,
            isPlain: isPlain && other.isPlain && !overflow)
    }
}

/// The work on whole lists that a panel needs: pure functions for any thread, which use all
/// cores for long lists.
enum ListWork {
    /// Lists are cut into pieces of this many entries, and shorter ones are not cut at all.
    static let pieceSize = 8_192

    static func pieces(_ count: Int, of size: Int = pieceSize) -> [Range<Int>] {
        stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }

    /// The parts as one list. The copying is spread over the cores: every entry copied is
    /// a handful of reference counts.
    static func joined<Element: Sendable>(_ parts: [[Element]]) -> [Element] {
        let total = parts.reduce(0) { $0 + $1.count }
        guard total > pieceSize * 2 else { return Array(parts.joined()) }
        var starts: [Int] = []
        var next = 0
        for part in parts {
            starts.append(next)
            next += part.count
        }
        return [Element](unsafeUninitializedCapacity: total) { [starts] buffer, count in
            // Each part is copied to its own places.
            nonisolated(unsafe) let target = buffer.baseAddress!
            _ = Parallel.map(Array(parts.indices)) { index in
                parts[index].withUnsafeBufferPointer { part in
                    guard let source = part.baseAddress else { return }
                    (target + starts[index]).initialize(from: source, count: part.count)
                }
            }
            count = total
        }
    }

    /// What a filter shows of a list, with the place of every shown entry; nil places when
    /// everything is shown, and the list itself is then what is shown.
    static func arrange(_ listed: [FileItem], by filter: PanelFilter?) -> (shown: [FileItem], places: [UInt32]?) {
        guard let filter else { return (listed, nil) }
        var shown: [FileItem] = []
        var places: [UInt32] = []
        if listed.count > pieceSize * 2 {
            let parts = listed.withUnsafeBufferPointer { listed in
                // Only read, while the call lasts.
                nonisolated(unsafe) let listed = listed
                return Parallel.map(pieces(listed.count)) { piece -> (items: [FileItem], places: [UInt32]) in
                    var passed: (items: [FileItem], places: [UInt32]) = ([], [])
                    for place in piece where filter.matches(listed[place]) {
                        passed.items.append(listed[place])
                        passed.places.append(UInt32(place))
                    }
                    return passed
                }
            }
            (shown, places) = (joined(parts.map(\.items)), joined(parts.map(\.places)))
        } else {
            for place in listed.indices where filter.matches(listed[place]) {
                shown.append(listed[place])
                places.append(UInt32(place))
            }
        }
        return shown.count == listed.count ? (listed, nil) : (shown, places)
    }

    /// The same for a filter that lets through only what is shown already: those entries
    /// alone are looked at.
    static func narrow(_ shown: [FileItem], at places: [UInt32]?, by filter: PanelFilter) -> (
        shown: [FileItem], places: [UInt32]?
    ) {
        let (kept, among) = arrange(shown, by: filter)
        guard let among else { return (shown, places) }
        return (kept, places.map { places in among.map { places[Int($0)] } } ?? among)
    }

    /// The places of the entries of `shown` in `listed`, of which they are meant to be a part
    /// in the same order; nil when they are not. An entry is found by everything that tells
    /// it from another of the same name (a list gathered from several folders can hold a
    /// name twice): its location and what the list says about it.
    static func places(of shown: [FileItem], in listed: [FileItem]) -> [UInt32]? {
        guard shown.count <= listed.count else { return nil }
        @Sendable func isSame(_ a: FileItem, _ b: FileItem) -> Bool {
            guard ExactName.areSame(a.name, b.name), a.size == b.size, a.isDirectory == b.isDirectory,
                a.isSymlink == b.isSymlink,
                a.modified == b.modified
                    || (a.modified.timeIntervalSinceReferenceDate.isNaN
                        && b.modified.timeIntervalSinceReferenceDate.isNaN)
            else { return false }
            // A copy of an entry holds the very same location; only otherwise are the two compared.
            let isSameObject = withUnsafeBytes(of: a.url) { first in
                withUnsafeBytes(of: b.url) { first.elementsEqual($0) }
            }
            return isSameObject || a.url == b.url
        }
        var places: [UInt32] = []
        places.reserveCapacity(shown.count)
        var next = 0
        for item in shown {
            while next < listed.count, !isSame(listed[next], item) { next += 1 }
            guard next < listed.count else { return nil }
            places.append(UInt32(next))
            next += 1
        }
        return places
    }

    /// The entries at the given places.
    static func picked(_ items: [FileItem], at places: [UInt32]) -> [FileItem] {
        Sorter.permute(items, by: places)
    }

    /// Whether two lists hold the same entries in the same order, apart from calculated
    /// folder sizes: what a refresh that changed nothing brings. A long list is compared on
    /// all cores.
    static func areSameEntries(_ items: [FileItem], _ others: [FileItem]) -> Bool {
        guard items.count == others.count else { return false }
        @Sendable func isSame(_ a: FileItem, _ b: FileItem) -> Bool {
            ExactName.areSame(a.name, b.name) && a.size == b.size && a.modified == b.modified
                && a.isDirectory == b.isDirectory
                && a.isSymlink == b.isSymlink && a.isPackage == b.isPackage && a.isHidden == b.isHidden
                && a.permissions == b.permissions && a.isSpecial == b.isSpecial
        }
        guard items.count > pieceSize * 2 else { return zip(items, others).allSatisfy(isSame) }
        let differs = CancellationFlag()
        return items.withUnsafeBufferPointer { items in
            others.withUnsafeBufferPointer { others in
                // Only read, while the call lasts.
                nonisolated(unsafe) let (items, others) = (items, others)
                return Parallel.map(pieces(items.count, of: pieceSize * 2)) { piece -> Bool in
                    // One difference settles it for every piece.
                    guard !differs.isCancelled, piece.allSatisfy({ isSame(items[$0], others[$0]) }) else {
                        differs.cancel()
                        return false
                    }
                    return true
                }.allSatisfy { $0 }
            }
        }
    }

    /// The places whose entries have a calculated size.
    static func sized(_ items: [FileItem]) -> Bitset {
        let wordsPerPiece = pieceSize / 64
        let wordCount = (items.count + 63) / 64
        @Sendable func words(_ range: Range<Int>) -> [UInt64] {
            range.map { word in
                var bits: UInt64 = 0
                for place in (word * 64)..<min(word * 64 + 64, items.count) where items[place].computedSize != nil {
                    bits |= 1 << UInt64(place & 63)
                }
                return bits
            }
        }
        guard items.count > pieceSize * 2 else { return Bitset(size: items.count, words: words(0..<wordCount)) }
        return Bitset(size: items.count, words: joined(Parallel.map(pieces(wordCount, of: wordsPerPiece), words)))
    }

    /// The places among `candidates` (all places when nil) whose entries `matches` holds for.
    /// `matches` is called from several threads at once for a long list.
    static func matching(
        _ items: [FileItem], among candidates: Bitset?, where matches: @Sendable (FileItem) -> Bool
    ) -> Bitset {
        let wordCount = (items.count + 63) / 64
        @Sendable func words(_ range: Range<Int>) -> [UInt64] {
            var result = [UInt64](repeating: 0, count: range.count)
            if let candidates {
                candidates.forEach(inWords: range) { place in
                    if matches(items[place]) { result[place >> 6 - range.lowerBound] |= 1 << UInt64(place & 63) }
                }
            } else {
                for place in (range.lowerBound * 64)..<min(range.upperBound * 64, items.count)
                where matches(items[place]) {
                    result[place >> 6 - range.lowerBound] |= 1 << UInt64(place & 63)
                }
            }
            return result
        }
        guard items.count > pieceSize * 2 else { return Bitset(size: items.count, words: words(0..<wordCount)) }
        return Bitset(size: items.count, words: joined(Parallel.map(pieces(wordCount, of: pieceSize / 64), words)))
    }

    /// Counts the entries at `places` of a list (all of it when nil). The result is what
    /// counting them one after the other gives, sizes that fit no number included.
    static func tally(_ items: [FileItem], at places: Bitset? = nil) -> Tally {
        @Sendable func count(_ range: Range<Int>) -> Tally {
            var tally = Tally()
            if let places {
                places.forEach(inWords: range) { tally.add(items[$0]) }
            } else {
                for place in range { tally.add(items[place]) }
            }
            return tally
        }
        let whole = places.map { 0..<$0.wordCount } ?? 0..<items.count
        guard items.count > pieceSize * 2 else { return count(whole) }
        let parts = Parallel.map(pieces(whole.count, of: places == nil ? pieceSize : pieceSize / 64), count)
        // Sums with sizes below zero or beyond all numbers depend on their order: those are
        // made again in the list's own.
        guard parts.allSatisfy(\.isPlain) else { return count(whole) }
        return parts.reduce(Tally()) { $0.joined(with: $1) }
    }

    /// Of several entries with the very same name (`found`, their places in `items`), the one
    /// that `item` is: at the same location and looking the same, else at the same location,
    /// else the first.
    static func twin(of item: FileItem, among found: [Int], in items: [FileItem]) -> Int? {
        guard found.count > 1 else { return found.first }
        return found.first {
            items[$0].url == item.url && items[$0].size == item.size && items[$0].modified == item.modified
        }
            ?? found.first { items[$0].url == item.url } ?? found.first
    }

    /// Where every entry of `old` is in the list of `finder`: `UInt32.max` for one that is
    /// not there. Lists that differ little are walked side by side; names are looked up only
    /// where the two part ways.
    static func moves(from old: [FileItem], to finder: NameFinder) -> [UInt32] {
        @Sendable func walk(_ range: Range<Int>, _ place: (FileItem, Int) -> Int?) -> [UInt32] {
            var shift = 0
            return range.map { index in
                guard let found = place(old[index], index + shift) else { return UInt32.max }
                shift = found - index
                return UInt32(found)
            }
        }
        guard old.count > pieceSize * 2 else { return walk(0..<old.count, finder.place(of:near:)) }
        // The index is made first, so that the pieces only read it.
        let index = finder.prepare()
        let items = finder.items
        return joined(
            Parallel.map(pieces(old.count)) { piece in
                walk(piece) { item, hint in
                    if items.indices.contains(hint), ExactName.areSame(items[hint].name, item.name) { return hint }
                    return twin(of: item, among: index.places(of: item.name, in: items), in: items)
                }
            })
    }
}

/// Lists that are no longer shown, kept by whoever may still want them (a snapshot, a list
/// that was worked out and not taken). When the last holder lets go, on whatever thread, the
/// memory is released in the background.
///
/// Unchecked: `lists` is changed only in `deinit`, when nobody else holds the object.
final class Remains: @unchecked Sendable {
    private(set) var lists: [[FileItem]]

    init(_ lists: [FileItem]...) {
        self.lists = lists
    }

    deinit {
        for index in lists.indices { Discard.later(&lists[index]) }
    }
}
