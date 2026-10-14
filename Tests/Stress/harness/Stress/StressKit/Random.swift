/// A small deterministic random generator (SplitMix64): the same seed gives the same numbers.
public struct Random: RandomNumberGenerator {
    /// The generator's state; every call to `next()` moves it on.
    private var state: UInt64

    /// A generator that starts from `seed`.
    public init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    /// The next 64 random bits.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
