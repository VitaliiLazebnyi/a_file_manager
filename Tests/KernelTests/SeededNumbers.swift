/// A fixed sequence of numbers that look random, so a failing case can be found again.
internal struct SeededNumbers {
    /// Where the sequence stands; the same state gives the same numbers from then on.
    internal var state: UInt64

    /// The sequence that starts at `seed`.
    internal init(seed: UInt64) {
        state = seed
    }

    /// The next number, from 0 up to `limit` (not included).
    internal mutating func next(_ limit: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(limit))
    }
}
