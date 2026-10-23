import Foundation

/// One call of the file system that changes something, and the system calls it is made of.
///
/// Each system call that may wait on the volume goes through `run`: it can then be ended by
/// `interruption` (from another thread, when the caller's flag is set), and none is begun once that
/// has happened. What must be done whatever happens (putting a lock back) is called directly
/// instead.
internal final class LocalCall: Sendable {
    /// Ends the system call under way, and keeps the next one from being begun.
    internal let interruption = Interruption()
    private let willAsk: (@Sendable (String) -> Void)?

    /// A call that tells `probes` about every path it asks the system about.
    internal init(_ probes: LocalProbes) {
        willAsk = probes.willAsk
    }

    /// Runs one system call on `path` that returns a negative number and sets `errno` on
    /// failure.
    ///
    /// Returns its result, with `errno` set on failure; throws `userCancelled` once interrupted.
    internal func run(_ path: String, _ call: () -> Int32) throws -> Int32 {
        willAsk?(path)
        return Int32(try interruption.run { Int(call()) })
    }

    /// The same for a call that must not be made a second time when a signal nobody sent
    /// ends it early (a copy that has made its file already): the `EINTR` is the caller's.
    internal func runOnce(_ path: String, _ call: () -> Int32) throws -> Int32 {
        willAsk?(path)
        guard interruption.begin() else { throw CocoaError(.userCancelled) }
        let result = call()
        let code = errno
        interruption.end()
        errno = code
        return result
    }

    deinit {
        // Nothing to release.
    }
}
