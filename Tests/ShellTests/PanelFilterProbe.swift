import Foundation

/// Counts on which threads a filter was asked.
///
/// Unchecked: the counts are guarded by `lock`.
internal final class PanelFilterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0
    private var other = 0

    /// How often the filter was asked on the main thread.
    internal var onMain: Int { lock.withLock { main } }
    /// How often it was asked on other threads.
    internal var elsewhere: Int { lock.withLock { other } }

    /// A probe that has counted nothing.
    internal init() {
        // Counts start at zero.
    }

    /// The filter was asked, on the calling thread.
    internal func note() {
        lock.withLock {
            if Thread.isMainThread {
                main += 1
            } else {
                other += 1
            }
        }
    }

    /// Starts counting again.
    internal func reset() {
        lock.withLock { (main, other) = (0, 0) }
    }

    deinit {
        // Nothing to release.
    }
}
