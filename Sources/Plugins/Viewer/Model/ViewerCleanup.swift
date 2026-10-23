import AFMKernel
import Dispatch

/// Where things that wait for a file system are done that nobody is waiting for: closing the
/// readers of a file that is no longer shown (an SFTP or FTP close is a request to the server
/// and waits for the answer, up to the session's time-out), deleting copies.
///
/// Never call these from a queue that must not wait, and hand work here from the main thread.
internal enum ViewerCleanup {
    private static let queue = DispatchQueue(label: "viewer.cleanup", qos: .userInitiated, attributes: .concurrent)

    /// Runs `work` on the cleanup queue, beside other cleanup work; returns at once.
    internal static func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Closes the source off the calling thread.
    internal static func close(_ source: (any ByteSource)?) {
        guard let source else {
            return
        }
        queue.async { source.close() }
    }

    /// Closes the readers off the calling thread.
    internal static func close(_ readers: [any FileReader]) {
        guard !readers.isEmpty else {
            return
        }
        queue.async {
            for reader in readers { reader.close() }
        }
    }

    /// Returns once everything handed over so far has been done (for tests).
    internal static func drain() {
        queue.sync(flags: .barrier) {
            // Nothing to do: the barrier runs only after all the work handed over before it.
        }
    }
}
