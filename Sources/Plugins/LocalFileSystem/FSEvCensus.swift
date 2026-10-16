import Foundation

/// The streams this process holds. The system gives one process 512 of them and refuses
/// the next one without a word (`FSEventStreamStart` answers false and nothing is
/// logged), so a program that lets streams pile up ends with folders nobody watches.
/// Counted here so that this can be seen: by tests, and in a run with
/// `AFM_WATCHER_CENSUS` set, which prints the figures when the process ends.
internal enum FSEvCensus {
    /// Streams that run now, the most that ran at one time, and how often a stream could
    /// not be had (the system refused it, or the process had too few descriptors to spare).
    internal struct Figures: Sendable {
        /// Streams that run now.
        internal var live = 0
        /// The most that ran at one time.
        internal var peak = 0
        /// How often a stream could not be had.
        internal var refused = 0
    }

    private static let lock = NSLock()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var counts = Figures()
    private static let printsAtExit: Void = {
        guard getenv("AFM_WATCHER_CENSUS") != nil else {
            return
        }
        atexit {
            let current = Self.figures
            fputs(
                "AFM_WATCHER_CENSUS live=\(current.live) peak=\(current.peak) refused=\(current.refused)\n",
                stderr
            )
        }
    }()

    /// The figures as they are now.
    internal static var figures: Figures {
        lock.withLock { counts }
    }

    /// A stream was started.
    internal static func started() {
        _ = printsAtExit
        lock.withLock {
            counts.live += 1
            counts.peak = max(counts.peak, counts.live)
        }
    }

    /// A stream was ended.
    internal static func ended() {
        lock.withLock { counts.live -= 1 }
    }

    /// A stream could not be had.
    internal static func wasRefused() {
        _ = printsAtExit
        lock.withLock { counts.refused += 1 }
    }
}
