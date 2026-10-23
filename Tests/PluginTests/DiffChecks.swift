@testable import CompareContentPlugin

/// What the tests of the diffs check results against: what every diff must be, and the length of the
/// shortest one.
internal enum DiffChecks {
    /// Random numbers that are the same in every run.
    internal struct Seeded: RandomNumberGenerator {
        /// The generator's state.
        internal var state: UInt64

        /// The next number of the sequence.
        internal mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 29)
        }
    }

    /// The length of the longest common subsequence, by the textbook table.
    internal static func longestCommon<T: Equatable>(_ first: [T], _ second: [T]) -> Int {
        var row = [Int](repeating: 0, count: second.count + 1)
        for element in first {
            var diagonal = 0
            for (index, other) in second.enumerated() {
                let above = row[index + 1]
                row[index + 1] = element == other ? diagonal + 1 : max(above, row[index])
                diagonal = above
            }
        }
        return row[second.count]
    }

    /// What every diff must be, whatever it was computed with: a cover of both sequences in
    /// order, with equal stretches that are equal, turning `first` into `second`.
    internal static func isValid<T: Hashable>(_ segments: [DiffSegment], _ first: [T], _ second: [T]) -> Bool {
        var (inFirst, inSecond) = (0, 0)
        for segment in segments {
            guard segment.first.lowerBound == inFirst, segment.second.lowerBound == inSecond,
                !(segment.first.isEmpty && segment.second.isEmpty)
            else {
                return false
            }
            if segment.isEqual, Array(first[segment.first]) != Array(second[segment.second]) {
                return false
            }
            (inFirst, inSecond) = (segment.first.upperBound, segment.second.upperBound)
        }
        return inFirst == first.count && inSecond == second.count
            && Myers.apply(segments, to: first, from: second) == second
    }
}
