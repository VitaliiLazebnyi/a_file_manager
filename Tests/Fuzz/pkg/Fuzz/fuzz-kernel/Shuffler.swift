/// A small seeded generator (a linear congruential one) for shuffling listings the same way on every run.
internal struct Shuffler: RandomNumberGenerator {
    /// The generator's state; every call to `next()` moves it on.
    internal var state: UInt64

    /// The next 64 bits.
    internal mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
