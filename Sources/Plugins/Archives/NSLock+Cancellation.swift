import AFMKernel
import Foundation

/// Taking a lock with an end to the wait.
extension NSLock {
    /// Takes the lock; with a `cancellation` in turns, so that a wait for somebody who holds it
    /// long (an archive's opening) ends soon after the flag is set, with `ArchiveError.cancelled`.
    internal func lock(unlessCancelled cancellation: CancellationFlag?) throws {
        guard let cancellation else {
            lock()
            return
        }
        var isLocked: Bool
        repeat {
            isLocked = lock(before: Date(timeIntervalSinceNow: 0.05))
        } while !isLocked && !cancellation.isCancelled
        guard isLocked else { throw ArchiveError.cancelled }
    }
}
