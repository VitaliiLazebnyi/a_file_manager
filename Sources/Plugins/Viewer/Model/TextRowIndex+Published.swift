import Foundation

/// The segments an index has published, and how a row, an offset or a line is found in them.
extension TextRowIndex {
    /// A segment that was read (or failed), waiting for those before it to be published.
    private struct FinishedSegment {
        let segment: Segment
        /// The end of the bytes the segment stands for.
        let end: Int64
        let failed: Bool
    }

    /// The segments that are published, in file order, and the counts that go with them.
    ///
    /// A value the index keeps behind its lock.
    internal struct Published {
        /// Rows of all published segments.
        internal private(set) var rows = 0
        /// Lines of all published segments.
        internal private(set) var lines = 0
        /// The rows of everything before this offset are known.
        internal private(set) var coveredEnd: Int64
        /// Whether the build ended with every segment published.
        internal private(set) var complete = false
        /// The first error that made a part of the file unreadable.
        internal private(set) var firstFailure: (any Error)?
        /// How many segments the last build took over from the layout before.
        internal var reused = 0
        private var finished: [Int: FinishedSegment] = [:]
        private var segments: [Segment] = []
        private var nextToPublish = 0
        /// Whether the last published segment is the unfinished frontier one, to be replaced by
        /// its next state.
        private var hasPartial = false

        /// How many checkpoints the published segments hold.
        internal var checkpointCount: Int {
            segments.reduce(0) { total, segment in total + segment.checkpoints.count }
        }

        /// The numbers the main thread reads.
        internal var counts: Counts {
            Counts(
                rows: rows,
                lines: lines,
                covered: coveredEnd,
                complete: complete,
                failure: firstFailure,
                reused: reused
            )
        }

        /// Nothing published yet of a text that starts at `start`.
        internal init(start: Int64) {
            coveredEnd = start
        }

        /// How many elements of a sorted array `matches` holds for (it holds for a prefix).
        private static func prefixCount<Elements: RandomAccessCollection>(
            in elements: Elements,
            where matches: (Elements.Element) -> Bool
        ) -> Int
        where Elements.Index == Int {
            var low = 0
            var high = elements.count
            while low < high {
                let middle = (low + high) / 2
                if matches(elements[middle]) { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// Keeps the first error that made a part of the file unreadable.
        internal mutating func recordFailure(_ error: any Error) {
            if firstFailure == nil { firstFailure = error }
        }

        /// Marks the index complete: its rows cover everything up to `end`.
        internal mutating func markComplete(at end: Int64) {
            complete = true
            coveredEnd = end
        }

        /// Shows what the segment that comes next has found so far, in place of its earlier state
        /// (`scan` hands on only a state that has rows).
        ///
        /// Returns whether anything was published.
        internal mutating func publishPartial(_ number: Int, _ segment: Segment, coveredEnd covered: Int64) -> Bool {
            guard number == nextToPublish else {
                return false
            }
            dropPartial()
            var next = segment
            next.firstRow = rows
            next.firstLine = lines
            rows += next.rowCount
            lines += next.lineCount
            segments.append(next)
            hasPartial = true
            coveredEnd = max(coveredEnd, covered)
            return true
        }

        /// Takes a finished segment and publishes every segment that now follows the published
        /// ones without a gap.
        ///
        /// Returns whether anything was published.
        internal mutating func finish(_ number: Int, _ segment: Segment, end: Int64, failed: Bool) -> Bool {
            finished[number] = FinishedSegment(segment: segment, end: end, failed: failed)
            if number == nextToPublish { dropPartial() }
            var publishedAny = false
            while let done = finished[nextToPublish] {
                var next = done.segment
                finished[nextToPublish] = nil
                nextToPublish += 1
                publishedAny = true
                // Every row that begins before the end of a segment belongs to a line that
                // begins in it or before it, so it is known now.
                coveredEnd = max(coveredEnd, done.end)
                // The rows after those of the segment before are not the next in the file.
                if done.failed, !segments.isEmpty { segments[segments.count - 1].endsAtGap = true }
                guard next.rowCount > 0 else { continue }
                next.firstRow = rows
                next.firstLine = lines
                rows += next.rowCount
                lines += next.lineCount
                segments.append(next)
            }
            return publishedAny
        }

        /// The checkpoint to start from to reach `row`; nil when the row is not known (yet).
        internal func position(ofRow row: Int) -> Position? {
            guard row >= 0, row < rows else {
                return nil
            }
            // The first segment begins with row 0.
            let segment = segments[Self.prefixCount(in: segments) { $0.firstRow <= row } - 1]
            return position(segment, min((row - segment.firstRow) / segment.stride, segment.checkpoints.count - 1))
        }

        /// The last checkpoint at or before a byte offset; nil when that part is not indexed yet.
        internal func position(before offset: Int64) -> Position? {
            // None when the offset is before the first segment that could be read.
            let count = Self.prefixCount(in: segments) { $0.checkpoints[0].offset <= offset }
            guard offset < coveredEnd || complete, count > 0 else {
                return nil
            }
            let segment = segments[count - 1]
            // Its first checkpoint is at or before the offset.
            return position(segment, Self.prefixCount(in: segment.checkpoints) { $0.offset <= offset } - 1)
        }

        /// The last checkpoint at or before the first row of a line (counted from 0).
        internal func position(beforeLine line: Int) -> Position? {
            guard line >= 0, line < lines else {
                return nil
            }
            // The first segment begins with line 0, and the first checkpoint of a segment with its first line.
            let segment = segments[Self.prefixCount(in: segments) { $0.firstLine <= line } - 1]
            return position(
                segment,
                Self.prefixCount(in: segment.checkpoints) { $0.linesBefore <= line - segment.firstLine } - 1
            )
        }

        private mutating func dropPartial() {
            guard hasPartial, let last = segments.popLast() else {
                return
            }
            rows -= last.rowCount
            lines -= last.lineCount
            hasPartial = false
        }

        private func position(_ segment: Segment, _ checkpoint: Int) -> Position {
            let point = segment.checkpoints[checkpoint]
            return Position(
                offset: point.offset,
                row: segment.firstRow + checkpoint * segment.stride,
                startsLine: point.startsLine,
                linesBefore: segment.firstLine + point.linesBefore,
                endRow: segment.endsAtGap ? segment.firstRow + segment.rowCount : nil
            )
        }
    }
}
