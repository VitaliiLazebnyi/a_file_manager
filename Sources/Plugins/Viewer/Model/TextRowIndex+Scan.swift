import AFMKernel
import Foundation

/// How one segment of a text is read and cut into rows.
extension TextRowIndex {
    /// What an index is built from: the bytes of a source, in an encoding, laid out with options.
    internal struct Input: Sendable {
        /// Where the bytes come from.
        internal let source: any ByteSource
        /// The bytes that are text (after a byte-order mark).
        internal let content: Range<Int64>
        /// The encoding of the text.
        internal let encoding: ViewerEncoding
        /// How the text is cut into rows.
        internal let options: TextLayoutOptions
    }

    /// How a build reads its text.
    internal struct ScanOptions: Sendable {
        /// What the viewer uses: segments of 4 MB read 1 MB at a time, plain lines found in the raw
        /// bytes.
        internal static let standard = Self(segmentSize: 4 << 20, chunkSize: 1 << 20, rawScan: true)

        /// The bytes of a segment, the part of the text one thread reads.
        internal var segmentSize: Int
        /// The bytes read at a time (at least 16).
        internal var chunkSize: Int
        /// Whether plain lines are found in the raw bytes; off decodes every byte (the reference
        /// the fast scan is tested against).
        internal var rawScan: Bool
    }

    /// One segment to scan, and where its news go.
    internal struct SegmentJob {
        /// The bytes whose lines the segment owns.
        internal var segment: Range<Int64>
        /// Whether this is the first segment: a line begins at its start.
        internal var isFirst: Bool
        /// Where a line is known to begin (inside the segment), nil when that is not known.
        ///
        /// Nothing before it is read.
        internal var lineStart: Int64?
        /// Handed what is found so far, and the offset read up to, every few megabytes.
        internal var partial: ((Segment, Int64) -> Void)?
        /// Called when a read came back short: the file became shorter.
        internal var changed: (() -> Void)?
    }

    /// The scan of one segment: what it has recorded so far, what it does with the next row,
    /// and the text it is cutting.
    private struct SegmentScan {
        let segment: Range<Int64>
        let unit: Int64
        var result = Segment()
        var skipping: Bool
        var stopped = false
        /// Where the last row recorded begins.
        var lastOffset: Int64 = 0
        var splitter: RowSplitter
        var text = DecodedText()
        /// The file offset of the first byte not used yet.
        var base: Int64
        let encoding: ViewerEncoding
        let unitSize: Int
        let columns: Int
        let bigEndian: Bool
        let rawScan: Bool

        init(_ input: Input, _ job: SegmentJob, rawScan: Bool) {
            // With `lineStart`, a line is known to begin there (inside the segment): nothing before it is read.
            let startsAtLine = job.isFirst || job.lineStart != nil
            segment = job.segment
            unitSize = input.encoding.unitSize
            unit = Int64(unitSize)
            skipping = !startsAtLine
            splitter = RowSplitter(input.options)
            splitter.startsLine = startsAtLine
            base = job.lineStart ?? job.segment.lowerBound
            encoding = input.encoding
            columns = input.options.columns
            bigEndian = input.encoding.kind == .utf16BE
            self.rawScan = rawScan
        }

        /// Records a row (`width` columns wide); false when the scan is past the end of its segment.
        @inline(__always)
        mutating func take(offset: Int64, startsLine: Bool, width: Int) -> Bool {
            if startsLine {
                if offset > segment.upperBound {
                    stopped = true
                    result.nextStart = offset
                    return false
                }
                skipping = false
            } else if skipping, offset > segment.upperBound + unit {
                // No line begins in this segment at all.
                stopped = true
                return false
            }
            if skipping {
                return true
            }
            lastOffset = offset
            if result.rowCount.isMultiple(of: result.stride) {
                addCheckpoint(Checkpoint(offset: offset, linesBefore: result.lineCount, startsLine: startsLine))
            }
            if startsLine {
                result.lineCount += 1
                if width > result.widest { result.widest = width }
            } else {
                result.widest = .max
            }
            result.rowCount += 1
            return true
        }

