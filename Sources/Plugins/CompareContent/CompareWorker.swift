import Foundation

/// Where the session's loading, comparing and searching run: a thread of their own for each, never
/// a worker of the shared pool.
///
/// Reading from a share that does not answer can block for as long as the server takes to give up;
/// a handful of those must not use up the workers that everything else needs.
internal enum CompareWorker {
    /// Runs `body` on a new thread called `name`, at user-initiated priority; returns at once.
    internal static func run(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
    }
}
