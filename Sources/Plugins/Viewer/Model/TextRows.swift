import AFMKernel
import Foundation

/// How text is cut into rows (spec 10 › Text).
///
/// With wrapping on, a row breaks at a word boundary after at most `columns` characters; with
/// wrapping off it is simply cut there (the specification's `UnwrapWidth`), so no row is ever
/// unbounded.
struct TextLayoutOptions: Equatable {
    var columns: Int
    var wordWrap: Bool
    var tabWidth: Int

    init(columns: Int, wordWrap: Bool, tabWidth: Int = 8) {
        self.columns = max(1, columns)
        self.wordWrap = wordWrap
        self.tabWidth = max(1, tabWidth)
    }
}

/// Cuts decoded text into rows.
///
/// CR, LF and CR+LF each end a line; a line longer than the allowed width continues in further
/// rows. It works on one piece of text after another: what is left of an unfinished row is handed
/// in again with the next piece. A value without shared state.
struct RowSplitter {
    let options: TextLayoutOptions
    /// Whether the row at the start of the next piece begins a line (and is not the
    /// continuation of a wrapped one).
    var startsLine = true

    init(_ options: TextLayoutOptions) {
        self.options = options
    }

    /// Calls `row` with the unit range of every complete row (line end included) and whether it
    /// begins a line, until `row` returns false.
    ///
    /// Returns the index of the first unit that is not part of a reported row: the start of the
    /// unfinished row to hand in again. With `final`, the text ends here and the last row is
    /// reported too.
    mutating func split(
        _ units: UnsafeBufferPointer<UInt16>,
        final: Bool,
        row: (_ start: Int, _ end: Int, _ startsLine: Bool) -> Bool
    ) -> Int {
        runUnits(units, final: final) { start, end, startsLine, _ in row(start, end, startsLine) }
    }

    /// `split`, which also tells how many columns each row takes (its line end not counted).
    mutating func splitMeasuring(
        _ units: UnsafeBufferPointer<UInt16>,
        final: Bool,
        row: (_ start: Int, _ end: Int, _ startsLine: Bool, _ width: Int) -> Bool
    ) -> Int {
        runUnits(units, final: final, row: row)
    }

    /// The same for text that is plain ASCII, cut straight from its bytes: no decoding, no
    /// table of offsets (a byte is a unit).
    mutating func splitMeasuring(
        _ bytes: UnsafeBufferPointer<UInt8>,
        final: Bool,
        row: (_ start: Int, _ end: Int, _ startsLine: Bool, _ width: Int) -> Bool
    ) -> Int {
        runBytes(bytes, final: final, row: row)
    }

    // The same code twice, for 16-bit units and for bytes: a generic one is slow where nothing is optimised.
    private mutating func runUnits(
        _ units: UnsafeBufferPointer<UInt16>,
        final: Bool,
        row: (Int, Int, Bool, Int) -> Bool
    ) -> Int {
        let count = units.count
        let columns = options.columns
        let tabWidth = options.tabWidth
        // Spaces may hang over the edge instead of opening a row of their own, within reason.
        let hangLimit = columns * 2
        var rowStart = 0
        var index = 0
        var column = 0
        var lastBreak = -1
        // Whether the unit before was a zero width joiner: what it joins stays with it.
        var joined = false
        while index < count {
            let unit = units[index]
            if unit == 0x0A || unit == 0x0D {
                var end = index + 1
                if unit == 0x0D {
                    if end < count {
                        if units[end] == 0x0A { end += 1 }
                    } else if !final {
                        // Whether a LF follows is not known yet.
                        break
                    }
                }
                let goOn = row(rowStart, end, startsLine, column)
                startsLine = true
                rowStart = end
                index = end
                column = 0
                lastBreak = -1
                joined = false
                if !goOn {
                    return rowStart
                }
                continue
            }
            let isSpace = unit == 0x20 || unit == 0x09
            // A mark that combines with the character before, the second half of a surrogate
            // pair, and what a joiner joins take no column: a row is never cut in front of them.
            let isSecondHalf = (0xDC00...0xDFFF).contains(unit)
            let takesNone = isSecondHalf || joined || Self.takesNoColumn(unit)
            let width =
                unit == 0x09
                ? tabWidth - column % tabWidth
                : takesNone
                    ? 0
                    : unit >= 0x1100 && EastAsianWidth.isWide(units, at: index) ? 2 : 1
            joined = unit == 0x200D
            // A run of marks with nothing to hold them is cut after a while: a row is never unbounded.
            let endless = takesNone && !isSecondHalf && index - rowStart >= columns * 4 + 16
            // A unit without width never breaks the row by itself: after a wide character in a row of one column the
            // row is already past its width, and the second half of the character or its mark belongs to it.
            if (width > 0 && column + width > columns) || endless, index > rowStart, !(isSpace && column < hangLimit) {
                let cut = options.wordWrap && lastBreak > rowStart ? lastBreak : index
                let goOn = row(rowStart, cut, startsLine, column)
                startsLine = false
                rowStart = cut
                index = cut
                column = 0
                lastBreak = -1
                joined = false
                if !goOn {
                    return rowStart
                }
                continue
            }
            column += width
            index += 1
            if isSpace { lastBreak = index }
        }
        if final, rowStart < count, index == count {
            _ = row(rowStart, count, startsLine, column)
            startsLine = false
            return count
        }
        return rowStart
    }

