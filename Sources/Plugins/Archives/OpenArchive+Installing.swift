import AFMKernel
import Foundation

/// Putting the new archive file in place, reading a file changed by someone else, sending a fetched one back.
extension OpenArchive {
    /// Puts the new file in the archive's place and makes the directory in memory speak of
    /// it: one rename, then a walk over the entries that were written.
    ///
    /// The disk is asked and the file renamed **without** the directory's lock; the lock is
    /// taken only for the walk, which is memory alone. That is sound because the gate is held
    /// (no other write of this archive runs, and `signature` and `file` change nowhere else),
    /// and because the archive has changes waiting until the walk is done: `isCurrent`
    /// answers for a busy archive without looking at the disk, so nobody takes the moment
    /// between the rename and the walk for a change made by someone else. Readers that hold
    /// the old file go on reading it; it lives for as long as it is open.
    internal func install(_ built: Built, from snapshot: Snapshot) throws {
        let newFile = try putInPlace(built)
        lock.lock()
        defer { lock.unlock() }
        file = newFile
        // Of the file that was opened: no other can have come between.
        signature = newFile.signature
        directoryOffset = built.directoryOffset
        if unlisted.count == built.unlistedOffsets.count {
            for (index, offset) in built.unlistedOffsets.enumerated() {
                unlisted[index].source = .archive(headerOffset: offset, file: newFile)
            }
        }
        let vanished = repoint(snapshot, to: newFile, offsets: built.offsets)
        if snapshot.isComplete { writtenCount = snapshot.changeCount }
        if built.isRewrite { writtenRemovals = snapshot.removals }
        if vanished > 0 {
            // The next write takes them out again; it is due like any other change. (Taking
            // one out counted as a change, after the snapshot: that change is still waiting.)
            removals += vanished
            if let delay = environment.flushDelay { armTimer(after: idleDelay(delay)) }
        }
        pendingBytes -= min(pendingBytes, snapshot.pendingBytes)
        if fetchedCopy != nil { uploadPending = true }
    }

    /// Renames the new file to the archive's name; returns the new file, opened.
    ///
    /// Refused when someone else changed the archive file since it was read. The new file is
    /// removed when that fails.
    private func putInPlace(_ built: Built) throws -> RandomAccessFile {
        do {
            guard FileSignature.of(localURL.path) == locked({ signature }) else {
                throw ArchiveError.changedOutside(name)
            }
            let newFile = try RandomAccessFile(built.url, shownAs: localURL.path)
            guard Darwin.rename(built.url.path, localURL.path) == 0 else { throw posixError(errno, localURL.path) }
            return newFile
        } catch {
            unlink(built.url.path)
            throw error
        }
    }

    /// Makes the entries that were written point into the new file; returns how many of the
    /// members this write put there for the first time have been removed meanwhile.
    ///
    /// Entries are found by path; one that was renamed while the file was written, by its
    /// position. Called with the lock held.
    private func repoint(_ snapshot: Snapshot, to newFile: RandomAccessFile, offsets: [Int: UInt64]) -> Int {
        var vanished = 0
        for written in snapshot.entries {
            guard case .zip(let then) = written.content, let offset = offsets[written.order] else { continue }
            var path = written.path
            if tree.entry(path)?.order != written.order {
                guard let moved = tree.path(atOrder: written.order) else {
                    // Removed (or replaced) while the file was written: the file holds it
                    // all the same. One that was in the old file was counted when it was
                    // removed; one that this write put there for the first time is counted now.
                    if !then.isInArchive { vanished += 1 }
                    continue
                }
                path = moved
            }
            // (The entry at the written one's position is that member, so it is a ZIP member.)
            tree.update(path) { entry in
                if case .zip(var record) = entry.content {
                    // Changed again meanwhile: the data is in the file, the newer header is not.
                    if record.hasSameHeader(as: then) { record.unwritten.formIntersection(.arriving) }
                    record.source = .archive(headerOffset: offset, file: newFile)
                    entry.content = .zip(record)
                }
            }
        }
        return vanished
    }

