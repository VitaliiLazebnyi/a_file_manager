import Foundation

/// Remembers the top of the tree for the directories that were read a moment ago.
///
/// A file system finds the top by going up one level at a time, which for a path thousands of
/// levels deep (inside an archive) is thousands of steps over a long text each; the directory above
/// was nearly always asked just before, and its top is this one's.
///
/// Unchecked: all state is guarded by `lock`.
internal final class RootCache: @unchecked Sendable {
    /// What is known of one directory.
    private struct Entry {
        /// The top of its tree.
        let root: URL
        /// When that was found.
        let made: Date
    }

    /// The most directories remembered; past it, all are forgotten.
    private static let capacity = 256
    /// For how long an answer is trusted, in seconds: long enough for walking about in a
    /// tree, short enough for a file system whose tops can change.
    private static let lifetime: TimeInterval = 30

    private let lock = NSLock()
    /// The tops, by file system and location (`key`).
    private var known: [String: Entry] = [:]

    /// The top of the tree of `directory`, whose parent is `parent`, in `provider`.
    internal func root(of directory: URL, parent: URL?, in provider: any FileSystemProvider) -> URL {
        var root = directory
        if let parent {
            // The directory above was nearly always read a moment ago. Otherwise the file
            // system is asked, which answers at once if it knows its tops, and climbs if not.
            root = lookUp(key(parent, provider)) ?? provider.root(of: parent)
        }
        lock.lock()
        if known.count >= Self.capacity { known.removeAll() }
        known[key(directory, provider)] = Entry(root: root, made: Date())
        lock.unlock()
        return root
    }

    /// The key of a directory of a file system.
    private func key(_ directory: URL, _ provider: any FileSystemProvider) -> String {
        "\(UInt(bitPattern: ObjectIdentifier(provider).hashValue)) " + directory.absoluteString
    }

    /// The top remembered for a key, while it is fresh.
    private func lookUp(_ key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = known[key], -entry.made.timeIntervalSinceNow < Self.lifetime else {
            return nil
        }
        return entry.root
    }

    deinit {
        // Nothing to release.
    }
}
