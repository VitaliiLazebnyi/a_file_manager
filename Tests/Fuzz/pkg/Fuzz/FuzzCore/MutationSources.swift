/// What a mutation may take material from besides the input itself.
internal struct MutationSources {
    /// Another input of the corpus, for splicing.
    internal let other: [UInt8]
    /// The target's tokens.
    internal let dict: [[UInt8]]
    /// Offsets of size and offset fields in the input, for integer mutations aimed at them.
    internal let fields: [Int]
}
