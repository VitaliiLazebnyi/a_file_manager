import AFMKernel
import Foundation

/// A request to end a read that runs through streams (decompressing, skipping on to a member,
/// waiting for a child process).
///
/// Set from any thread; the streams that can take long look at it and throw, and a child process is
/// stopped by it. All state is guarded by `lock`.
internal final class StreamInterrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var isRaised = false
    private var handlers: [@Sendable () -> Void] = []

    /// True once the request was made.
    internal var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRaised
    }

    /// Makes the request: runs the handlers waiting for it, on the calling thread, once.
    internal func set() {
        lock.lock()
        let waiting = isRaised ? [] : handlers
        isRaised = true
        handlers = []
        lock.unlock()
        for handler in waiting { handler() }
    }

    /// Throws `ArchiveError.cancelled` once the request was made.
    internal func check() throws {
        if isSet { throw ArchiveError.cancelled }
    }

    /// Runs `handler` when the request is set, at once if it is already.
    ///
    /// Holds on to what it touches weakly.
    internal func onSet(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard isRaised else {
            handlers.append(handler)
            lock.unlock()
            return
        }
        lock.unlock()
        handler()
    }

    /// Set when `flag` is, for as long as the returned object is held.
    internal func following(_ flag: CancellationFlag?) -> AnyObject? {
        flag?.onCancel { [weak self] in self?.set() }
    }

    deinit {
        // Nothing to release.
    }
}
