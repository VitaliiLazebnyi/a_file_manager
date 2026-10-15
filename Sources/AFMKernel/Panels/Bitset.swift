/// A set of places in a list, one bit each: what a panel keeps its marks in.
///
/// Marking everything, nothing or the opposite touches a sixty-fourth of the list's length, and a
/// mark belongs to one entry even when another has the same name.
internal struct Bitset: Equatable, Sendable, Sequence {
    /// The places, sixty-four to a word, the lowest place in the lowest bit.
    private var words: [UInt64]
    /// The length of the list the places are in.
    internal private(set) var size: Int
    /// How many places are in the set.
    internal private(set) var count = 0

    /// Whether no place is in the set.
    internal var isEmpty: Bool { count == .zero }
    /// How many words hold the places, for work that is cut into pieces of words.
    internal var wordCount: Int { words.count }

    /// An empty set for a list of `size` entries.
    internal init(size: Int) {
        self.size = size
        words = [UInt64](repeating: 0, count: (size + 63) / 64)
    }

    /// An empty set for an empty list.
    internal init() {
        self = Self(size: 0)
    }

    /// From whole words, as work on several threads makes them; bits beyond `size` are dropped.
    internal init(size: Int, words: [UInt64]) {
        precondition(words.count == (size + 63) / 64)
        self.size = size
        self.words = words
        if size & 63 != 0, let last = words.indices.last { self.words[last] &= (1 << UInt64(size & 63)) - 1 }
        recount()
    }

    /// Every place of a list of `size` entries.
    internal static func full(_ size: Int) -> Self {
        Self(size: size, words: [UInt64](repeating: .max, count: (size + 63) / 64))
    }

    /// Whether the place is in the set.
    internal func contains(_ place: Int) -> Bool {
        place >= 0 && place < size && words[place >> 6] & (1 << UInt64(place & 63)) != 0
    }

    /// Whether `matches` holds for a place of the set; stops at the first that it holds for.
    internal func contains(where matches: (Int) -> Bool) -> Bool {
        for index in words.indices {
            var word = words[index]
            while word != 0 {
                if matches(index << 6 + word.trailingZeroBitCount) {
                    return true
                }
                word &= word - 1
            }
        }
        return false
    }

    /// The places in rising order.
    internal func makeIterator() -> BitsetIterator {
        BitsetIterator(words: words)
    }

    /// The places that lie in a run of words, for work that is cut into pieces.
    internal func forEach(inWords range: Range<Int>, _ body: (Int) -> Void) {
        for index in range {
            var word = words[index]
            while word != 0 {
                body(index << 6 + word.trailingZeroBitCount)
                word &= word - 1
            }
        }
    }

    /// Adds a place; returns whether it was not in the set before.
    @discardableResult
    internal mutating func insert(_ place: Int) -> Bool {
        guard place >= 0, place < size else {
            return false
        }
        let bit: UInt64 = 1 << UInt64(place & 63)
        guard words[place >> 6] & bit == 0 else {
            return false
        }
        words[place >> 6] |= bit
        count += 1
        return true
    }

    /// Takes a place out; returns whether it was in the set.
    @discardableResult
    internal mutating func remove(_ place: Int) -> Bool {
        guard place >= 0, place < size else {
            return false
        }
        let bit: UInt64 = 1 << UInt64(place & 63)
        guard words[place >> 6] & bit != 0 else {
            return false
        }
        words[place >> 6] &= ~bit
        count -= 1
        return true
    }

    /// Adds the places of another set of the same size.
    internal mutating func formUnion(_ other: Self) {
        precondition(other.size == size)
        for index in words.indices { words[index] |= other.words[index] }
        recount()
    }

    /// Keeps only the places that are in another set of the same size as well.
    internal mutating func formIntersection(_ other: Self) {
        precondition(other.size == size)
        for index in words.indices { words[index] &= other.words[index] }
        recount()
    }

    /// Takes out the places of another set of the same size.
    internal mutating func subtract(_ other: Self) {
        precondition(other.size == size)
        for index in words.indices { words[index] &= ~other.words[index] }
        recount()
    }

    /// Counts the places anew, after whole words changed.
    private mutating func recount() {
        count = words.reduce(0) { $0 + $1.nonzeroBitCount }
    }
}
