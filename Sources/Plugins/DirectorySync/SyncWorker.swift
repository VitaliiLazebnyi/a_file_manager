import Foundation

/// Where the session's comparison, list and plan are made: a thread of their own for each, not a worker
/// of the shared pool (see `SyncSession.compare`).
internal enum SyncWorker {
    /// Runs `body` on a new thread called `name`, at user-initiated priority; returns at once.
    internal static func run(_ name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.stackSize = 4 << 20
        thread.start()
    }
}
