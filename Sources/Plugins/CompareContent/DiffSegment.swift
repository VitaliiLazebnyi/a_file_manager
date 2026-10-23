/// A stretch of two sequences that is either the same in both or differs: `first` is deleted and
/// `second` inserted in its place (either may be empty).
///
/// The segments of a diff cover both sequences completely, in order.
public struct DiffSegment: Equatable, Sendable {
    /// The positions of the stretch in the first sequence.
    public let first: Range<Int>
    /// The positions of the stretch in the second sequence.
    public let second: Range<Int>
    /// Whether the two stretches are the same; else `first` is replaced by `second`.
    public let isEqual: Bool
}
