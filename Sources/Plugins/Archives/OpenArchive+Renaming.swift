import AFMKernel
import Foundation

/// Renaming members.
extension OpenArchive {
    /// The renaming itself, with the lock held.
    ///
    /// Returns what stood at the destination.
    internal func rename(_ source: String, to destination: String, replacing: Bool) throws -> ArchiveEntry? {
        guard let entry = tree.entry(source), !destination.isEmpty else { throw ArchiveError.notFound(source) }
        if ArchiveTree.relative(destination, to: source) != nil {
            throw FileSystemError.notSupported("Moving a folder into itself")
        }
        var replaced: ArchiveEntry?
        if let existing = tree.entry(destination) {
            guard replacing else { throw FileSystemError.alreadyExists(destination) }
            // As on the disk: a file takes the place of a file, and a folder that of an empty folder.
            if existing.isDirectory != entry.isDirectory || tree.hasChildren(destination) {
                throw FileSystemError.alreadyExists(destination)
            }
            take(existing)
            replaced = existing
        }
        let moved = [entry] + (entry.isDirectory ? tree.descendants(of: source) : [])
        for item in moved {
            if Self.isTransfer(item) { transfers -= 1 }
            tree.remove(item.path)
        }
        for var item in moved.sorted(by: { $0.order < $1.order }) {
            // Cut and joined by bytes: the paths are not the same string to Swift in every case.
            item.path =
                ArchiveTree.relative(item.path, to: source).map { rest in destination + "/" + rest } ?? destination
            if case .zip(var record) = item.content {
                record.setName(item.isDirectory ? item.path + "/" : item.path)
                record.unwritten.remove(.arriving)
                item.content = .zip(record)
            }
            tree.insert(item, keepingOrder: true)
        }
        keepFolder(ArchiveTree.parent(of: source))
        changed()
        return replaced
    }

    /// Renames a file, or a folder with everything in it.
    ///
    /// A file that has just come through a writer gets its final name this way when a job
    /// has copied it in (jobs write under a temporary name and rename). Whoever moves files
    /// deletes the source once the rename has returned, so here the archive file is written
    /// before it returns, when that is cheap (`immediateWriteLimit`): if the write fails,
    /// the rename fails with it, is taken back, and the source stays. A write that would
    /// cost more than the limit is left to the timer, and so is one that would have to wait
    /// for a write that is under way; a file was only admitted then because
    /// the disk had room for that write (`finishWrite`), and a write that fails all the same
    /// loses nothing: it is reported and tried again. Files of other threads that are still
    /// under their temporary names are left out of this write; each follows with its own.
    ///
    /// This is a convenience for callers that do not `commit`; one that does makes it
    /// redundant. So that a job with many small files does not write the directory again
    /// for each of them, what these writes cost between two rests is held to the limit plus
    /// the bytes that arrived meanwhile (the data pays for its own overhead); past that the
    /// timer or the commit writes.
    internal func move(_ source: String, to destination: String, replacing: Bool) throws {
        var replaced: ArchiveEntry?
        var loaded = 0
        try requireWritable()
        let writesNow: UInt64? = try locked {
            try requireEditable()
            guard let entry = tree.entry(source) else { throw ArchiveError.notFound(source) }
            guard source != destination else {
                return nil
            }
            replaced = try rename(source, to: destination, replacing: replacing)
            loaded = loadCount
            return immediateCost(of: entry)
        }
        guard let writesNow else {
            return
        }
        // Not behind a write that may take minutes: then the timer (or the commit) writes.
        // Behind another rename's write, which is as small as this one, it waits its turn.
        guard gate.lockUnlessLong() else {
            return
        }
        do {
            defer { gate.unlock() }
            try flushLocked(leavingOutArrivals: true, cancellation: nil) { _, _ in true }
            locked { immediateSpent = immediateSpent.plusClamped(writesNow) }
        } catch {
            locked { takeBack(destination, to: source, replaced: replaced, loaded: loaded) }
            throw error
        }
        // The archive file has a new size and date; the panels hear of it once the job pauses.
        locked {
            notifyPending = true
            if let delay = environment.flushDelay { armTimer(after: delay) }
        }
    }

    /// What writing the archive file now would cost, for a member that has just been given its
    /// final name; nil when that is not to be written before the rename returns (see `move`).
    ///
    /// Called with the lock held.
    private func immediateCost(of entry: ArchiveEntry) -> UInt64? {
        guard !entry.isDirectory, case .zip(let record) = entry.content, record.unwritten.contains(.arriving),
            environment.immediateWriteLimit > 0
        else { return nil }
        // The directory is written; so is the member once more, if a write that came
        // between has already put it into the file under its temporary name.
        var cost = file.size - min(file.size, directoryOffset)
        if record.isInArchive { cost = cost.plusClamped(record.compressedSize) }
        if writesWholeArchive { cost = cost.plusClamped(file.size) }
        guard cost <= max(environment.immediateWriteLimit, pendingBytes),
            immediateSpent.plusClamped(cost) <= environment.immediateWriteLimit.plusClamped(arrivedBytes)
        else { return nil }
        return cost
    }

    /// Takes back a rename whose write failed: the member goes back to its temporary name (on
    /// its way again), and what it replaced comes back.
    ///
    /// Called with the lock held. After the directory was read anew from a file that someone
    /// else changed (`loadCount` is no longer `loaded`), the member has been put back by its new
    /// name already, and what stood at the destination is what the file holds: nothing is done.
    private func takeBack(_ destination: String, to source: String, replaced: ArchiveEntry?, loaded: Int) {
        guard loadCount == loaded else {
            return
        }
        _ = try? rename(destination, to: source, replacing: false)
        // Under its temporary name again, it is on its way again.
        if var entry = tree.remove(source) {
            if case .zip(var record) = entry.content {
                record.unwritten.insert(.arriving)
                entry.content = .zip(record)
            }
            put(entry, keepingOrder: true)
        }
        if let replaced {
            put(replaced, keepingOrder: true)
            // Taking it out was counted; it is back.
            if case .zip(let record) = replaced.content {
                if record.isInArchive {
                    removals -= 1
                } else {
                    pendingBytes = pendingBytes.plusClamped(record.compressedSize)
                }
            }
        }
    }
}