    /// Units that add no column: combining marks, variation selectors and the zero width spaces
    /// and joiners.
    @inline(__always)
    private static func takesNoColumn(_ unit: UInt16) -> Bool {
        guard unit >= 0x0300 else {
            return false
        }
        switch unit {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x200B...0x200F, 0x20D0...0x20FF, 0x3099...0x309A,
            0xFE00...0xFE0F, 0xFE20...0xFE2F:
            return true

        default:
            return false
        }
    }

    private mutating func runBytes(
        _ units: UnsafeBufferPointer<UInt8>,
        final: Bool,
        row: (Int, Int, Bool, Int) -> Bool
    ) -> Int {
        let count = units.count
        let columns = options.columns
        let tabWidth = options.tabWidth
        // Spaces may hang over the edge instead of opening a row of their own, within reason.
        let hangLimit = columns * 2
        var rowStart = 0
        var index = 0
        var column = 0
        var lastBreak = -1
        while index < count {
            let unit = units[index]
            if unit == 0x0A || unit == 0x0D {
                var end = index + 1
                if unit == 0x0D {
                    if end < count {
                        if units[end] == 0x0A { end += 1 }
                    } else if !final {
                        // Whether a LF follows is not known yet.
                        break
                    }
                }
                let goOn = row(rowStart, end, startsLine, column)
                startsLine = true
                rowStart = end
                index = end
                column = 0
                lastBreak = -1
                if !goOn {
                    return rowStart
                }
                continue
            }
            let isSpace = unit == 0x20 || unit == 0x09
            let width = unit == 0x09 ? tabWidth - column % tabWidth : 1
            if column + width > columns, index > rowStart, !(isSpace && column < hangLimit) {
                let cut = options.wordWrap && lastBreak > rowStart ? lastBreak : index
                let goOn = row(rowStart, cut, startsLine, column)
                startsLine = false
                rowStart = cut
                index = cut
                column = 0
                lastBreak = -1
                if !goOn {
                    return rowStart
                }
                continue
            }
            column += width
            index += 1
            if isSpace { lastBreak = index }
        }
        if final, rowStart < count, index == count {
            _ = row(rowStart, count, startsLine, column)
            startsLine = false
            return count
        }
        return rowStart
    }
}

/// Where the rows of a text are in the file.
///
/// Holding the start of every row of a file of many gigabytes would cost more memory than showing
/// it is worth, so only every 64th row is kept (and no more than one per 4 KB of a file of very
/// short rows); the rows in between are found again by cutting the text from there.
///
/// The index is built in the background (`build`), big files in segments on all cores at once.
/// Segments are published in file order as they finish, so the start of the file can be shown
/// while the rest is still being read. A new layout of the same text (another width) takes over
/// the segments of the one before wherever every line took one row and still does
/// (`Segment.widest`), and reads only the others. All members are safe to use from any thread:
/// the state is guarded by `lock`, and `overview` has a lock of its own.
final class TextRowIndex: @unchecked Sendable {
    /// Runs the pieces of work of a parallel build, numbered from 0 to the count, and returns when all are done.
    internal typealias Spread = @Sendable (_ count: Int, _ work: @escaping @Sendable (Int) -> Void) -> Void

    static let stride = 64
    /// Checkpoints are at least this many bytes apart on average: a file of nothing but line
    /// ends would need one per 64 bytes otherwise.
    static let minimumCheckpointDistance = 4_096
    /// A segment holds no more checkpoints than this (3 MB): a line of many gigabytes, which is
    /// all rows of one segment, gets them farther apart instead (a lookup then cuts a few hundred
    /// kilobytes more of text, which costs less than a megabyte of checkpoints per 4 MB).
    static let maximumCheckpoints = 1 << 18
    /// A scan looks at the density of its checkpoints from this many on.
    static let thinningThreshold = 2_048

    struct Checkpoint {
        var offset: Int64
        /// Lines of this segment that begin before this row.
        var linesBefore: Int
        var startsLine: Bool
    }

    /// Checkpoints in 12 bytes each instead of 24: the offset with the flag in its lowest bit,
    /// and the line count relative to the segment, which a segment cannot overflow.
    ///
    /// They are kept in chunks, so a copy of the list that was published (the partial state of a
    /// segment) shares all full chunks and appending to the original copies the outer array and one
    /// chunk at most, whatever the length of the list.
    struct CheckpointList: RandomAccessCollection {
        private static let chunkShift = 12
        private static let chunkSize = 1 << chunkShift
        private var marks: [[Int64]] = []
        private var lines: [[UInt32]] = []
        private(set) var count = 0

        var startIndex: Int { 0 }
        var endIndex: Int { count }

