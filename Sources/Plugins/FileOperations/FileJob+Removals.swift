import AFMKernel
import Foundation

/// The removal of the sources of a move after the commit of a file system that writes later
/// (`defersRemovals`), and the removal of one entry of a tree the job walked.
extension FileJob {
    /// Notes a source of a move whose removal waits for the commit; any thread of the job.
    internal func postponeRemoval(of url: URL, isFolder: Bool, tree: URL?) {
        pendingRemovals.withLock { deferred.append(DeferredRemoval(url: url, isFolder: isFolder, tree: tree)) }
    }

    /// Removes one entry: a file, a link or an empty folder.
    ///
    /// An entry of a tree the job walked into (`tree` is the top folder of that tree, one of the
    /// job's own sources) is removed by going down from that folder without following a link
    /// (`remove(_:below:cancellation:)`): should a folder on the way have been swapped for a link
    /// since it was listed, nothing is removed and the step fails, instead of an entry of the same
    /// name going wherever the link leads (F043). A source itself is removed by its path. File
    /// systems without such a walk remove by path in both cases.
    internal func remove(_ url: URL, below tree: URL?) throws {
        let provider = try fileSystems.provider(for: url)
        if let tree, (try? fileSystems.provider(for: tree)) === provider {
            try provider.remove(url, below: tree, cancellation: cancellation)
        } else {
            try provider.remove(url, cancellation: cancellation)
        }
    }

    /// Whether `url`, or something below it, was kept at its source.
    internal func isKept(_ url: URL) -> Bool {
        pendingRemovals.withLock { kept.contains(url.locationKey) }
    }

    /// Notes that `url` stays, and with it every folder above.
    ///
    /// Called with `pendingRemovals` held.
    private func keep(_ url: URL) {
        var current = url
        // A folder that is noted has everything above it noted too.
        while kept.insert(current.locationKey).inserted {
            let above = current.deletingLastPathComponent()
            guard above.path.count < current.path.count else { break }
            current = above
        }
    }

    /// What still waits when the job is over was not removed.
    internal func keepPendingRemovals() {
        pendingRemovals.withLock {
            for removal in deferred { keep(removal.url) }
            deferred = []
        }
    }

    /// Makes what was written durable, then removes the sources that wait, files before the
    /// folders that held them.
    ///
    /// Every writer of the waiting files is closed. If the commit fails nothing is removed: the
    /// user is told, as for any failed step, and the job ends.
    internal func flushDeferred() throws {
        let pending = pendingRemovals.withLock { () -> [DeferredRemoval] in
            defer { deferred = [] }
            return deferred
        }
        guard !pending.isEmpty, let target else {
            return
        }
        var done = 0
        // Whatever was not removed stays, however this is left.
        defer {
            pendingRemovals.withLock {
                for removal in pending[done...] { keep(removal.url) }
            }
        }
        try checkCancelled()
        let folder = target.directory
        // Said before the writing starts, which is also where a paused job waits: a commit
        // that is under way cannot be held back, one that has not begun can.
        report(["Writing: \(display(folder))"])
        emit(force: true)
        try checkCancelled()
        do {
            // The file system asks between the members it writes (or the blocks it sends):
            // a report goes out when one is due, which is where a paused job waits, so Pause
            // takes hold inside the commit too; false ends it.
            try fileSystems.provider(for: folder)
                .commit(folder, cancellation: cancellation) { [self] _, _ in
                    if counters.withLock({ isDue }) { emit(force: false) }
                    return !isStopping
                }
        } catch {
            if isStopping { throw Cancelled() }
            // Nothing written since the last commit can be relied on. A Retry would only ask
            // again for the same answer, never remove anything.
            _ = try attempt(.move, at: folder, target: nil) { throw error }
            stop.cancel()
            throw Cancelled()
        }
        for removal in pending {
            try checkCancelled()
            // Shown like every other step, which is also where a paused job waits.
            report { ["Deleting: \(self.display(removal.url))"] }
            if isKept(removal.url) {
                // Something inside was not removed, so this folder cannot be.
                done += 1
                continue
            }
            let removed = try attempt(removal.isFolder ? .removeFolder : .delete, at: removal.url, target: nil) {
                try self.remove(removal.url, below: removal.tree)
                return true
            }
            done += 1
            if !removed { pendingRemovals.withLock { keep(removal.url) } }
        }
    }
}
