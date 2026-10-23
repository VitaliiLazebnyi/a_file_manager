internal import Foundation

/// What is known of the links of one server: whether each leads to a directory, by path.
///
/// Shared by the connections of a session, so that what one found, in the background or while
/// listing, spares the others the question. Safe from any thread: all state is guarded by `lock`.
internal final class LinkMemory: @unchecked Sendable {
    /// Where a link leads, as far as a listing needs to know.
    internal enum Target: Equatable, Sendable {
        /// A directory: the link opens like a folder.
        case directory
        /// Anything else: a file, or nothing that could be reached.
        case nonDirectory
    }

    private static let capacity = 2_048

    private let lock = NSLock()
    private var targets: [String: Target] = [:]

    /// What the link at a full path was found to lead to; nil when that is not known.
    internal func target(of path: String) -> Target? {
        lock.lock()
        defer { lock.unlock() }
        return targets[path]
    }

    /// Keeps what the link at a full path leads to; when the memory is full it starts again empty.
    internal func remember(_ path: String, target: Target) {
        lock.lock()
        defer { lock.unlock() }
        if targets.count >= Self.capacity { targets.removeAll() }
        targets[path] = target
    }

    /// After anything changed on the server that may have changed where a link leads.
    internal func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        targets.removeAll()
    }

    deinit {
        // Nothing to release.
    }
}
