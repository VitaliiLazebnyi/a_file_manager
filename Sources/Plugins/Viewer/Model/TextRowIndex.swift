import AFMKernel
import Foundation

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
internal final class TextRowIndex: @unchecked Sendable {
    /// Runs the pieces of work of a parallel build, numbered from 0 to the count, and returns when all are done.
    internal typealias Spread = @Sendable (_ count: Int, _ work: @escaping @Sendable (Int) -> Void) -> Void

    /// What a build was given: a later layout may take its segments over when this is the same.
    private struct Parameters: Equatable {
        var content: Range<Int64>
        var encoding: ViewerEncoding
        var tabWidth: Int
        var segmentSize: Int64
    }

    /// One build: what is read and how, and what its threads share.
    private struct Build: Sendable {
        let input: Input
        let scanning: ScanOptions
        /// The segments, in file order.
        let bounds: [Range<Int64>]
        /// The segments of the layout before that may be taken over, by number.
        let reusable: [Int: Segment]
        /// How many segments were taken over.
        let takenOver: Locked<Int>
        let cancellation: CancellationFlag
        let progress: @Sendable () -> Void
    }

    /// Rows between two checkpoints, unless a segment thins them.
    internal static let stride = 64
    /// Checkpoints are at least this many bytes apart on average: a file of nothing but line
    /// ends would need one per 64 bytes otherwise.
    internal static let minimumCheckpointDistance = 4_096
    /// A segment holds no more checkpoints than this (3 MB): a line of many gigabytes, which is
    /// all rows of one segment, gets them farther apart instead (a lookup then cuts a few hundred
    /// kilobytes more of text, which costs less than a megabyte of checkpoints per 4 MB).
    internal static let maximumCheckpoints = 1 << 18
    /// A scan looks at the density of its checkpoints from this many on.
    internal static let thinningThreshold = 2_048

    private let lock = NSLock()
    private var state: Published
    private var parameters: Parameters?
    /// Every segment as it was scanned, by number: what a later layout can take over.
    private var scanned: [Int: Segment] = [:]
    private var previous: TextRowIndex?

    private let overview: Overview

    /// How a parallel build runs its segments: on all cores at once.
    private let spread: Spread

    // None of these waits for the index lock: they are read on the main thread.

    /// Rows known so far.
    internal var rowCount: Int { overview.rowCount }
    /// Lines known so far.
    internal var lineCount: Int { overview.lineCount }
    /// The rows of everything before this offset are known.
    internal var indexedThrough: Int64 { overview.coveredEnd }
    /// Whether the whole text is indexed.
    internal var isComplete: Bool { overview.isComplete }
    /// The first error that made a part of the file unreadable; its rows are missing.
    internal var failure: (any Error)? { overview.failed }
    /// How many segments the last build took over from the layout before (for tests).
    internal var segmentsReused: Int { overview.reusedCount }
    /// How many checkpoints the index holds (for tests, and to see what a file costs).
    internal var checkpointCount: Int { synchronized { state.checkpointCount } }

    /// An empty index of the text from `start` on; `reusing` is the index of the same bytes in
    /// another layout, if there is one.
    internal convenience init(start: Int64, reusing previous: TextRowIndex?) {
        self.init(start: start, reusing: previous) { count, work in
            DispatchQueue.concurrentPerform(iterations: count, execute: work)
        }
    }

    /// An index whose parallel builds run their segments through `spread` (tests run each on a thread of its own).
    internal init(start: Int64, reusing previous: TextRowIndex?, spread: @escaping Spread) {
        state = Published(start: start)
        overview = Overview(covered: start)
        self.previous = previous
        self.spread = spread
    }

    /// `content` cut into segments of `size` bytes, the last one shorter.
    private static func cuts(of content: Range<Int64>, size: Int64) -> [Range<Int64>] {
        var cuts: [Range<Int64>] = []
        var lower = content.lowerBound
        while lower < content.upperBound {
            let upper = min(content.upperBound, lower + size)
            cuts.append(lower..<upper)
            lower = upper
        }
        return cuts
    }

    // MARK: Building

    /// Reads the content of `input` and records its rows.
    ///
    /// Blocks until done or cancelled; call it on a background thread. With `parallel`, the
    /// segments are read on all cores at once (each through a reader of its own); otherwise one
    /// after another. `progress` is called from the working threads whenever more of the start of
    /// the file is known. `scanning.rawScan` off decodes every byte (the reference the fast scan is
    /// tested against).
    internal func build(
        _ input: Input,
        parallel: Bool,
        scanning: ScanOptions,
        cancellation: CancellationFlag,
        progress: @escaping @Sendable () -> Void
    ) {
        let unit = Int64(input.encoding.unitSize)
        let size = max(unit, Int64(scanning.segmentSize) / unit * unit)
        let now = Parameters(
            content: input.content,
            encoding: input.encoding,
            tabWidth: input.options.tabWidth,
            segmentSize: size
        )
        let reusable: [Int: Segment] = synchronized {
            parameters = now
            defer { previous = nil }
            guard let before = previous, scanning.rawScan else {
                return [:]
            }
            return before.takeOverable(for: now)
        }
        let run = Build(
            input: input,
            scanning: scanning,
            bounds: Self.cuts(of: input.content, size: size),
            reusable: reusable,
            takenOver: Locked(0),
            cancellation: cancellation,
            progress: progress
        )
        if parallel, run.bounds.count > 1 {
            spread(run.bounds.count) { number in self.scanSegment(number, lineStart: nil, run) }
        } else {
            var lineStart: Int64?
            for number in run.bounds.indices {
                scanSegment(number, lineStart: lineStart, run)
                // What this segment found out about where its last line ends is the next one's start.
                let entry = synchronized { scanned[number] }
                if let known = entry?.nextStart { lineStart = known } else if entry != nil { lineStart = nil }
            }
        }
        guard !cancellation.isCancelled else {
            return
        }
        synchronized {
            state.reused = run.takenOver.value
            state.markComplete(at: input.content.upperBound)
            mirror()
        }
        progress()
    }

