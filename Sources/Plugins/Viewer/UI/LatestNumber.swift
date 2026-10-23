import Foundation

/// A number that can be read on any thread: the newest request, so the work of an overtaken one
/// can be skipped by the queue it waits in.
///
/// Guarded by `lock`.
internal final class LatestNumber: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0

    /// The number; read and written on any thread.
    internal var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return number
        }
        set {
            lock.lock()
            number = newValue
            lock.unlock()
        }
    }

    deinit {
        // Nothing to release.
    }
}
