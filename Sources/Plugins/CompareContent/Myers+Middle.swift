/// The middle: where a shortest edit path of two stretches crosses, found from both ends.
extension Myers {
    /// A point on an edit path where a stretch is split in two: the first `first` elements of the first
    /// sequence and the first `second` of the second come before it.
    internal struct Split {
        /// How many elements of the first sequence come before the point.
        internal var first: Int
        /// How many elements of the second sequence come before the point.
        internal var second: Int
        /// Whether the point is on a shortest edit path; false where the search was cut off and took the furthest
        /// point reached.
        internal var isExact: Bool
    }

    /// The two walks of one search for a middle: from the start of both sequences forward and from their ends
    /// backward, a round at a time, until they meet.
    ///
    /// The tables are the caller's, shared by every search of one diff; the part one search uses is cleared when
    /// it starts. A walk keeps, for each diagonal (position in the first minus position in the second), the
    /// furthest position in the first it reached.
    internal struct MiddleWalk {
        /// The first sequence.
        internal let first: UnsafeBufferPointer<Int32>
        /// The second sequence.
        internal let second: UnsafeBufferPointer<Int32>
        /// How many rounds the walks take at most; also where diagonal 0 is in the tables.
        internal let rounds: Int
        /// How many places of each table the search uses.
        private let length: Int
        /// The furthest position reached walking forward, by diagonal plus `rounds`; -1 for none yet.
        private let forwardReach: UnsafeMutablePointer<Int>
        /// The furthest position reached walking backward, counted from the ends, by diagonal plus `rounds`.
        private let backwardReach: UnsafeMutablePointer<Int>
        /// How much longer the first sequence is than the second.
        private let delta: Int
        /// Whether the forward walk closes the gap (an odd `delta`); else the backward one does.
        private let forwardMeets: Bool
        /// How many diagonals at the low and the high end the forward walk no longer takes: they left the
        /// sequences.
        private var forwardTrim = (low: 0, high: 0)
        /// The same for the backward walk.
        private var backwardTrim = (low: 0, high: 0)

        /// A search of `first` against `second` in `tables`, sized for `reach` diagonals; with a `limit`, the walks
        /// stop after that many rounds.
        internal init(
            _ first: UnsafeBufferPointer<Int32>,
            _ second: UnsafeBufferPointer<Int32>,
            limit: Int?,
            tables: UnsafeMutablePointer<Int>,
            reach: Int
        ) {
            self.first = first
            self.second = second
            rounds = min((first.count + second.count + 1) / 2, limit.map { bound in bound + 1 } ?? Int.max)
            length = 2 * rounds + 2
            forwardReach = tables
            backwardReach = tables + (2 * reach + 2)
            forwardReach.update(repeating: -1, count: length)
            backwardReach.update(repeating: -1, count: length)
            forwardReach[rounds + 1] = 0
            backwardReach[rounds + 1] = 0
            delta = first.count - second.count
            // With an odd difference in length the forward walk closes the gap, else the backward.
            forwardMeets = !delta.isMultiple(of: 2)
        }

        /// Where a walk goes on along `diagonal` in `round`: from the neighbour that got further.
        private static func start(on diagonal: Int, round: Int, in reach: UnsafeMutablePointer<Int>, at slot: Int)
            -> Int
        {
            diagonal == -round || (diagonal != round && reach[slot - 1] < reach[slot + 1])
                ? reach[slot + 1] : reach[slot - 1] + 1
        }

        /// One round of the forward walk; the middle when it meets the backward walk.
        internal mutating func forward(_ round: Int) -> Split? {
            var diagonal = -round + forwardTrim.low
            while diagonal <= round - forwardTrim.high {
                let slot = rounds + diagonal
                var inFirst = Self.start(on: diagonal, round: round, in: forwardReach, at: slot)
                var inSecond = inFirst - diagonal
                while inFirst < first.count, inSecond < second.count, first[inFirst] == second[inSecond] {
                    inFirst += 1
                    inSecond += 1
                }
                forwardReach[slot] = inFirst
                if inFirst > first.count {
                    forwardTrim.high += 2
                } else if inSecond > second.count {
                    forwardTrim.low += 2
                } else if forwardMeets {
                    let other = rounds + delta - diagonal
                    if other >= 0, other < length, backwardReach[other] != -1,
                        inFirst >= first.count - backwardReach[other]
                    {
                        return Split(first: inFirst, second: inSecond, isExact: true)
                    }
                }
                diagonal += 2
            }
            return nil
        }

