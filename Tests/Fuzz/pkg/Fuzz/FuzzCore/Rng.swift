// A small coverage-guided mutation fuzzer (libFuzzer is not shipped with the Command Line Tools).
//
//   fuzz-X list
//   fuzz-X fuzz <target> --out DIR [--time SECS] [--seeds DIR] [--timeout S] [--rss MB] [--seed N] [--execs N]
//   fuzz-X run  <target> FILE... run inputs once (reproduce)
//   fuzz-X min  <target> FILE OUT         delta-debug a reproducer
//
// `fuzz` is a supervisor: it starts a worker (the same binary), which writes every input to
// DIR/current before running it. When the worker dies, the supervisor files the input under
// DIR/findings/<signature>/ and starts the next worker. With `--seed` the mutations are the same
// on every run; without it each worker starts from the time and its process number.

/// A small, fast pseudo-random generator (SplitMix64): the same seed gives the same numbers.
public struct Rng {
    /// The generator's state; every call to `next()` moves it on.
    private var state: UInt64

    /// A generator that starts from `seed`.
    public init(_ seed: UInt64) {
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

    /// A number in `0..<bound`; 0 when `bound` is 1 or less.
    public mutating func below(_ bound: Int) -> Int {
        bound <= 1 ? 0 : Int(next() % UInt64(bound))
    }

    /// True once in `oneIn` calls, on average.
    public mutating func chance(_ oneIn: Int) -> Bool {
        below(oneIn) == 0
    }

    /// One of `items`, which must not be empty.
    public mutating func pick<Item>(_ items: [Item]) -> Item {
        items[below(items.count)]
    }
}
