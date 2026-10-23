import Dispatch

/// The queues the work for one document runs on, so that a read that never returns (a share that
/// stopped answering) holds up that document only, not the next file shown.
internal final class DocumentQueues: Sendable {
    /// Row fetches: a newer one replaces an older one that is still waiting.
    internal let rows = DispatchQueue(label: "viewer.rows", qos: .userInitiated)
    /// Looks for a place or a line, and for the text cursor.
    internal let lookups = DispatchQueue(label: "viewer.lookups", qos: .userInitiated)

    deinit {
        // Nothing to release.
    }
}
