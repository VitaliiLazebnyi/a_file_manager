import Foundation

/// Coalescing the reports of the real file systems.
extension VirtualFileSystem {
    /// Passes the first report on at once and the ones that follow within a short time as one
    /// more report after it.
    ///
    /// The reports go out on the main thread, whichever thread the real file system reports on, and
    /// none goes out once `cancel` was called. A folder that keeps changing is reported ever less
    /// often (up to `longestWindow` apart), so that the virtual folder is not walked again all the
    /// time.
    ///
    /// All mutable state is guarded by `lock`.
    internal final class Coalescer: @unchecked Sendable {
        /// How long after a report the next one waits, at first.
        internal static let window: TimeInterval = 0.5
        /// The longest wait between two reports, however busy the folder is.
        internal static let longestWindow: TimeInterval = 8
        private let lock = NSLock()
        private var isQuiet = true
        private var isDirty = false
        private var isCancelled = false
        private var wait = Coalescer.window
        private let fire: @MainActor @Sendable () -> Void

        /// A coalescer that reports by calling `fire`, on the main thread.
        internal init(_ fire: @escaping @MainActor @Sendable () -> Void) { self.fire = fire }

        /// Ends the reports, also the ones that are waiting for their turn.
        internal func cancel() {
            lock.lock()
            defer { lock.unlock() }
            isCancelled = true
        }

        /// Takes one report of the real file system, from any thread.
        internal func signal() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            guard isQuiet else {
                isDirty = true
                lock.unlock()
                return
            }
            isQuiet = false
            wait = Self.window
            let delay = wait
            lock.unlock()
            deliver()
            schedule(after: delay)
        }

        /// Ends a wait: reports again when more came in meanwhile, and waits twice as long;
        /// otherwise the folder is quiet again.
        @MainActor
        private func settle() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            let again = isDirty
            isDirty = false
            if again {
                wait = min(wait * 2, Self.longestWindow)
            } else {
                isQuiet = true
                wait = Self.window
            }
            let delay = wait
            lock.unlock()
            guard again else {
                return
            }
            fire()
            schedule(after: delay)
        }

        /// Reports at once on the main thread, or as soon as the main thread is free.
        private func deliver() {
            if Thread.isMainThread {
                MainActor.assumeIsolated { fire() }
            } else {
                DispatchQueue.main.async { [self] in
                    lock.lock()
                    let cancelled = isCancelled
                    lock.unlock()
                    // The main queue runs its blocks on the main thread.
                    if !cancelled { MainActor.assumeIsolated { fire() } }
                }
            }
        }

        /// Ends the wait after `delay`, on the main thread.
        private func schedule(after delay: TimeInterval) {
            // The main queue runs its blocks on the main thread.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in MainActor.assumeIsolated { settle() } }
        }

        deinit {
            // Nothing to release.
        }
    }
}
