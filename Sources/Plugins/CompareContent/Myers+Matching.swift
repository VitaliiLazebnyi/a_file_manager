import AFMKernel

/// Matching: the partners of the elements, stretch by stretch.
extension Myers {
    /// A part of the two shortened sequences still to be matched: `firstStart..<firstEnd` of the first with
    /// `secondStart..<secondEnd` of the second.
    internal struct Stretch {
        /// Where the part of the first sequence starts.
        internal var firstStart: Int
        /// Where the part of the first sequence ends.
        internal var firstEnd: Int
        /// Where the part of the second sequence starts.
        internal var secondStart: Int
        /// Where the part of the second sequence ends.
        internal var secondEnd: Int

        /// Whether neither part is empty, so that there is something to match.
        internal var isOpen: Bool { firstStart < firstEnd && secondStart < secondEnd }
    }

    /// One matching of two shortened sequences: the stretches still to be solved and the partners found so far.
    internal struct Matcher {
        /// The first shortened sequence.
        internal let first: UnsafeBufferPointer<Int32>
        /// The second shortened sequence.
        internal let second: UnsafeBufferPointer<Int32>
        /// Where each element of the first shortened sequence stands in the whole first sequence.
        internal let keptFirst: [Int]
        /// Where each element of the second shortened sequence stands in the whole second sequence.
        internal let keptSecond: [Int]
        /// The most rounds of one search for a middle; nil for no bound.
        internal let limit: Int?
        /// The walks' tables, `2 * (2 * reach + 2)` places, shared by every search.
        internal let tables: UnsafeMutablePointer<Int>
        /// The most diagonals one walk can take, which sizes the tables.
        internal let reach: Int
        /// The scratch tables for the unique anchors.
        internal var counts: AnchorCounts
        /// For every element of the whole first sequence the position of its partner in the second, or -1.
        internal var match: [Int]
        /// The stretches still to be solved.
        internal var pending: [Stretch]

        /// Solves the stretches until none is left, or `cancellation` is set.
        internal mutating func run(cancellation: CancellationFlag?) {
            while var stretch = pending.popLast() {
                if cancellation?.isCancelled == true {
                    break
                }
                matchEqualEnds(of: &stretch)
                guard stretch.isOpen,
                    let split = Myers.middle(
                        UnsafeBufferPointer(rebasing: first[stretch.firstStart..<stretch.firstEnd]),
                        UnsafeBufferPointer(rebasing: second[stretch.secondStart..<stretch.secondEnd]),
                        limit: limit,
                        tables: tables,
                        reach: reach
                    )
                else {
                    continue
                }
                // The search was cut off. Lines that both sides have exactly once are fixed points
                // that a block moved or deleted far away cannot lead astray.
                if !split.isExact, splitAtUniqueAnchors(stretch) {
                    continue
                }
                let middleFirst = stretch.firstStart + split.first
                let middleSecond = stretch.secondStart + split.second
                pending.append(
                    Stretch(
                        firstStart: stretch.firstStart,
                        firstEnd: middleFirst,
                        secondStart: stretch.secondStart,
                        secondEnd: middleSecond
                    )
                )
                pending.append(
                    Stretch(
                        firstStart: middleFirst,
                        firstEnd: stretch.firstEnd,
                        secondStart: middleSecond,
                        secondEnd: stretch.secondEnd
                    )
                )
            }
        }

        /// Matches the elements the two parts share at their start and at their end, and takes them out.
        private mutating func matchEqualEnds(of stretch: inout Stretch) {
            while stretch.isOpen, first[stretch.firstStart] == second[stretch.secondStart] {
                match[keptFirst[stretch.firstStart]] = keptSecond[stretch.secondStart]
                stretch.firstStart += 1
                stretch.secondStart += 1
            }
            while stretch.isOpen, first[stretch.firstEnd - 1] == second[stretch.secondEnd - 1] {
                match[keptFirst[stretch.firstEnd - 1]] = keptSecond[stretch.secondEnd - 1]
                stretch.firstEnd -= 1
                stretch.secondEnd -= 1
            }
        }

        /// Matches the unique anchors of the stretch and leaves the parts between them to be solved; false when
        /// the stretch has none.
        private mutating func splitAtUniqueAnchors(_ stretch: Stretch) -> Bool {
            let anchors = counts.uniqueAnchors(first, second, in: stretch)
            guard !anchors.isEmpty else {
                return false
            }
            var (inFirst, inSecond) = (stretch.firstStart, stretch.secondStart)
            for anchor in anchors {
                pending.append(
                    Stretch(
                        firstStart: inFirst,
                        firstEnd: anchor.first,
                        secondStart: inSecond,
                        secondEnd: anchor.second
                    )
                )
                match[keptFirst[anchor.first]] = keptSecond[anchor.second]
                (inFirst, inSecond) = (anchor.first + 1, anchor.second + 1)
            }
            pending.append(
                Stretch(
                    firstStart: inFirst,
                    firstEnd: stretch.firstEnd,
                    secondStart: inSecond,
                    secondEnd: stretch.secondEnd
                )
            )
            return true
        }
    }

    /// For every element of `first` the position of its partner in `second`, or -1.
    ///
    /// The partners rise with the positions.
    internal static func matching(
        _ first: [Int32],
        _ second: [Int32],
        kinds: Int,
        costLimit: Int?,
        cancellation: CancellationFlag?
    ) -> [Int] {
        var inFirst = [Bool](repeating: false, count: kinds)
        var inSecond = [Bool](repeating: false, count: kinds)
        for element in first {
            inFirst[Int(element)] = true
        }
        for element in second {
            inSecond[Int(element)] = true
        }
        let keptFirst = first.indices.filter { index in inSecond[Int(first[index])] }
        let keptSecond = second.indices.filter { index in inFirst[Int(second[index])] }
        let shortFirst = keptFirst.map { index in first[index] }
        let shortSecond = keptSecond.map { index in second[index] }

        let size = shortFirst.count + shortSecond.count
        let limit = costLimit ?? defaultLimit(forSize: size)
        // The two walks' tables are made once, for the largest split: with a limit the walks
        // stop after `limit` rounds, so that bounds their size, not the length of the input.
        let widest = (size + 1) / 2 + 1
        let reach = limit.map { rounds in min(widest, rounds + 1) } ?? widest
        let tables = UnsafeMutablePointer<Int>.allocate(capacity: 2 * (2 * reach + 2))
        defer { tables.deallocate() }
        return shortFirst.withUnsafeBufferPointer { firstBuffer in
            shortSecond.withUnsafeBufferPointer { secondBuffer in
                var matcher = Matcher(
                    first: firstBuffer,
                    second: secondBuffer,
                    keptFirst: keptFirst,
                    keptSecond: keptSecond,
                    limit: limit,
                    tables: tables,
                    reach: reach,
                    counts: AnchorCounts(kinds: kinds),
                    match: [Int](repeating: -1, count: first.count),
                    pending: [
                        Stretch(
                            firstStart: 0,
                            firstEnd: firstBuffer.count,
                            secondStart: 0,
                            secondEnd: secondBuffer.count
                        )
                    ]
                )
                matcher.run(cancellation: cancellation)
                return matcher.match
            }
        }
    }
}