        /// One round of the backward walk; the middle when it meets the forward walk.
        internal mutating func backward(_ round: Int) -> Split? {
            var diagonal = -round + backwardTrim.low
            while diagonal <= round - backwardTrim.high {
                let slot = rounds + diagonal
                var fromEnd = Self.start(on: diagonal, round: round, in: backwardReach, at: slot)
                var fromEndSecond = fromEnd - diagonal
                while fromEnd < first.count, fromEndSecond < second.count,
                    first[first.count - fromEnd - 1] == second[second.count - fromEndSecond - 1]
                {
                    fromEnd += 1
                    fromEndSecond += 1
                }
                backwardReach[slot] = fromEnd
                if fromEnd > first.count {
                    backwardTrim.high += 2
                } else if fromEndSecond > second.count {
                    backwardTrim.low += 2
                } else if !forwardMeets {
                    let other = rounds + delta - diagonal
                    if other >= 0, other < length, forwardReach[other] != -1,
                        forwardReach[other] >= first.count - fromEnd
                    {
                        let inFirst = forwardReach[other]
                        return Split(first: inFirst, second: rounds + inFirst - other, isExact: true)
                    }
                }
                diagonal += 2
            }
            return nil
        }

        /// Out of effort after `round`: the point that either walk got furthest with.
        ///
        /// Seen from the start (forward) or from the end (backward); the one that progressed more is taken. Nil when
        /// neither moved.
        internal func furthest(after round: Int) -> Split? {
            var best: Split?
            var progress = 0
            var diagonal = -round + forwardTrim.low
            while diagonal <= round - forwardTrim.high {
                let inFirst = forwardReach[rounds + diagonal]
                let inSecond = inFirst - diagonal
                if isInside(inFirst, inSecond), inFirst + inSecond > progress {
                    best = Split(first: inFirst, second: inSecond, isExact: false)
                    progress = inFirst + inSecond
                }
                diagonal += 2
            }
            diagonal = -round + backwardTrim.low
            while diagonal <= round - backwardTrim.high {
                let fromEnd = backwardReach[rounds + diagonal]
                let fromEndSecond = fromEnd - diagonal
                if isInside(fromEnd, fromEndSecond), fromEnd + fromEndSecond > progress {
                    best = Split(first: first.count - fromEnd, second: second.count - fromEndSecond, isExact: false)
                    progress = fromEnd + fromEndSecond
                }
                diagonal += 2
            }
            return best
        }

        /// Whether a point lies within both sequences and short of their joint end.
        private func isInside(_ inFirst: Int, _ inSecond: Int) -> Bool {
            inFirst >= 0 && inFirst <= first.count && inSecond >= 0 && inSecond <= second.count
                && inFirst + inSecond < first.count + second.count
        }
    }

    /// A point on a shortest edit path of two sequences that share neither a start nor an
    /// end, found by walking from both corners until the walks meet.
    ///
    /// Nil when the sequences have nothing in common. With a `limit`, the walks stop after that
    /// many rounds and the point is the furthest either of them reached (`isExact` is false then).
    internal static func middle(
        _ first: UnsafeBufferPointer<Int32>,
        _ second: UnsafeBufferPointer<Int32>,
        limit: Int?,
        tables: UnsafeMutablePointer<Int>,
        reach: Int
    ) -> Split? {
        var walk = MiddleWalk(first, second, limit: limit, tables: tables, reach: reach)
        for round in 0..<walk.rounds {
            if let split = walk.forward(round) ?? walk.backward(round) {
                return split
            }
            if let limit, round >= limit, let split = walk.furthest(after: round) {
                return split
            }
        }
        return nil
    }
}
