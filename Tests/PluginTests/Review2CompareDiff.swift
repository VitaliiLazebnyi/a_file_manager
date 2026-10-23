import Testing

@testable import CompareContentPlugin

/// Review round 2: the diff of large files near the shortest, and a bounded effort that still gives
/// a valid diff.
@Suite
internal struct Review2CompareDiff {
    /// A source-like file: mostly distinct lines, some repeated ones (braces, blanks).
    private static func sourceLike(_ count: Int, seed: UInt64) -> [Int] {
        var random = DiffChecks.Seeded(state: seed)
        return (0..<count)
            .map { index in
                Int.random(in: 0..<10, using: &random) < 2 ? -Int.random(in: 1...30, using: &random) : index
            }
    }

    /// A block deleted from a large file, with a few lines changed, costs about the block.
    @Test
    internal func aDeletedBlockInALargeFileCostsAboutTheBlock() {
        let original = Self.sourceLike(24_000, seed: 1)
        var changed = original
        var random = DiffChecks.Seeded(state: 2)
        changed.removeSubrange(9_000..<10_500)
        for _ in 0..<150 {
            changed[Int.random(in: 0..<changed.count, using: &random)] =
                1_000_000 + Int.random(in: 0..<1_000_000, using: &random)
        }
        let segments = Myers.diff(original, changed)
        #expect(DiffChecks.isValid(segments, original, changed))
        // The shortest script deletes the block and replaces 150 lines: at most 1,500 + 2 x 150.
        #expect(Myers.editDistance(segments) <= 1_800 + 100)
    }

    /// A block moved in a large file costs about twice the block.
    @Test
    internal func aMovedBlockInALargeFileCostsAboutTwiceTheBlock() {
        let original = Self.sourceLike(24_000, seed: 3)
        var changed = original
        let block = Array(changed[3_000..<3_400])
        changed.removeSubrange(3_000..<3_400)
        changed.insert(contentsOf: block, at: 17_000)
        var random = DiffChecks.Seeded(state: 4)
        for _ in 0..<100 {
            changed[Int.random(in: 0..<changed.count, using: &random)] =
                2_000_000 + Int.random(in: 0..<1_000_000, using: &random)
        }
        let segments = Myers.diff(original, changed)
        #expect(DiffChecks.isValid(segments, original, changed))
        #expect(Myers.editDistance(segments) <= 1_000 + 100)
    }

    /// Where the search is cut off, the lines that occur once on each side hold the diff together.
    @Test
    internal func whenTheSearchIsCutOffLinesUniqueToBothSidesHoldTheDiffTogether() {
        // A low limit forces the cut-off at once; the lines that occur once on each side anchor the result.
        let original = Array(0..<6_000)
        var changed = original
        changed.removeSubrange(2_000..<2_800)
        var random = DiffChecks.Seeded(state: 5)
        for _ in 0..<60 {
            changed[Int.random(in: 0..<changed.count, using: &random)] =
                100_000 + Int.random(in: 0..<100_000, using: &random)
        }
        for limit in [0, 1, 5, 20] {
            let segments = Myers.diff(original, changed, costLimit: limit)
            #expect(DiffChecks.isValid(segments, original, changed))
            #expect(Myers.editDistance(segments) <= 800 + 2 * 60 + 40)
        }
    }

    /// Diffs cut off at any limit stay valid on small random inputs.
    @Test
    internal func cutOffDiffsStayValidOnSmallRandomInputs() {
        var random = DiffChecks.Seeded(state: 6)
        for _ in 0..<400 {
            let first = (0..<Int.random(in: 0...40, using: &random)).map { _ in Int.random(in: 0..<6, using: &random) }
            let second = (0..<Int.random(in: 0...40, using: &random)).map { _ in Int.random(in: 0..<6, using: &random) }
            for limit in [0, 1, 2, 3, 8] {
                #expect(DiffChecks.isValid(Myers.diff(first, second, costLimit: limit), first, second))
            }
        }
    }

    /// The effort's limit follows the size of the input and stays within its bounds.
    @Test
    internal func theLimitFollowsTheSizeAndStaysBounded() {
        #expect(Myers.defaultLimit(forSize: 19_999) == nil)
        #expect(Myers.defaultLimit(forSize: 20_000) == 8_192)
        #expect((Myers.defaultLimit(forSize: 100_000) ?? 0) > 2_000)
        #expect(Myers.defaultLimit(forSize: 10_000_000) == 256)
    }

    /// Inside a line only the start of a huge line is compared; the rest counts as different.
    @Test
    internal func insideALineOnlyTheStartOfAHugeLineIsLookedAt() {
        let long = String(repeating: "abcdefghij", count: 200_000)
        let ranges = TextDiff.inline(long, long + "X")
        #expect(
            ranges.left.allSatisfy { range in range.upperBound <= long.utf16.count }
                && ranges.right.last?.upperBound == long.utf16.count + 1
        )
    }
}
