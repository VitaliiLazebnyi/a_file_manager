import Foundation

/// What the index keeps of the rows of a text.
extension TextRowIndex {
    /// A row whose start is kept: every `stride`th row of a segment.
    internal struct Checkpoint {
        /// Where the row begins in the file.
        internal var offset: Int64
        /// Lines of this segment that begin before this row.
        internal var linesBefore: Int
        /// Whether the row begins a line (and is not the continuation of a wrapped one).
        internal var startsLine: Bool
    }

    /// Checkpoints in 12 bytes each instead of 24: the offset with the flag in its lowest bit,
    /// and the line count relative to the segment, which a segment cannot overflow.
    ///
    /// They are kept in chunks, so a copy of the list that was published (the partial state of a
    /// segment) shares all full chunks and appending to the original copies the outer array and one
    /// chunk at most, whatever the length of the list.
    internal struct CheckpointList: RandomAccessCollection {
        private static let chunkShift = 12
        private static let chunkSize = 1 << chunkShift
        private var marks: [[Int64]] = []
        private var lines: [[UInt32]] = []
        /// How many checkpoints the list holds.
        internal private(set) var count = 0

        /// The index of the first checkpoint: 0.
        internal var startIndex: Int { 0 }
        /// The index after the last checkpoint: `count`.
        internal var endIndex: Int { count }

        /// Adds a checkpoint at the end.
        internal mutating func append(_ checkpoint: Checkpoint) {
            if count & (Self.chunkSize - 1) == 0 {
                marks.append([])
                lines.append([])
                marks[marks.count - 1].reserveCapacity(Self.chunkSize)
                lines[lines.count - 1].reserveCapacity(Self.chunkSize)
            }
            marks[marks.count - 1].append(checkpoint.offset << 1 | (checkpoint.startsLine ? 1 : 0))
            lines[lines.count - 1].append(UInt32(truncatingIfNeeded: checkpoint.linesBefore))
            count += 1
        }

        /// Every `step`th checkpoint, the first included.
        internal func thinned(every step: Int) -> Self {
            var result = Self()
            for index in Swift.stride(from: 0, to: count, by: Swift.max(1, step)) { result.append(self[index]) }
            return result
        }

        /// The checkpoint at `index`.
        internal subscript(index: Int) -> Checkpoint {
            let chunk = index >> Self.chunkShift
            let inChunk = index & (Self.chunkSize - 1)
            let mark = marks[chunk][inChunk]
            return Checkpoint(offset: mark >> 1, linesBefore: Int(lines[chunk][inChunk]), startsLine: mark & 1 == 1)
        }
    }

    /// The rows of the lines that begin in one part of the file.
    internal struct Segment {
        /// The number of the segment's first row in the whole text (set when it is published).
        internal var firstRow = 0
        /// The number of the segment's first line in the whole text (set when it is published).
        internal var firstLine = 0
        /// The rows of the segment.
        internal var rowCount = 0
        /// The lines that begin in the segment.
        internal var lineCount = 0
        /// The rows whose starts are kept.
        internal var checkpoints = CheckpointList()
        /// Rows between two checkpoints: 64, or a multiple of it where rows are very short.
        internal var stride = TextRowIndex.stride
        /// The widest line of the segment in columns (an upper bound), or `Int.max` when a line
        /// takes more than one row: with a width that holds the widest line, every line takes
        /// one row and the segment is the same as it is here.
        internal var widest = 0
        /// Whether the segment that follows in the file is missing (it could not be read), so
        /// the rows after the last one of this segment are not those of the next row number.
        internal var endsAtGap = false
        /// Where the first line begins that this segment does not own: the line start behind its
        /// last row, or the end of the text. nil when the scan did not get there.
        ///
        /// A sequential build passes it on, so the segments in between (a line longer than they
        /// are) are not read again only to find that no line begins in them.
        internal var nextStart: Int64?

        /// Keeps fewer checkpoints when the segment has too many for the bytes its rows cover:
        /// `bytes` is that span (from the first checkpoint to the end of the last row, which is
        /// far more than the nominal size of the segment when a line is longer than a segment).
        ///
        /// On average they stay `minimumCheckpointDistance` bytes apart, and there are never more
        /// than `maximumCheckpoints`.
        internal mutating func thin(spanning bytes: Int64) {
            let count = checkpoints.count
            guard count > 1 else {
                return
            }
            let span = max(1, bytes)
            // (A number of checkpoints, which are in memory, times 4 KB does not overflow.)
            let product = Int64(count) * Int64(TextRowIndex.minimumCheckpointDistance)
            let byDistance = Int((product + span - 1) / span)
            let byCount = (count + TextRowIndex.maximumCheckpoints - 1) / TextRowIndex.maximumCheckpoints
            let wanted = max(byDistance, byCount)
            guard wanted > 1 else {
                return
            }
            // A power of two, and never more than the checkpoints there are: the first is kept.
            var step = 2
            while step < wanted, step < count { step *= 2 }
            checkpoints = checkpoints.thinned(every: step)
            stride *= step
        }
    }

    /// Where to start cutting to reach a row.
    internal struct Position {
        /// The byte offset of the checkpoint row.
        internal var offset: Int64
        /// The number of the checkpoint row.
        internal var row: Int
        /// Whether the checkpoint row begins a line.
        internal var startsLine: Bool
        /// Lines that begin before the checkpoint row, in the whole text.
        internal var linesBefore: Int
        /// The row the text must not be walked past from here (a segment that could not be read
        /// follows); nil when the rows go on.
        internal var endRow: Int?
    }
}
