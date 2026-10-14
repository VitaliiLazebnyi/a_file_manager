import Foundation

/// The threads of the concurrent stage, and how many of them still run.
///
/// Unchecked: `alive` and `started` are only touched while `lock` is held.
internal final class ThreadGroup: @unchecked Sendable {
    /// Guards `alive` and `started`.
    private let lock = NSLock()
    /// The threads that have not ended.
    private var alive = 0
    /// Every thread started.
    private var started = 0

    /// How many threads still run.
    internal var running: Int {
        lock.withLock { alive }
    }

    /// How many threads were started.
    internal var count: Int {
        lock.withLock { started }
    }

    /// Starts a thread called `name` with an 8 MB stack that runs `body`.
    internal func launch(_ name: String, _ body: @escaping @Sendable () -> Void) {
        lock.withLock {
            alive += 1
            started += 1
        }
        let thread = Thread { [self] in
            body()
            lock.withLock { alive -= 1 }
        }
        thread.name = name
        thread.stackSize = 8 << 20
        thread.start()
    }

    deinit {
        // Nothing to release.
    }
}
