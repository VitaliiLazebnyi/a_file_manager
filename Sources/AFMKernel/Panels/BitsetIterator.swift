/// The places of a `Bitset` in rising order.
internal struct BitsetIterator: IteratorProtocol {
    /// The set's words.
    private let words: [UInt64]
    /// The word being walked.
    private var index = 0
    /// What is left of that word.
    private var word: UInt64

    /// Walks the places of these words.
    internal init(words: [UInt64]) {
        self.words = words
        word = words.first ?? 0
    }

    /// The next place; nil after the last.
    internal mutating func next() -> Int? {
        while word == 0 {
            index += 1
            guard index < words.count else {
                return nil
            }
            word = words[index]
        }
        let place = index << 6 + word.trailingZeroBitCount
        word &= word - 1
        return place
    }
}
