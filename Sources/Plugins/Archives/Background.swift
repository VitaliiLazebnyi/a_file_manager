import AFMKernel
import Foundation

/// Work of an archive job that runs on another thread while the job's thread keeps reporting.
internal enum Background {
    /// Runs `work` on another thread and calls `tick` on this one ten times a second until it
    /// is done: the job's thread stays free to report progress while all cores are busy.
    ///
    /// The other thread is one of the kernel's own, not one of the system's shared pool: the work
    /// reads an archive and writes files, and where that waits (a share, a server) it must not keep
    /// a thread everybody else's work needs.
    internal static func run<Result: Sendable>(_ work: @escaping @Sendable () -> Result, tick: () -> Void) -> Result {
        let group = DispatchGroup()
        // Written by the work before it leaves the group, read here only after the wait: by then
        // it holds the one result.
        nonisolated(unsafe) var results: [Result] = []
        group.enter()
        BlockingCalls.run {
            results.append(work())
            group.leave()
        }
        while group.wait(timeout: .now() + 0.1) == .timedOut { tick() }
        tick()
        return results[0]
    }
}
