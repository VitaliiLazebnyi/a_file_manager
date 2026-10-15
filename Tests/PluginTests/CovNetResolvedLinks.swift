import Foundation

/// The links a session reported resolved, from any thread.
///
/// Unchecked: the paths are guarded by `lock`.
internal final class CovNetResolvedLinks: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    /// The paths reported so far.
    internal var all: [String] { lock.withLock { paths } }

    /// Nothing reported yet.
    internal init() {
        // Nothing is reported yet.
    }

    /// Records `path`.
    internal func add(_ path: String) {
        lock.withLock { paths.append(path) }
    }

    deinit {
        // Nothing to release.
    }
}