        mutating func append(_ checkpoint: Checkpoint) {
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

        subscript(index: Int) -> Checkpoint {
            let chunk = index >> Self.chunkShift
            let inChunk = index & (Self.chunkSize - 1)
            let mark = marks[chunk][inChunk]
            return Checkpoint(offset: mark >> 1, linesBefore: Int(lines[chunk][inChunk]), startsLine: mark & 1 == 1)
        }

        /// Every `step`th checkpoint, the first included.
        func thinned(every step: Int) -> Self {
            var result = Self()
            for index in Swift.stride(from: 0, to: count, by: Swift.max(1, step)) { result.append(self[index]) }
            return result
        }
    }

    struct Segment {
        var firstRow = 0
        var firstLine = 0
        var rowCount = 0
        var lineCount = 0
        var checkpoints = CheckpointList()
        /// Rows between two checkpoints: 64, or a multiple of it where rows are very short.
        var stride = TextRowIndex.stride
        /// The widest line of the segment in columns (an upper bound), or `Int.max` when a line
        /// takes more than one row: with a width that holds the widest line, every line takes
        /// one row and the segment is the same as it is here.
        var widest = 0
        /// Whether the segment that follows in the file is missing (it could not be read), so
        /// the rows after the last one of this segment are not those of the next row number.
        var endsAtGap = false
        /// Where the first line begins that this segment does not own: the line start behind its
        /// last row, or the end of the text. nil when the scan did not get there.
        ///
        /// A sequential build passes it on, so the segments in between (a line longer than they
        /// are) are not read again only to find that no line begins in them.
        var nextStart: Int64?

