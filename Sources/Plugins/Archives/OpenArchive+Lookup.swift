import AFMKernel
import Foundation

/// Looking things up in the directory.
extension OpenArchive {
    /// Runs `body` with the directory's lock held, and returns what it returns.
    internal func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The entry at a path; the top folder has none.
    internal func entry(_ path: String) -> ArchiveEntry? {
        locked { tree.entry(path) }
    }

    /// The entries directly inside a folder.
    ///
    /// Throws `notFound` when nothing is at the path, `notADirectory` when a file is.
    internal func children(of path: String) throws -> [ArchiveEntry] {
        try locked {
            guard tree.isDirectory(path) else {
                throw tree.entry(path) == nil ? ArchiveError.notFound(path) : ArchiveError.notADirectory(path)
            }
            return tree.children(of: path)
        }
    }

    /// Everything below a folder, in archive order.
    internal func descendants(of path: String) -> [ArchiveEntry] {
        locked { tree.descendants(of: path) }.sorted { $0.order < $1.order }
    }

    /// False when the archive file was replaced or changed by someone else since it was read
    /// (and for an archive the store has let go).
    ///
    /// The disk is asked without the lock; a server, which costs a round trip, at most once a
    /// second, and with a `cancellation` that wait ends when it is set.
    internal func isCurrent(cancellation: CancellationFlag?) -> Bool {
        lock.lock()
        if retired {
            lock.unlock()
            return false
        }
        if isBusyLocked {
            lock.unlock()
            return true
        }
        guard fetchedCopy != nil else {
            let known = signature
            lock.unlock()
            let now = FileSignature.of(localURL.path)
            // A write of our own may have come between the look and the question.
            return now == known || now == locked { signature }
        }
        guard Date().timeIntervalSince(lastRemoteCheck) > 1 else {
            lock.unlock()
            return true
        }
        lastRemoteCheck = Date()
        let stamp = remoteStamp
        lock.unlock()
        guard let provider = try? environment.fileSystems()?.provider(for: archiveURL) else {
            return false
        }
        let item =
            cancellation.map { flag in provider.item(at: archiveURL, cancellation: flag) }
            ?? provider.item(at: archiveURL)
        // A question that was given up says nothing.
        if cancellation?.isCancelled == true {
            return true
        }
        guard let item else {
            return false
        }
        guard let stamp else {
            // After an upload whose result could not be read back: this is the state to compare with from now on.
            locked { if remoteStamp == nil { remoteStamp = (item.size, item.modified) } }
            return true
        }
        return item.size == stamp.size && item.modified == stamp.modified
    }

    /// Lets the archive go, unless it is in use: see the class comment.
    ///
    /// True when it is retired.
    internal func retireIfIdle() -> Bool {
        locked {
            if retired {
                return true
            }
            guard !isBusyLocked else {
                return false
            }
            retired = true
            return true
        }
    }
}
