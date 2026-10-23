import AFMKernel
import Darwin.C
import Testing

@testable import CompareContentPlugin

/// Myers' difference of two sequences (spec 09 › Comparison rules): exact where it can be, bounded and still
/// correct where it cannot.
@Suite
internal struct MyersDiff {
    /// Empty, equal, disjoint and small inputs give the segments one would write by hand.
    @Test
    internal func edgeCases() {
        #expect(Myers.diff([Int](), []).isEmpty)
        #expect(Myers.diff([], [1, 2]) == [DiffSegment(first: 0..<0, second: 0..<2, isEqual: false)])
        #expect(Myers.diff([1, 2], []) == [DiffSegment(first: 0..<2, second: 0..<0, isEqual: false)])
        #expect(Myers.diff([1, 2, 3], [1, 2, 3]) == [DiffSegment(first: 0..<3, second: 0..<3, isEqual: true)])
        #expect(Myers.diff([1], [2]) == [DiffSegment(first: 0..<1, second: 0..<1, isEqual: false)])
        #expect(Myers.diff([1, 2, 3], [4, 5]) == [DiffSegment(first: 0..<3, second: 0..<2, isEqual: false)])
        #expect(
            Myers.diff(Array("abcd"), Array("abXcd")) == [
                DiffSegment(first: 0..<2, second: 0..<2, isEqual: true),
                DiffSegment(first: 2..<2, second: 2..<3, isEqual: false),
                DiffSegment(first: 2..<4, second: 3..<5, isEqual: true)
            ]
        )
        #expect(
            Myers.diff(Array("abcd"), Array("ad")) == [
                DiffSegment(first: 0..<1, second: 0..<1, isEqual: true),
                DiffSegment(first: 1..<3, second: 1..<1, isEqual: false),
                DiffSegment(first: 3..<4, second: 1..<2, isEqual: true)
            ]
        )
        // The classic example of the paper: five edits.
        #expect(Myers.editDistance(Myers.diff(Array("ABCABBA"), Array("CBABAC"))) == 5)
    }

    /// Applying the diff to the first sequence gives the second, and no diff is shorter.
    @Test
    internal func applyingTheDiffToAYieldsBAndItIsTheShortest() {
        var random = DiffChecks.Seeded(state: 42)
        for round in 0..<600 {
            let alphabet = [2, 3, 5, 12][round % 4]
            let first = (0..<Int.random(in: 0...40, using: &random))
                .map { _ in
                    Int.random(in: 0..<alphabet, using: &random)
                }
            let second = (0..<Int.random(in: 0...40, using: &random))
                .map { _ in
                    Int.random(in: 0..<alphabet, using: &random)
                }
            let segments = Myers.diff(first, second)
            #expect(DiffChecks.isValid(segments, first, second), "\(first) -> \(second)")
            #expect(
                Myers.editDistance(segments) == first.count + second.count - 2
                    * DiffChecks.longestCommon(first, second),
                "\(first) -> \(second)"
            )
        }
    }

    /// Copies with a few edits are found exactly.
    @Test
    internal func editedCopiesAreFoundExactly() {
        var random = DiffChecks.Seeded(state: 7)
        for _ in 0..<40 {
            let first = (0..<Int.random(in: 50...400, using: &random))
                .map { _ in Int.random(in: 0..<60, using: &random) }
            var second = first
            for _ in 0..<Int.random(in: 0...12, using: &random) {
                let position = Int.random(in: 0...second.count, using: &random)
                if Bool.random(using: &random), position < second.count {
                    second.remove(at: position)
                } else {
                    second.insert(Int.random(in: 0..<70, using: &random), at: position)
                }
            }
            let segments = Myers.diff(first, second)
            #expect(DiffChecks.isValid(segments, first, second))
            #expect(
                Myers.editDistance(segments) == first.count + second.count - 2 * DiffChecks.longestCommon(first, second)
            )
        }
    }

    /// A search bounded in effort still gives a correct diff.
    @Test
    internal func aBoundedSearchStillGivesACorrectDiff() {
        var random = DiffChecks.Seeded(state: 99)
        for limit in [1, 2, 5] {
            for _ in 0..<150 {
                let first = (0..<Int.random(in: 0...120, using: &random))
                    .map { _ in Int.random(in: 0..<6, using: &random) }
                let second = (0..<Int.random(in: 0...120, using: &random))
                    .map { _ in Int.random(in: 0..<6, using: &random) }
                let segments = Myers.diff(first, second, costLimit: limit)
                #expect(DiffChecks.isValid(segments, first, second))
                #expect(
                    Myers.editDistance(segments) >= first.count + second.count - 2
                        * DiffChecks.longestCommon(first, second)
                )
            }
        }
    }

    /// Huge inputs fall back to the bounded search, stay correct, and take bounded time.
    @Test
    internal func hugeInputsFallBackToTheHeuristicAndStayCorrect() {
        // Two long texts in different order: far more differences than an exact search could
        // go through, and more elements than `exactBelow`.
        var random = DiffChecks.Seeded(state: 3)
        let first = (0..<30_000).map { _ in Int.random(in: 0..<400, using: &random) }
        let second = (0..<30_000).map { _ in Int.random(in: 0..<400, using: &random) }
        #expect(first.count + second.count > Myers.exactBelow)
        // The work done is bounded by the cost limit, not by the clock: the time of this thread's own processor,
        // which a busy machine does not stretch.
        func processorSeconds() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
        }
        let started = processorSeconds()
        let segments = Myers.diff(first, second)
        #expect(DiffChecks.isValid(segments, first, second))
        let hasEqualStretch = segments.contains(where: \.isEqual)
        #expect(hasEqualStretch)
        #expect(processorSeconds() - started < 60)
    }

    /// Lines without a partner on the other side are taken out before the search.
    @Test
    internal func linesWithoutAPartnerAreTakenOutFirst() {
        // 200,000 lines on each side with nothing in common but three lines: no search to speak of.
        var first = (0..<200_000).map { "left \($0)" }
        var second = (0..<200_000).map { "right \($0)" }
        for (position, text) in [(10, "one"), (100_000, "two"), (199_990, "three")] {
            first[position] = text
            second[position + 5] = text
        }
        let segments = Myers.diff(first, second)
        #expect(DiffChecks.isValid(segments, first, second))
        #expect(segments.filter(\.isEqual).map(\.first) == [10..<11, 100_000..<100_001, 199_990..<199_991])
    }

    /// A large file with few changes is compared exactly.
    @Test
    internal func aLargeFileWithFewChangesIsExact() {
        var first = (0..<120_000).map { "line \($0 % 5_000) of block \($0 / 5_000)" }
        var second = first
        second.remove(at: 70_000)
        second.insert("something new", at: 20_000)
        second[110_000] = "changed"
        first.append("tail")
        let segments = Myers.diff(first, second)
        #expect(DiffChecks.isValid(segments, first, second))
        #expect(Myers.editDistance(segments) == 5)
    }

    /// A cancelled diff ends early but still covers both sequences.
    @Test
    internal func cancelledDiffEndsEarlyButIsStillACover() {
        let flag = CancellationFlag()
        flag.cancel()
        let (first, second) = ([1, 2, 3, 4], [1, 3, 4, 5])
        let segments = Myers.diff(first, second, cancellation: flag)
        #expect(DiffChecks.isValid(segments, first, second))
    }
}