        /// Records `count` empty lines of one byte each (a run of LF), the first at `offset`:
        /// the same as `take` for each, without the cost of it.
        mutating func takeEmptyLines(offset: Int64, count: Int) {
            var taken = count
            let room = segment.upperBound - offset
            if room < Int64(taken - 1) {
                taken = max(0, Int(room) + 1)
                stopped = true
                // The first line that is not this segment's: the one after those taken. When
                // the run begins past the segment's end (the line before it reached over the
                // end) none is taken and that line is the run's first; "one past the end" was
                // then a place in the middle of the line before, and the next segment, told
                // that a line began there, made a row of its own out of that line's tail.
                result.nextStart = offset + Int64(taken)
            }
            guard taken > 0 else {
                return
            }
            skipping = false
            lastOffset = offset + Int64(taken)
            let first = result.rowCount
            var row = (first + result.stride - 1) / result.stride * result.stride
            while row < first + taken {
                addCheckpoint(
                    Checkpoint(
                        offset: offset + Int64(row - first),
                        linesBefore: result.lineCount + row - first,
                        startsLine: true
                    )
                )
                // The stride may have doubled meanwhile.
                row = (row / result.stride + 1) * result.stride
            }
            result.lineCount += taken
            result.rowCount += taken
        }

        /// Cuts `buffer[range]` (its first byte at `base`) into rows, records them, and returns the
        /// bytes used.
        ///
        /// Plain ASCII is cut from its bytes, anything else is decoded first.
        mutating func cut(_ buffer: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, final: Bool) -> Int {
            let origin = base + Int64(range.lowerBound)
            // The splitter is worked on as a copy: the rows it reports change the rest of the scan.
            var rows = splitter
            defer { splitter = rows }
            if rawScan, unitSize == 1, let start = buffer.baseAddress,
                TextRowIndex.isASCII(start + range.lowerBound, range.count)
            {
                let piece = UnsafeBufferPointer(rebasing: buffer[range])
                return rows.splitMeasuring(piece, final: final) { first, _, startsLine, width in
                    take(offset: origin + Int64(first), startsLine: startsLine, width: width)
                }
            }
            let used = encoding.decode(UnsafeBufferPointer(rebasing: buffer[range]), final: final, into: &text)
            let decoded = text
            let consumedUnits = decoded.units.withUnsafeBufferPointer { units in
                rows.splitMeasuring(units, final: final) { first, _, startsLine, width in
                    take(offset: origin + Int64(decoded.offsets[first]), startsLine: startsLine, width: width)
                }
            }
            return consumedUnits == decoded.units.count ? used : Int(decoded.offsets[consumedUnits])
        }

        /// Cuts what `buffer` holds into rows and returns the bytes used (its first byte is at
        /// `base`).
        ///
        /// Most lines are short and plain: they are one row each, and a row is all that is wanted
        /// of them, so only the line ends are looked for in the raw bytes. Decoding is left to the
        /// lines that may need more than one row (longer than a row, or with tabs) and to the ends
        /// of unfinished lines.
        mutating func cutLines(_ buffer: UnsafeBufferPointer<UInt8>, atEnd: Bool) -> Int {
            let count = buffer.count
            guard !buffer.isEmpty, let start = buffer.baseAddress else {
                return 0
            }
            let finder = LineFinder(buffer: buffer, start: start, unit: unitSize, bigEndian: bigEndian)
            var position = 0
            var nextLF = -1
            var nextCR = -1
            while position < count, !stopped {
                if unitSize == 1, splitter.startsLine, buffer[position] == 0x0A {
                    // A run of empty lines costs no more than looking at its bytes.
                    let run = finder.emptyRun(from: position)
                    if run - position >= 4 {
                        takeEmptyLines(offset: base + Int64(position), count: run - position)
                        position = run
                        continue
                    }
                }
                let line = finder.lineEnd(from: position, nextLF: &nextLF, nextCR: &nextCR)
                guard line.end < count else {
                    position = cutTail(buffer, from: position, atEnd: atEnd)
                    break
                }
                guard let end = finder.endOfLineEnd(at: line.end, atEnd: atEnd) else {
                    break
                }
                let length = line.end - position
                // The width is bounded by the bytes for 8-bit units (a wide character takes 2 columns and
                // at least 2 bytes, except in UTF-8 where it takes 3), but a 16-bit unit may be 2 columns wide.
                let widthBound = unitSize == 2 ? length : length / unitSize
                if splitter.startsLine, widthBound <= columns,
                    line.plainShort || length == 0 || memchr(start + position, 0x09, length) == nil
                {
                    _ = take(offset: base + Int64(position), startsLine: true, width: widthBound)
                } else {
                    _ = cut(buffer, position..<end, final: true)
                }
                position = end
            }
            return position
        }