    /// Reads the archive again after another program changed it, and adds the members that
    /// exist only here to what it holds now; one whose name is taken there gets a name of
    /// its own.
    ///
    /// Returns true when changes to members of the old archive had to be given up.
    ///
    /// The file is opened and its directory read without the lock; the lock is taken to put
    /// the new directory in the old one's place, which is memory alone.
    internal func rebase() throws -> Bool {
        let reopened: RandomAccessFile
        let listing: ZipListing
        // (Only a ZIP is changed, so only a ZIP is read again.)
        do {
            reopened = try RandomAccessFile(localURL, shownAs: nil)
            listing = try Self.readZip(reopened, environment: environment, control: nil)
            guard !listing.hasDuplicates else { throw ArchiveError.changedOutside(name) }
        } catch {
            throw ArchiveError.changedOutside(name)
        }
        lock.lock()
        defer { lock.unlock() }
        let fresh = tree.ordered.compactMap { entry -> (entry: ArchiveEntry, record: ZipRecord)? in
            guard case .zip(let record) = entry.content, !record.isInArchive else {
                return nil
            }
            return (entry, record)
        }
        let lost =
            removals != writtenRemovals
            || tree.contains { entry in
                if case .zip(let record) = entry.content {
                    return record.isInArchive && !record.unwritten.isEmpty
                }
                return false
            }
        file = reopened
        signature = reopened.signature
        (tree, unlisted, hasDuplicates) = (listing.tree, listing.unlisted, false)
        (comment, directoryOffset, prefixEnd) = (listing.comment, listing.directoryOffset, listing.prefixEnd)
        (writtenCount, writtenRemovals, pendingBytes, transfers) = (changeCount, removals, 0, 0)
        loadCount += 1
        for (entry, record) in fresh {
            addBack(entry, record)
        }
        if !fresh.isEmpty { changeCount += 1 }
        publish()
        return lost
    }

    /// Adds a member that exists only here to the directory read anew.
    ///
    /// One whose name is taken there gets a name of its own. Called with the lock held.
    private func addBack(_ fresh: ArchiveEntry, _ written: ZipRecord) {
        var (entry, record) = (fresh, written)
        if entry.isDirectory {
            if let existing = tree.entry(entry.path), !existing.isImplicit {
                return
            }
        } else if tree.entry(entry.path) != nil {
            let (folder, parts) = (ArchiveTree.parent(of: entry.path), FileItem.split(entry.name))
            var number = 2
            repeat {
                entry.path = ArchiveTree.join(
                    folder,
                    "\(parts.base) (\(number))" + (parts.ext.isEmpty ? "" : "." + parts.ext)
                )
                number += 1
            } while tree.entry(entry.path) != nil
            record.setName(entry.path)
            entry.content = .zip(record)
        }
        pendingBytes = pendingBytes.plusClamped(record.compressedSize)
        put(entry, keepingOrder: false)
    }

    /// Puts the changed copy back where the archive came from.
    ///
    /// The copy stays ahead of the original until that has worked.
    internal func upload(cancellation: CancellationFlag?, progress: (Int64, Int64) -> Bool) throws {
        guard let fileSystems = environment.fileSystems() else { throw ArchiveError.readOnly(name) }
        let provider = try fileSystems.provider(for: archiveURL)
        let temporary = archiveURL.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        let local = locked { file }
        let flag = cancellation ?? CancellationFlag()
        let writer = try provider.write(temporary, cancellation: flag)
        // A write that waits on the server is ended by the request too.
        let tie = flag.interrupting(writer)
        try withExtendedLifetime(tie) {
            do {
                let source = FileRangeStream(local, offset: 0, length: nil)
                let size = Int64(clamping: local.size)
                var sent: Int64 = 0
                while let block = try source.read(upToCount: 1 << 20) {
                    try Self.check(cancellation)
                    if !progress(sent, size) { throw ArchiveError.cancelled }
                    try writer.write(block)
                    sent += Int64(block.count)
                }
                try writer.close(attributes: FileAttributes())
                try provider.move(temporary, to: archiveURL, replacing: true, cancellation: flag)
            } catch {
                try? writer.close(attributes: FileAttributes())
                try? provider.remove(temporary)
                throw error
            }
        }
        // When the server cannot say what it holds now, the next look at it sets the mark
        // (see `isCurrent`).
        let stamp = provider.item(at: archiveURL, cancellation: flag).map { item in (item.size, item.modified) }
        locked {
            remoteStamp = stamp
            uploadPending = false
        }
    }
}
