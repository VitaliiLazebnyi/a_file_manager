/// One fuzz target: how to make, mutate and run its inputs.
///
/// Its closures run on the main thread, like the drivers' top-level code.
@preconcurrency
public struct FuzzTarget {
    /// The name `list` shows and the commands take.
    public var name: String
    /// The longest input the fuzzer makes.
    public var maxLen: Int
    /// Tokens that mutations insert or write over the input.
    public var dict: [[UInt8]]
    /// Offsets of size and offset fields in an input, for integer mutations aimed at them.
    public var fields: @MainActor ([UInt8]) -> [Int]
    /// A format-aware mutation, used for a share of the mutants.
    public var custom: (@MainActor (inout [UInt8], inout Rng) -> Void)?
    /// The inputs the fuzzer starts from.
    public var seeds: @MainActor () -> [[UInt8]]
    /// Runs once in each worker before the first input.
    public var setUp: @MainActor () -> Void
    /// Runs one input; a broken invariant ends the process through `fzFail`.
    public var run: @MainActor ([UInt8]) -> Void

    /// A target; `dict` gives tokens as text, `rawDict` as bytes.
    @preconcurrency
    public init(
        _ name: String,
        maxLen: Int = 1 << 15,
        dict: [String] = [],
        rawDict: [[UInt8]] = [],
        fields: @escaping @MainActor ([UInt8]) -> [Int] = { _ in [] },
        custom: (@MainActor (inout [UInt8], inout Rng) -> Void)? = nil,
        seeds: @escaping @MainActor () -> [[UInt8]] = { [] },
        setUp: @escaping @MainActor () -> Void = {
            // Nothing to prepare.
        },
        run: @escaping @MainActor ([UInt8]) -> Void
    ) {
        self.name = name
        self.maxLen = maxLen
        self.dict = dict.map { Array($0.utf8) } + rawDict
        self.fields = fields
        self.custom = custom
        self.seeds = seeds
        self.setUp = setUp
        self.run = run
    }
}
