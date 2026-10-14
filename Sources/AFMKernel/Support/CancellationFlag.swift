import Foundation

/// A request to stop, shared between whoever asks (a Cancel button, the program quitting) and
/// the work that checks it. Safe to use from any thread.
public final class CancellationFlag {
    private let lock = NSLock()
    private var cancelled = false
    /// What `onCancel` was given, until the flag is set or the registration is released.
    private var handlers: [Int: () -> Void] = [:]
    private var lastHandler = 0

    public init() {}

    public func cancel() {
        lock.lock()
        let waiting = cancelled ? [:] : handlers
        cancelled = true
        handlers = [:]
        lock.unlock()
        // Outside the lock: a handler may look at the flag, or take a while.
        for handler in waiting.values { handler() }
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// For work that waits where it cannot look at the flag (in a read from a server): `handler`
    /// is called once when the flag is set, on the thread that sets it, or here and now when
    /// it is set already. It is forgotten when the returned object is released, which whoever
    /// registers does as soon as the wait is over.
    ///
    /// The handler runs while the work it ends is still running on its own thread, so it does
    /// only what is safe from another thread (close a socket, set a mark) and returns at once.
    /// A cancel that has begun may still call it for a moment after the object was released:
    /// it holds what it touches weakly, or touches only what outlives the registration.
    public func onCancel(_ handler: @escaping () -> Void) -> AnyObject {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            handler()
            return Registration(flag: nil, id: 0)
        }
        lastHandler += 1
        let id = lastHandler
        handlers[id] = handler
        lock.unlock()
        return Registration(flag: self, id: id)
    }

    private final class Registration {
        private weak var flag: CancellationFlag?
        private let id: Int

        init(flag: CancellationFlag?, id: Int) {
            self.flag = flag
            self.id = id
        }

        deinit {
            guard let flag else { return }
            flag.lock.lock()
            let handler = flag.handlers.removeValue(forKey: id)
            flag.lock.unlock()
            // Released outside the lock: what the handler holds may itself touch the flag.
            _ = handler
        }
    }
}
