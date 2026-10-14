import Foundation

/// Checks that a property holds for many random values, and when it does not, finds a small
/// value for which it fails.
///
/// The runs are the same every time: the seed comes from the property's name, so a failure on
/// one machine is a failure on every machine. Two variables of the environment widen the search:
/// `AFM_PROPERTY_SEED` (a number) starts from another seed, and `AFM_PROPERTY_RUNS` multiplies
/// the number of values (`AFM_PROPERTY_RUNS=100` for a long hunt).
public enum Property {
    /// How many smaller candidates shrinking tries at most.
    private static let shrinkLimit = 5_000

    /// The first counterexample of `holds` among `count` values of `generator`, shrunk; nil when
    /// the property held for every value. `name` picks the seed (the test's name by default).
    public static func check<Value>(
        _ generator: Generator<Value>,
        count: Int = 200,
        name: String = #function,
        _ holds: (Value) -> Bool
    ) -> Counterexample<Value>? {
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["AFM_PROPERTY_SEED"].flatMap(UInt64.init) ?? fnv(name)
        let runs = count * max(1, environment["AFM_PROPERTY_RUNS"].flatMap(Int.init) ?? 1)
        var choices = Choices(seed: seed)
        for passed in 0..<runs {
            let start = choices.drawn.count
            let value = generator.value(&choices)
            if !holds(value) {
                let smallest = shrink(Array(choices.drawn[start...]), generator, holds)
                return Counterexample(value: smallest, original: value, seed: seed, passed: passed)
            }
        }
        return nil
    }

    /// The smallest value found by replaying fewer and smaller choices that still fail.
    private static func shrink<Value>(
        _ failing: [UInt64],
        _ generator: Generator<Value>,
        _ holds: (Value) -> Bool
    ) -> Value {
        var best = failing
        var tries = 0
        func fails(_ candidate: [UInt64]) -> Bool {
            tries += 1
            var replay = Choices(replaying: candidate)
            return !holds(generator.value(&replay))
        }
        var improved = true
        while improved, tries < shrinkLimit {
            improved = false
            for candidate in candidates(best) where tries < shrinkLimit && isSimpler(candidate, than: best) {
                if fails(candidate) {
                    best = candidate
                    improved = true
                    break
                }
            }
        }
        var replay = Choices(replaying: best)
        return generator.value(&replay)
    }

    /// Smaller versions of a list of choices: runs of them left out, then single ones set to
    /// zero, halved and lowered by one.
    private static func candidates(_ choices: [UInt64]) -> [[UInt64]] {
        var result: [[UInt64]] = []
        for size in [8, 4, 2, 1] where size <= choices.count {
            for start in stride(from: 0, through: choices.count - size, by: 1) {
                result.append(Array(choices[..<start] + choices[(start + size)...]))
            }
        }
        for index in choices.indices where choices[index] > 0 {
            for smaller in [0, choices[index] / 2, choices[index] - 1] where smaller < choices[index] {
                var changed = choices
                changed[index] = smaller
                result.append(changed)
            }
        }
        return result
    }

    /// Shorter, or as long and smaller at the first place where the two differ.
    private static func isSimpler(_ candidate: [UInt64], than other: [UInt64]) -> Bool {
        candidate.count != other.count ? candidate.count < other.count : candidate.lexicographicallyPrecedes(other)
    }

    /// A number made of the name (FNV-1a), so that each property has a seed of its own.
    private static func fnv(_ name: String) -> UInt64 {
        name.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0100_0000_01B3 }
    }
}
