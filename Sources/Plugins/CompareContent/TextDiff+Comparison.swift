import AFMKernel

/// The comparison of two texts behind `compute`.
extension TextDiff {
    /// Two texts to compare line by line, with how lines count as equal and how much effort a diff may take.
    ///
    /// `hashes` makes the lines' hashes: `DiffOptions.hashes`, or, in a test that needs two different lines with
    /// the same hash (which the real one as good as never gives), one that makes them.
    internal struct Comparison {
        /// The lines of the left file.
        internal let left: [TextLine]
        /// The lines of the right file.
        internal let right: [TextLine]
        /// When two lines count as equal.
        internal let options: DiffOptions
        /// The effort per split of the diff, as in `Myers.diff`; nil chooses by size.
        internal let costLimit: Int?
        /// Cuts the rows short when set.
        internal let cancellation: CancellationFlag?
        /// The hashes of lines, equal for lines that `options` count as equal.
        internal let hashes: @Sendable ([TextLine]) -> [UInt64]

        /// The rows of a stretch of the left text against one of the right, starting at their lower bounds.
        private static func appendRows(
            of segment: DiffSegment,
            at start: (left: Int, right: Int),
            to rows: inout [DiffRow]
        ) {
            let (first, second) = (segment.first.lowerBound + start.left, segment.second.lowerBound + start.right)
            if segment.isEqual {
                for offset in 0..<segment.first.count {
                    rows.append(DiffRow(left: first + offset, right: second + offset, kind: .equal))
                }
                return
            }
            // Replaced lines face each other as far as they go; the rest stands alone.
            let paired = min(segment.first.count, segment.second.count)
            for offset in 0..<paired {
                rows.append(DiffRow(left: first + offset, right: second + offset, kind: .changed))
            }
            for offset in paired..<segment.first.count {
                rows.append(DiffRow(left: first + offset, right: nil, kind: .removed))
            }
            for offset in paired..<segment.second.count {
                rows.append(DiffRow(left: nil, right: second + offset, kind: .added))
            }
        }

        /// The two texts laid side by side; `anchors` are pairs of lines the user said belong together ("Resync
        /// comparison from here"): the texts before and after each are compared on their own.
        internal func diff(anchors: [(left: Int, right: Int)]) -> TextDiff {
            // One side after the other: a long side is spread over all cores by itself, and a
            // short one costs little.
            let keys = (left: hashes(left), right: hashes(right))
            var found: [DiffRow] = []
            found.reserveCapacity(max(left.count, right.count))
            var (nextLeft, nextRight) = (0, 0)
            for anchor in anchors.sorted(by: { first, second in first.left < second.left })
            where anchor.left >= nextLeft && anchor.right >= nextRight && anchor.left < left.count
                && anchor.right < right.count
            {
                compare(nextLeft..<anchor.left, nextRight..<anchor.right, keys: keys, into: &found)
                found.append(
                    DiffRow(
                        left: anchor.left,
                        right: anchor.right,
                        kind: keys.left[anchor.left] == keys.right[anchor.right]
                            && options.isSameKey(left[anchor.left], right[anchor.right])
                            ? .equal : .changed
                    )
                )
                (nextLeft, nextRight) = (anchor.left + 1, anchor.right + 1)
            }
            compare(nextLeft..<left.count, nextRight..<right.count, keys: keys, into: &found)
            // Lines are paired by their hashes; a pair that is not really equal (a collision, which
            // is as good as never) is shown as changed.
            for index in found.indices where found[index].kind == .equal {
                let (one, two) = (found[index].left, found[index].right)
                if let one, let two, !options.isSameKey(left[one], right[two]) {
                    found[index] = DiffRow(left: one, right: two, kind: .changed)
                }
            }
            return TextDiff(rows: found, blocks: TextDiff.blocks(of: found))
        }

        /// Appends the rows of a stretch of each text, compared by their keys.
        private func compare(
            _ leftRange: Range<Int>,
            _ rightRange: Range<Int>,
            keys: (left: [UInt64], right: [UInt64]),
            into rows: inout [DiffRow]
        ) {
            for segment in Myers.diff(
                Array(keys.left[leftRange]),
                Array(keys.right[rightRange]),
                costLimit: costLimit,
                cancellation: cancellation
            ) {
                Self.appendRows(of: segment, at: (leftRange.lowerBound, rightRange.lowerBound), to: &rows)
            }
        }
    }
}
