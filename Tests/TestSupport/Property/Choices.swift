/// The random choices a generated value is made of, recorded so that the value can be made again
/// and made smaller.
///
/// Every generator takes its randomness from here as numbers below a bound. A fresh source draws
/// them from a seeded generator (SplitMix64) and records each; a replaying source hands back
/// recorded numbers instead (cut to the bound asked for, and zero once they run out). Shrinking a
/// failing value is then the same for every generator: replay smaller or fewer choices and keep
/// what still fails. Generators are written so that smaller choices give simpler values (zero
/// gives the shortest list, the first element, the number nearest zero).
public struct Choices {
    /// The numbers handed out so far, each below the bound it was asked for.
    public private(set) var drawn: [UInt64] = []
    /// The state of the random generator; unused while replaying.
    private var state: UInt64
    /// The numbers to hand out again, when replaying.
    private let replayed: [UInt64]
    /// Whether the numbers come from `replayed` rather than from the random generator.
    private let isReplaying: Bool

    /// A source of fresh random choices, the same ones for the same seed.
    public init(seed: UInt64) {
        state = seed
        replayed = []
        isReplaying = false
    }

    /// A source that hands out `choices` again.
    public init(replaying choices: [UInt64]) {
        state = 0
        replayed = choices
        isReplaying = true
    }

    /// A number below `bound` (which is at least one).
    public mutating func next(below bound: UInt64) -> UInt64 {
        precondition(bound > 0)
        let value: UInt64
        if isReplaying {
            value = drawn.count < replayed.count ? min(replayed[drawn.count], bound - 1) : 0
        } else {
            value = random() % bound
        }
        drawn.append(value)
        return value
    }

    /// Any number of 64 bits.
    public mutating func nextWord() -> UInt64 {
        let value: UInt64
        if isReplaying {
            value = drawn.count < replayed.count ? replayed[drawn.count] : 0
        } else {
            value = random()
        }
        drawn.append(value)
        return value
    }

    /// The next number of SplitMix64.
    private mutating func random() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