        /// Keeps fewer checkpoints when the segment has too many for the bytes its rows cover:
        /// `bytes` is that span (from the first checkpoint to the end of the last row, which is
        /// far more than the nominal size of the segment when a line is longer than a segment).
        ///
        /// On average they stay `minimumCheckpointDistance` bytes apart, and there are never more
        /// than `maximumCheckpoints`.
        mutating func thin(spanning bytes: Int64) {
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
    struct Position {
        /// The byte offset of the checkpoint row.
        var offset: Int64
        /// The number of the checkpoint row.
        var row: Int
        var startsLine: Bool
        /// Lines that begin before the checkpoint row, in the whole text.
        var linesBefore: Int
        /// The row the text must not be walked past from here (a segment that could not be read
        /// follows); nil when the rows go on.
        var endRow: Int?
    }

    /// What a build was given: a later layout may take its segments over when this is the same.
    private struct Parameters: Equatable {
        var content: Range<Int64>
        var encoding: ViewerEncoding
        var tabWidth: Int
        var segmentSize: Int64
    }

    private let lock = NSLock()
    private var finished: [Int: (segment: Segment, end: Int64, failed: Bool)] = [:]
    private var published: [Segment] = []
    private var nextToPublish = 0
    private var rows = 0, lines = 0
    private var coveredEnd: Int64
    private var complete = false
    /// Whether the last published segment is the unfinished frontier one, to be replaced by
    /// its next state.
    private var hasPartial = false
    private var firstFailure: any Error?
    private var parameters: Parameters?
    /// Every segment as it was scanned, by number: what a later layout can take over.
    private var scanned: [Int: Segment] = [:]
    private var previous: TextRowIndex?
    private var reused = 0

    /// What the main thread asks for all the time (the scroller, the status line): a copy kept
    /// behind a lock of its own that is held for a few stores only, so the view never waits for a
    /// thread that is publishing a segment, or that has been preempted holding the index lock.
    ///
    /// All state is guarded by `guarded`.
    private final class Overview: @unchecked Sendable {
        private let guarded = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        private var rows = 0, lines = 0, covered: Int64 = 0, complete = false, failure: any Error?, reused = 0

        init(covered: Int64) {
            guarded.initialize(to: os_unfair_lock())
            self.covered = covered
        }

        deinit {
            guarded.deallocate()
        }

        func store(rows: Int, lines: Int, covered: Int64, complete: Bool, failure: any Error?, reused: Int) {
            os_unfair_lock_lock(guarded)
            self.rows = rows
            self.lines = lines
            self.covered = covered
            self.complete = complete
            self.failure = failure
            self.reused = reused
            os_unfair_lock_unlock(guarded)
        }

        func read<T>(_ value: (Overview) -> T) -> T {
            os_unfair_lock_lock(guarded)
            defer { os_unfair_lock_unlock(guarded) }
            return value(self)
        }

        var rowCount: Int { read { $0.rows } }
        var lineCount: Int { read { $0.lines } }
        var coveredEnd: Int64 { read { $0.covered } }
        var isComplete: Bool { read { $0.complete } }
        var failed: any Error? { read { $0.failure } }
        var reusedCount: Int { read { $0.reused } }
    }

    private let overview: Overview

    /// How a parallel build runs its segments: on all cores at once.
    private let spread: Spread

    /// `reusing` is the index of the same bytes in another layout, if there is one.
    internal convenience init(start: Int64 = 0, reusing previous: TextRowIndex? = nil) {
        self.init(start: start, reusing: previous) { count, work in
            DispatchQueue.concurrentPerform(iterations: count, execute: work)
        }
    }

    /// An index whose parallel builds run their segments through `spread` (tests run each on a thread of its own).
    internal init(start: Int64, reusing previous: TextRowIndex?, spread: @escaping Spread) {
        coveredEnd = start
        overview = Overview(covered: start)
        self.previous = previous
        self.spread = spread
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Copies the counters to what the main thread reads.
    ///
    /// Called with the lock held, after any of them changed.
    private func mirror() {
        overview.store(
            rows: rows,
            lines: lines,
            covered: coveredEnd,
            complete: complete,
            failure: firstFailure,
            reused: reused
        )
    }

    // None of these waits for the index lock: they are read on the main thread.

    /// Rows known so far.
    var rowCount: Int { overview.rowCount }
    /// Lines known so far.
    var lineCount: Int { overview.lineCount }
    /// The rows of everything before this offset are known.
    var indexedThrough: Int64 { overview.coveredEnd }
    var isComplete: Bool { overview.isComplete }
    /// The first error that made a part of the file unreadable; its rows are missing.
    var failure: any Error? { overview.failed }
    /// How many segments the last build took over from the layout before (for tests).
    var segmentsReused: Int { overview.reusedCount }
    /// How many checkpoints the index holds (for tests, and to see what a file costs).
    var checkpointCount: Int { synchronized { published.reduce(0) { $0 + $1.checkpoints.count } } }

    // MARK: Building

    /// Reads `content` of `source` and records its rows.
    ///
    /// Blocks until done or cancelled; call it on a background thread. With `parallel`, the
    /// segments are read on all cores at once (each through a reader of its own); otherwise one
    /// after another. `progress` is called from the working threads whenever more of the start of
    /// the file is known. `rawScan` off decodes every byte (the reference the fast scan is tested
    /// against).
    func build(
        source: any ByteSource,
        content: Range<Int64>,
        encoding: ViewerEncoding,
        options: TextLayoutOptions,
        parallel: Bool,
        segmentSize: Int = 4 << 20,
        chunkSize: Int = 1 << 20,
        rawScan: Bool = true,
        cancellation: CancellationFlag,
        progress: @escaping @Sendable () -> Void
    ) {
        let unit = Int64(encoding.unitSize)
        let size = max(unit, Int64(segmentSize) / unit * unit)
        let now = Parameters(content: content, encoding: encoding, tabWidth: options.tabWidth, segmentSize: size)
        let reusable: [Int: Segment]? = synchronized {
            parameters = now
            defer { previous = nil }
            guard let before = previous, rawScan else {
                return nil
            }
            return before.takeOverable(for: now)
        }
        var cuts: [Range<Int64>] = []
        var lower = content.lowerBound
        while lower < content.upperBound {
            let upper = min(content.upperBound, lower + size)
            cuts.append(lower..<upper)
            lower = upper
        }
        let bounds = cuts
        let reused = Locked(0)
        /// `lineStart`: where the first line begins that the segments before this one do not own,
        /// when they were read in file order (nil otherwise).
        @Sendable func work(_ number: Int, lineStart: Int64? = nil) {
            // Each piece of work frees what the reads and the decoding left for the pool of the
            // thread: the threads of a parallel loop live on, and a search or an index build of
            // a big file would otherwise keep every buffer until they are idle.
            autoreleasepool {
                guard !cancellation.isCancelled else {
                    return
                }
                if let start = lineStart, bounds[number].upperBound < start || start >= content.upperBound {
                    // No line begins in this segment: a line of an earlier one goes through it.
                    var empty = Segment()
                    empty.nextStart = start
                    // It is the same as the empty segment of the layout before, which would have been taken over.
                    if let old = reusable?[number], old.widest <= options.columns { reused.add(1) }
                    synchronized { scanned[number] = empty }
                    if finish(number, empty, end: bounds[number].upperBound, failed: false) { progress() }
                    return
                }
                if let old = reusable?[number], old.widest <= options.columns {
                    reused.add(1)
                    synchronized { scanned[number] = old }
                    if finish(number, old, end: bounds[number].upperBound, failed: false) { progress() }
                    return
                }
                var segment = Segment()
                var failed = false
                do {
                    // The segment that comes next in file order shows what it has found so far, so a
                    // file whose first line is gigabytes long is not blank until it is all read.
                    segment = try Self.scan(
                        source: source,
                        content: content,
                        segment: bounds[number],
                        isFirst: number == 0,
                        encoding: encoding,
                        options: options,
                        chunkSize: chunkSize,
                        rawScan: rawScan,
                        cancellation: cancellation,
                        from: lineStart,
                        partial: { partial, covered in
                            if self.publishPartial(number, partial, coveredEnd: covered) { progress() }
                        },
                        changed: {
                            if !cancellation.isCancelled { self.recordFailure(ViewerError.fileChanged) }
                        }
                    )
                } catch {
                    // A read that was ended because the work is dropped is no failure of the file.
                    if !cancellation.isCancelled { recordFailure(error) }
                    failed = true
                }
                guard !cancellation.isCancelled else {
                    return
                }
                synchronized { scanned[number] = segment }
                if finish(number, segment, end: bounds[number].upperBound, failed: failed) { progress() }
            }
        }
        if parallel, bounds.count > 1 {
            spread(bounds.count) { work($0) }
        } else {
            var lineStart: Int64?
            for number in bounds.indices {
                work(number, lineStart: lineStart)
                // What this segment found out about where its last line ends is the next one's start.
                let entry = synchronized { scanned[number] }
                if let known = entry?.nextStart { lineStart = known } else if entry != nil { lineStart = nil }
            }
        }
        guard !cancellation.isCancelled else {
            return
        }
        synchronized {
            self.reused = reused.value
            complete = true
            coveredEnd = content.upperBound
            mirror()
        }
        progress()
    }

    /// The segments of this finished index that a layout built with `other` can use as they
    /// are: those of the same bytes cut the same way; nil when it is not the same text.
    private func takeOverable(for other: Parameters) -> [Int: Segment]? {
        synchronized {
            guard complete, firstFailure == nil, parameters == other else {
                return nil
            }
            return scanned
        }
    }

    /// A number shared by the threads of a build.
    ///
    /// Guarded by `lock`.
    private final class Locked<Value: AdditiveArithmetic>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ value: Value) { stored = value }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func add(_ amount: Value) {
            lock.lock()
            stored += amount
            lock.unlock()
        }
    }