    // MARK: Looking up

    /// The checkpoint to start from to reach `row`; nil when the row is not known (yet).
    internal func position(ofRow row: Int) -> Position? {
        synchronized { state.position(ofRow: row) }
    }

    /// The last checkpoint at or before a byte offset; nil when that part is not indexed yet.
    internal func position(before offset: Int64) -> Position? {
        synchronized { state.position(before: offset) }
    }

    /// The last checkpoint at or before the first row of a line (counted from 0).
    internal func position(beforeLine line: Int) -> Position? {
        synchronized { state.position(beforeLine: line) }
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
        overview.store(state.counts)
    }

    /// Reads segment `number` of a build, or takes it over from the layout before, and publishes it.
    ///
    /// `lineStart`: where the first line begins that the segments before this one do not own,
    /// when they were read in file order (nil otherwise).
    private func scanSegment(_ number: Int, lineStart: Int64?, _ run: Build) {
        // Each piece of work frees what the reads and the decoding left for the pool of the
        // thread: the threads of a parallel loop live on, and a search or an index build of
        // a big file would otherwise keep every buffer until they are idle.
        autoreleasepool {
            guard !run.cancellation.isCancelled else {
                return
            }
            if let start = lineStart, run.bounds[number].upperBound < start || start >= run.input.content.upperBound {
                // No line begins in this segment: a line of an earlier one goes through it.
                var empty = Segment()
                empty.nextStart = start
                // It is the same as the empty segment of the layout before, which would have been taken over.
                if let old = run.reusable[number], old.widest <= run.input.options.columns { run.takenOver.add(1) }
                keep(number, empty, failed: false, run)
                return
            }
            if let old = run.reusable[number], old.widest <= run.input.options.columns {
                run.takenOver.add(1)
                keep(number, old, failed: false, run)
                return
            }
            let outcome = read(number, lineStart: lineStart, run)
            guard !run.cancellation.isCancelled else {
                return
            }
            keep(number, outcome.segment, failed: outcome.failed, run)
        }
    }

    /// Scans segment `number`; an empty segment that `failed` when it could not be read.
    private func read(_ number: Int, lineStart: Int64?, _ run: Build) -> (segment: Segment, failed: Bool) {
        // The segment that comes next in file order shows what it has found so far, so a file
        // whose first line is gigabytes long is not blank until it is all read.
        let job = SegmentJob(
            segment: run.bounds[number],
            isFirst: number == 0,
            lineStart: lineStart,
            partial: { partial, covered in
                if self.publishPartial(number, partial, coveredEnd: covered) { run.progress() }
            },
            changed: {
                if !run.cancellation.isCancelled { self.recordFailure(ViewerError.fileChanged) }
            }
        )
        do {
            return (try Self.scan(run.input, job, scanning: run.scanning, cancellation: run.cancellation), false)
        } catch {
            // A read that was ended because the work is dropped is no failure of the file.
            if !run.cancellation.isCancelled { recordFailure(error) }
            return (Segment(), true)
        }
    }

    /// Keeps a segment as scanned (for a later layout) and publishes what can be published.
    private func keep(_ number: Int, _ segment: Segment, failed: Bool, _ run: Build) {
        let publishedAny = synchronized {
            scanned[number] = segment
            let published = state.finish(number, segment, end: run.bounds[number].upperBound, failed: failed)
            mirror()
            return published
        }
        if publishedAny { run.progress() }
    }

    /// The segments of this finished index that a layout built with `other` can use as they
    /// are: those of the same bytes cut the same way; none when it is not the same text.
    private func takeOverable(for other: Parameters) -> [Int: Segment] {
        synchronized {
            guard state.complete, state.firstFailure == nil, parameters == other else {
                return [:]
            }
            return scanned
        }
    }

    private func recordFailure(_ error: any Error) {
        synchronized {
            state.recordFailure(error)
            mirror()
        }
    }

    /// Shows what the segment that comes next has found so far; returns whether anything was published.
    private func publishPartial(_ number: Int, _ segment: Segment, coveredEnd covered: Int64) -> Bool {
        synchronized {
            guard state.publishPartial(number, segment, coveredEnd: covered) else {
                return false
            }
            mirror()
            return true
        }
    }

    deinit {
        // Nothing to release.
    }
}