        /// Keeps a checkpoint.
        ///
        /// A segment that holds a line of gigabytes keeps thinning its checkpoints as the line goes
        /// on, so it never holds more than a fixed number whatever its length: thinning waits for
        /// 2,048, where one thinning halves them.
        @inline(__always)
        private mutating func addCheckpoint(_ checkpoint: Checkpoint) {
            result.checkpoints.append(checkpoint)
            if result.checkpoints.count >= TextRowIndex.thinningThreshold {
                result.thin(spanning: checkpoint.offset - result.checkpoints[0].offset + 1)
            }
        }

        /// Cuts the line from `position` on, which does not end in the buffer, and returns where
        /// the unused bytes begin.
        ///
        /// At the end of the text it is cut whole; else as far as it goes, unless it may still be
        /// one plain row.
        private mutating func cutTail(_ buffer: UnsafeBufferPointer<UInt8>, from position: Int, atEnd: Bool) -> Int {
            let count = buffer.count
            if atEnd {
                _ = cut(buffer, position..<count, final: true)
                return count
            }
            guard !(splitter.startsLine && (count - position) / unitSize <= columns) else {
                return position
            }
            return position + cut(buffer, position..<count, final: false)
        }
    }

    /// How much of a segment is read between two partial results.
    private static let partialInterval = 4 << 20

    /// The rows of one segment: those of the lines that begin inside it.
    ///
    /// A line belongs to the segment its first byte is in (`lower < start <= upper`; the very first
    /// line to the first segment), wherever it ends, so the segments need nothing from each other:
    /// each looks for the first line start behind its lower bound and reads on past its upper bound
    /// to the end of its last line. The job's `partial` is handed what is found so far, every few
    /// megabytes.
    internal static func scan(
        _ input: Input,
        _ job: SegmentJob,
        scanning: ScanOptions,
        cancellation: CancellationFlag
    ) throws -> Segment {
        var state = SegmentScan(input, job, rawScan: scanning.rawScan)
        var bytes: [UInt8] = []
        var readPosition = state.base
        var sincePartial = 0
        while !cancellation.isCancelled {
            let wanted = Int(min(Int64(max(scanning.chunkSize, 16)), input.content.upperBound - readPosition))
            let chunk = try input.source.read(at: readPosition, count: wanted, cancellation: cancellation)
            readPosition += Int64(chunk.count)
            bytes.append(contentsOf: chunk)
            // A read that comes back short inside the file means the file is shorter than it
            // was: what is found stays, and the change is reported.
            let ended = chunk.count < wanted
            if ended { job.changed?() }
            let atEnd = ended || readPosition >= input.content.upperBound
            let consumed = bytes.withUnsafeBufferPointer { buffer in
                scanning.rawScan
                    ? state.cutLines(buffer, atEnd: atEnd) : state.cut(buffer, 0..<buffer.count, final: atEnd)
            }
            if state.stopped { break }
            if atEnd {
                if !state.skipping { state.result.nextStart = input.content.upperBound }
                break
            }
            bytes.removeFirst(consumed)
            state.base += Int64(consumed)
            if state.skipping, state.base > job.segment.upperBound + state.unit { break }
            sincePartial += chunk.count
            if let partial = job.partial, !state.skipping, state.result.rowCount > 0, sincePartial >= partialInterval {
                sincePartial = 0
                partial(state.result, state.base)
            }
        }
        // The bytes the rows cover: the segment, or more where a line goes on past its end.
        if let first = state.result.checkpoints.first {
            let span = max(job.segment.upperBound - job.segment.lowerBound, state.lastOffset - first.offset)
            state.result.thin(spanning: span)
        }
        return state.result
    }

    /// Whether all `count` bytes are below 0x80, eight at a time.
    @inline(__always)
    private static func isASCII(_ start: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var index = 0
        while index + 8 <= count {
            if UnsafeRawPointer(start + index).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 != 0 {
                return false
            }
            index += 8
        }
        while index < count {
            if start[index] >= 0x80 {
                return false
            }
            index += 1
        }
        return true
    }
}