    private func recordFailure(_ error: any Error) {
        synchronized {
            if firstFailure == nil { firstFailure = error }
            mirror()
        }
    }

    /// Shows what the segment that comes next has found so far, in place of its earlier state (`scan` hands on
    /// only a state that has rows).
    ///
    /// Returns whether anything was published.
    private func publishPartial(_ number: Int, _ segment: Segment, coveredEnd covered: Int64) -> Bool {
        synchronized {
            guard number == nextToPublish else {
                return false
            }
            dropPartial()
            var next = segment
            next.firstRow = rows
            next.firstLine = lines
            rows += next.rowCount
            lines += next.lineCount
            published.append(next)
            hasPartial = true
            coveredEnd = max(coveredEnd, covered)
            mirror()
            return true
        }
    }

    private func dropPartial() {
        guard hasPartial, let last = published.popLast() else {
            return
        }
        rows -= last.rowCount
        lines -= last.lineCount
        hasPartial = false
    }

    /// Takes a finished segment and publishes every segment that now follows the published
    /// ones without a gap.
    ///
    /// Returns whether anything was published.
    private func finish(_ number: Int, _ segment: Segment, end: Int64, failed: Bool) -> Bool {
        synchronized {
            finished[number] = (segment, end, failed)
            if number == nextToPublish { dropPartial() }
            var publishedAny = false
            while let (segment, nextEnd, wasFailure) = finished[nextToPublish] {
                var next = segment
                finished[nextToPublish] = nil
                nextToPublish += 1
                publishedAny = true
                // Every row that begins before the end of a segment belongs to a line that
                // begins in it or before it, so it is known now.
                coveredEnd = max(coveredEnd, nextEnd)
                // The rows after those of the segment before are not the next in the file.
                if wasFailure, !published.isEmpty { published[published.count - 1].endsAtGap = true }
                guard next.rowCount > 0 else { continue }
                next.firstRow = rows
                next.firstLine = lines
                rows += next.rowCount
                lines += next.lineCount
                published.append(next)
            }
            mirror()
            return publishedAny
        }
    }

    /// How much of a segment is read between two partial results.
    private static let partialInterval = 4 << 20

