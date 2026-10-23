/// Unique anchors: the elements that occur exactly once in each of two stretches, as in the patience diff.
extension Myers {
    /// Scratch tables for `uniqueAnchors`, made once per diff: how often each kind of element occurs
    /// in the stretch looked at (0, 1 or 2 for more) on either side, and where in the second one.
    internal struct AnchorCounts {
        /// How often each kind occurs in the first stretch: 0, 1, or 2 for more.
        internal var inFirst: [UInt8]
        /// How often each kind occurs in the second stretch: 0, 1, or 2 for more.
        internal var inSecond: [UInt8]
        /// Where each kind last occurs in the second stretch.
        internal var positionInSecond: [Int32]

        /// Empty tables for `kinds` kinds of element.
        internal init(kinds: Int) {
            inFirst = [UInt8](repeating: 0, count: kinds)
            inSecond = [UInt8](repeating: 0, count: kinds)
            positionInSecond = [Int32](repeating: 0, count: kinds)
        }

        /// The first pile whose tail is not below `position`, found by halving; `tails.count` for a new pile.
        private static func pile(for position: Int, in tails: [Int]) -> Int {
            var (low, high) = (0, tails.count)
            while low < high {
                let middle = (low + high) / 2
                if tails[middle] < position {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }

        /// The longest run, rising on both sides, of the elements that occur exactly once in each of
        /// the two stretches: pairs of positions (patience diff).
        ///
        /// Empty when there are none. The tables are empty again afterwards.
        internal mutating func uniqueAnchors(
            _ first: UnsafeBufferPointer<Int32>,
            _ second: UnsafeBufferPointer<Int32>,
            in stretch: Stretch
        ) -> [(first: Int, second: Int)] {
            for position in stretch.firstStart..<stretch.firstEnd {
                let kind = Int(first[position])
                if inFirst[kind] < 2 {
                    inFirst[kind] += 1
                }
            }
            for position in stretch.secondStart..<stretch.secondEnd {
                let kind = Int(second[position])
                if inSecond[kind] < 2 {
                    inSecond[kind] += 1
                }
                positionInSecond[kind] = Int32(truncatingIfNeeded: position)
            }
            let anchors = longestRisingRun(first, in: stretch)
            for position in stretch.firstStart..<stretch.firstEnd {
                inFirst[Int(first[position])] = 0
            }
            for position in stretch.secondStart..<stretch.secondEnd {
                inSecond[Int(second[position])] = 0
            }
            return anchors
        }

        /// The longest rising run of the elements counted once on each side, by the piles of the patience sort.
        private func longestRisingRun(_ first: UnsafeBufferPointer<Int32>, in stretch: Stretch)
            -> [(first: Int, second: Int)]
        {
            // Piles of the patience sort: the smallest end position in the second of a rising run of each length.
            var tails: [Int] = []
            var tailIndex: [Int] = []
            var candidates: [AnchorCandidate] = []
            for position in stretch.firstStart..<stretch.firstEnd {
                let kind = Int(first[position])
                guard inFirst[kind] == 1, inSecond[kind] == 1 else {
                    continue
                }
                let partner = Int(positionInSecond[kind])
                let pile = Self.pile(for: partner, in: tails)
                candidates.append(
                    AnchorCandidate(first: position, second: partner, previous: pile > 0 ? tailIndex[pile - 1] : -1)
                )
                if pile == tails.count {
                    tails.append(partner)
                    tailIndex.append(candidates.count - 1)
                } else {
                    tails[pile] = partner
                    tailIndex[pile] = candidates.count - 1
                }
            }
            guard var current = tailIndex.last else {
                return []
            }
            var anchors: [(first: Int, second: Int)] = []
            while current >= 0 {
                anchors.append((candidates[current].first, candidates[current].second))
                current = candidates[current].previous
            }
            return anchors.reversed()
        }
    }

    /// An element on a pile of the patience sort: its positions, and the candidate before it in its run.
    internal struct AnchorCandidate {
        /// Its position in the first stretch.
        internal var first: Int
        /// Its position in the second stretch.
        internal var second: Int
        /// The index of the candidate before it in the longest run that ends here; -1 for none.
        internal var previous: Int
    }
}