    /// What a scan has recorded so far and what it does with the next row.
    private struct SegmentScan {
        let segment: Range<Int64>
        let unit: Int64
        var result = Segment()
        var skipping: Bool
        var stopped = false
        /// Where the last row recorded begins.
        var lastOffset: Int64 = 0

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
            if result.rowCount % result.stride == 0 {
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

        /// Records `count` empty lines of one byte each (a run of LF), the first at `offset`:
        /// the same as `take` for each, without the cost of it.
        mutating func takeEmptyLines(offset: Int64, count: Int) {
            var count = count
            let room = segment.upperBound - offset
            if room < Int64(count - 1) {
                count = max(0, Int(room) + 1)
                stopped = true
                // The first line that is not this segment's: the one after those taken. When
                // the run begins past the segment's end (the line before it reached over the
                // end) none is taken and that line is the run's first; "one past the end" was
                // then a place in the middle of the line before, and the next segment, told
                // that a line began there, made a row of its own out of that line's tail.
                result.nextStart = offset + Int64(count)
            }
            guard count > 0 else {
                return
            }
            skipping = false
            lastOffset = offset + Int64(count)
            let first = result.rowCount
            var row = (first + result.stride - 1) / result.stride * result.stride
            while row < first + count {
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
            result.lineCount += count
            result.rowCount += count
        }
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

    /// 0x80 in every byte of `word` that equals `byte` (and nothing in the others).
    @inline(__always)
    private static func matches(in word: UInt64, _ byte: UInt64) -> UInt64 {
        let x = word ^ (byte &* 0x0101_0101_0101_0101)
        return ~(((x & 0x7F7F_7F7F_7F7F_7F7F) &+ 0x7F7F_7F7F_7F7F_7F7F) | x | 0x7F7F_7F7F_7F7F_7F7F)
    }

    /// The rows of one segment: those of the lines that begin inside it.
    ///
    /// A line belongs to the segment its first byte is in (`lower < start <= upper`; the very first
    /// line to the first segment), wherever it ends, so the segments need nothing from each other:
    /// each looks for the first line start behind its lower bound and reads on past its upper bound
    /// to the end of its last line. `partial` is handed what is found so far, every few megabytes.
    static func scan(
        source: any ByteSource,
        content: Range<Int64>,
        segment: Range<Int64>,
        isFirst: Bool,
        encoding: ViewerEncoding,
        options: TextLayoutOptions,
        chunkSize: Int,
        rawScan: Bool = true,
        cancellation: CancellationFlag,
        from lineStart: Int64? = nil,
        partial: ((Segment, Int64) -> Void)? = nil,
        changed: (() -> Void)? = nil
    ) throws -> Segment {
        let unit = encoding.unitSize
        // With `lineStart`, a line is known to begin there (inside the segment): nothing before it is read.
        let startsAtLine = isFirst || lineStart != nil
        var state = SegmentScan(segment: segment, unit: Int64(unit), skipping: !startsAtLine)
        var splitter = RowSplitter(options)
        splitter.startsLine = startsAtLine
        var bytes: [UInt8] = []
        var base = lineStart ?? segment.lowerBound
        var readPosition = base
        var text = DecodedText()
        var sincePartial = 0
        let bigEndian = encoding.kind == .utf16BE
        /// Cuts `buffer[range]` into rows and records them; returns the bytes used. Plain ASCII
        /// is cut from its bytes, anything else is decoded first.
        func cut(_ buffer: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, final: Bool) -> Int {
            let origin = base + Int64(range.lowerBound)
            if rawScan, unit == 1, let start = buffer.baseAddress, isASCII(start + range.lowerBound, range.count) {
                return splitter.splitMeasuring(UnsafeBufferPointer(rebasing: buffer[range]), final: final) {
                    first,
                    _,
                    startsLine,
                    width in
                    state.take(offset: origin + Int64(first), startsLine: startsLine, width: width)
                }
            }
            let used = encoding.decode(UnsafeBufferPointer(rebasing: buffer[range]), final: final, into: &text)
            let consumedUnits = text.units.withUnsafeBufferPointer { units in
                splitter.splitMeasuring(units, final: final) { first, _, startsLine, width in
                    state.take(offset: origin + Int64(text.offsets[first]), startsLine: startsLine, width: width)
                }
            }
            return consumedUnits == text.units.count ? used : Int(text.offsets[consumedUnits])
        }
        while !cancellation.isCancelled {
            let wanted = Int(min(Int64(max(chunkSize, 16)), content.upperBound - readPosition))
            let chunk = try source.read(at: readPosition, count: wanted, cancellation: cancellation)
            readPosition += Int64(chunk.count)
            bytes.append(contentsOf: chunk)
            // A read that comes back short inside the file means the file is shorter than it
            // was: what is found stays, and the change is reported.
            let ended = chunk.count < wanted
            if ended { changed?() }
            let atEnd = ended || readPosition >= content.upperBound
            let consumed = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard rawScan else {
                    return cut(buffer, 0..<buffer.count, final: atEnd)
                }
                // Most lines are short and plain: they are one row each, and a row is all that
                // is wanted of them, so only the line ends are looked for in the raw bytes.
                // Decoding is left to the lines that may need more than one row (longer than a
                // row, or with tabs) and to the ends of unfinished lines.
                let count = buffer.count
                let columns = options.columns
                guard !buffer.isEmpty, let start = buffer.baseAddress else {
                    return 0
                }
                @inline(__always) func load(_ at: Int) -> UInt64 {
                    UnsafeRawPointer(start + at).loadUnaligned(as: UInt64.self)
                }
                /// The first position at or after `from` of a unit that is `byte` (a line end).
                func find(_ byte: UInt8, from: Int) -> Int {
                    var position = from
                    while position < count, let found = memchr(start + position, Int32(byte), count - position) {
                        let at = start.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        if unit == 1 {
                            return at
                        }
                        // A 16-bit unit: the byte is its low half and the other one is zero.
                        let first = bigEndian ? at - 1 : at
                        if first >= from, first % 2 == 0, first + 1 < count, buffer[bigEndian ? first : first + 1] == 0
                        {
                            return first
                        }
                        position = at + 1
                    }
                    return count
                }
                func isUnit(_ at: Int, _ byte: UInt8) -> Bool {
                    unit == 1
                        ? buffer[at] == byte
                        : bigEndian
                            ? buffer[at] == 0 && buffer[at + 1] == byte : buffer[at] == byte && buffer[at + 1] == 0
                }
                var position = 0
                var nextLF = -1
                var nextCR = -1
                while position < count, !state.stopped {
                    if unit == 1, splitter.startsLine, buffer[position] == 0x0A {
                        // A run of empty lines costs no more than looking at its bytes.
                        var run = position + 1
                        while run + 8 <= count, load(run) == 0x0A0A_0A0A_0A0A_0A0A { run += 8 }
                        while run < count, buffer[run] == 0x0A { run += 1 }
                        if run - position >= 4 {
                            state.takeEmptyLines(offset: base + Int64(position), count: run - position)
                            position = run
                            continue
                        }
                    }
                    var searchFrom = position
                    var lineEnd = count
                    /// Whether a line that ends within the 8 bytes looked at has no tab.
                    var plainShort = false
                    if unit == 1, position + 8 <= count {
                        // Short lines are the most; their ends are found without a call.
                        let word = load(position)
                        let ends = Self.matches(in: word, 0x0A) | Self.matches(in: word, 0x0D)
                        if ends != 0 {
                            let before = ends.trailingZeroBitCount >> 3
                            lineEnd = position + before
                            plainShort = Self.matches(in: word, 0x09) & (1 << UInt64(before * 8) &- 1) == 0
                        } else {
                            searchFrom = position + 8
                        }
                    }
                    if lineEnd == count {
                        if nextLF < searchFrom { nextLF = find(0x0A, from: searchFrom) }
                        if nextCR < searchFrom { nextCR = find(0x0D, from: searchFrom) }
                        lineEnd = min(nextLF, nextCR)
                    }
                    guard lineEnd < count else {
                        if atEnd {
                            _ = cut(buffer, position..<count, final: true)
                            position = count
                        } else if !(splitter.startsLine && (count - position) / unit <= columns) {
                            position += cut(buffer, position..<count, final: false)
                        }
                        break
                    }
                    var end = lineEnd + unit
                    if isUnit(lineEnd, 0x0D) {
                        // Whether a LF follows is not known yet.
                        if end + unit > count {
                            if !atEnd { break }
                        } else if isUnit(end, 0x0A) {
                            end += unit
                        }
                    }
                    let length = lineEnd - position
                    // The width is bounded by the bytes for 8-bit units (a wide character takes 2 columns and
                    // at least 2 bytes, except in UTF-8 where it takes 3), but a 16-bit unit may be 2 columns wide.
                    let widthBound = unit == 2 ? length : length / unit
                    if splitter.startsLine, widthBound <= columns,
                        plainShort || length == 0 || memchr(start + position, 0x09, length) == nil
                    {
                        _ = state.take(offset: base + Int64(position), startsLine: true, width: widthBound)
                    } else {
                        _ = cut(buffer, position..<end, final: true)
                    }
                    position = end
                }
                return position
            }
            if state.stopped { break }
            if atEnd {
                if !state.skipping { state.result.nextStart = content.upperBound }
                break
            }
            bytes.removeFirst(consumed)
            base += Int64(consumed)
            if state.skipping, base > segment.upperBound + state.unit { break }
            sincePartial += chunk.count
            if let partial, !state.skipping, state.result.rowCount > 0, sincePartial >= partialInterval {
                sincePartial = 0
                partial(state.result, base)
            }
        }
        // The bytes the rows cover: the segment, or more where a line goes on past its end.
        if let first = state.result.checkpoints.first {
            state.result.thin(spanning: max(segment.upperBound - segment.lowerBound, state.lastOffset - first.offset))
        }
        return state.result
    }

    // MARK: Looking up

    /// The checkpoint to start from to reach `row`; nil when the row is not known (yet).
    func position(ofRow row: Int) -> Position? {
        synchronized {
            guard row >= 0, row < rows else {
                return nil
            }
            // The first segment begins with row 0.
            let segment = published[Self.prefixCount(in: published) { $0.firstRow <= row } - 1]
            return position(segment, min((row - segment.firstRow) / segment.stride, segment.checkpoints.count - 1))
        }
    }

    /// The last checkpoint at or before a byte offset; nil when that part is not indexed yet.
    func position(before offset: Int64) -> Position? {
        synchronized {
            // None when the offset is before the first segment that could be read.
            let segments = Self.prefixCount(in: published) { $0.checkpoints[0].offset <= offset }
            guard offset < coveredEnd || complete, segments > 0 else {
                return nil
            }
            let segment = published[segments - 1]
            // Its first checkpoint is at or before the offset.
            return position(segment, Self.prefixCount(in: segment.checkpoints) { $0.offset <= offset } - 1)
        }
    }

    /// The last checkpoint at or before the first row of a line (counted from 0).
    func position(beforeLine line: Int) -> Position? {
        synchronized {
            guard line >= 0, line < lines else {
                return nil
            }
            // The first segment begins with line 0, and the first checkpoint of a segment with its first line.
            let segment = published[Self.prefixCount(in: published) { $0.firstLine <= line } - 1]
            return position(
                segment,
                Self.prefixCount(in: segment.checkpoints) { $0.linesBefore <= line - segment.firstLine } - 1
            )
        }
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
}

/// The East Asian Width property (Unicode 15.1, UAX #11): characters of class W (wide) and F
/// (fullwidth) take two columns of a monospaced text; the others, one.
enum EastAsianWidth {
    /// Ranges of wide and fullwidth characters, sorted: first, last.
    private static let wide: [(UInt32, UInt32)] = [
        (0x1100, 0x115F), (0x231A, 0x231B), (0x2329, 0x232A), (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3),
        (0x25FD, 0x25FE), (0x2614, 0x2615), (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x2693), (0x26A1, 0x26A1),
        (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5), (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA),
        (0x26F2, 0x26F3), (0x26F5, 0x26F5), (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705), (0x270A, 0x270B),
        (0x2728, 0x2728), (0x274C, 0x274C), (0x274E, 0x274E), (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797),
        (0x27B0, 0x27B0), (0x27BF, 0x27BF), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55),
        (0x2E80, 0x2E99), (0x2E9B, 0x2EF3), (0x2F00, 0x2FD5), (0x2FF0, 0x2FFF), (0x3000, 0x303E), (0x3041, 0x3096),
        (0x3099, 0x30FF), (0x3105, 0x312F), (0x3131, 0x318E), (0x3190, 0x31E3), (0x31EF, 0x321E), (0x3220, 0x3247),
        (0x3250, 0x4DBF), (0x4E00, 0xA48C), (0xA490, 0xA4C6), (0xA960, 0xA97C), (0xAC00, 0xD7A3), (0xF900, 0xFAFF),
        (0xFE10, 0xFE19), (0xFE30, 0xFE52), (0xFE54, 0xFE66), (0xFE68, 0xFE6B), (0xFF01, 0xFF60), (0xFFE0, 0xFFE6),
        (0x16FE0, 0x16FE4), (0x16FF0, 0x16FF1), (0x17000, 0x187F7), (0x18800, 0x18CD5), (0x18D00, 0x18D08),
        (0x1AFF0, 0x1AFF3), (0x1AFF5, 0x1AFFB), (0x1AFFD, 0x1AFFE), (0x1B000, 0x1B122), (0x1B132, 0x1B132),
        (0x1B150, 0x1B152), (0x1B155, 0x1B155), (0x1B164, 0x1B167), (0x1B170, 0x1B2FB), (0x1F004, 0x1F004),
        (0x1F0CF, 0x1F0CF), (0x1F18E, 0x1F18E), (0x1F191, 0x1F19A), (0x1F200, 0x1F202), (0x1F210, 0x1F23B),
        (0x1F240, 0x1F248), (0x1F250, 0x1F251), (0x1F260, 0x1F265), (0x1F300, 0x1F320), (0x1F32D, 0x1F335),
        (0x1F337, 0x1F37C), (0x1F37E, 0x1F393), (0x1F3A0, 0x1F3CA), (0x1F3CF, 0x1F3D3), (0x1F3E0, 0x1F3F0),
        (0x1F3F4, 0x1F3F4), (0x1F3F8, 0x1F43E), (0x1F440, 0x1F440), (0x1F442, 0x1F4FC), (0x1F4FF, 0x1F53D),
        (0x1F54B, 0x1F54E), (0x1F550, 0x1F567), (0x1F57A, 0x1F57A), (0x1F595, 0x1F596), (0x1F5A4, 0x1F5A4),
        (0x1F5FB, 0x1F64F), (0x1F680, 0x1F6C5), (0x1F6CC, 0x1F6CC), (0x1F6D0, 0x1F6D2), (0x1F6D5, 0x1F6D7),
        (0x1F6DC, 0x1F6DF), (0x1F6EB, 0x1F6EC), (0x1F6F4, 0x1F6FC), (0x1F7E0, 0x1F7EB), (0x1F7F0, 0x1F7F0),
        (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945), (0x1F947, 0x1F9FF), (0x1FA70, 0x1FA7C), (0x1FA80, 0x1FA88),
        (0x1FA90, 0x1FABD), (0x1FABF, 0x1FAC5), (0x1FACE, 0x1FADB), (0x1FAE0, 0x1FAE8), (0x1FAF0, 0x1FAF8),
        (0x20000, 0x2FFFD), (0x30000, 0x3FFFD)
    ]

    /// Whether the code point takes two columns.
    static func isWide(_ scalar: UInt32) -> Bool {
        guard scalar >= 0x1100 else {
            return false
        }
        var low = 0
        var high = wide.count
        while low < high {
            let middle = (low + high) / 2
            if wide[middle].1 < scalar { low = middle + 1 } else { high = middle }
        }
        return low < wide.count && wide[low].0 <= scalar
    }

    /// Whether the character that begins at `index` of the UTF-16 units takes two columns (a
    /// surrogate pair is looked at as the one character it is).
    @inline(__always)
    static func isWide(_ units: UnsafeBufferPointer<UInt16>, at index: Int) -> Bool {
        let unit = units[index]
        if (0xD800...0xDBFF).contains(unit) {
            guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                return false
            }
            return isWide(0x10000 + (UInt32(unit) - 0xD800) << 10 + (UInt32(units[index + 1]) - 0xDC00))
        }
        return isWide(UInt32(unit))
    }
}
