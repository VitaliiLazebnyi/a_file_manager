import AFMKernel
import Foundation

/// Writing the changes into the archive file.
extension OpenArchive {
    /// What a write works from: the directory as it was when the write began.
    internal struct Snapshot {
        /// The entries the new file holds, in archive order.
        internal var entries: [ArchiveEntry]
        /// The members without a usable name, which stay in the archive.
        internal var unlisted: [ZipRecord]
        /// The archive file as it was.
        internal var file: RandomAccessFile
        /// The comment at the end of the archive.
        internal var comment: Data
        /// Where the old file's directory starts.
        internal var directoryOffset: UInt64
        /// Where the old file's first member starts.
        internal var prefixEnd: UInt64
        /// The `changeCount` the new file holds.
        internal var changeCount: Int
        /// The `removals` the new file holds.
        internal var removals: Int
        /// Whether members that lie in the old file were removed: then it is written anew.
        internal var removesMembers: Bool
        /// The compressed bytes of the members this write puts into the file.
        internal var pendingBytes: UInt64
        /// Whether the old file may be cloned and added to, as far as is known.
        internal var mayClone: Bool
        /// False when members were left out: then changes are still waiting afterwards.
        internal var isComplete: Bool
    }

    /// Writes the pending changes into the archive file (see the class comment for how).
    ///
    /// If that fails nothing has changed, on disk or here: the changes keep waiting, and the call
    /// can be repeated. Members that were added, or changed again, while the file was being written
    /// wait for the next write, and with `leavingOutArrivals` so do members that came through a
    /// writer and have not been given their final names yet.
    ///
    /// With a `cancellation`, a write that is under way ends soon after it is set, with
    /// `ArchiveError.cancelled`, and so does the wait for another write of this archive to
    /// end; like any failed write it changes nothing. Not for the main thread.
    ///
    /// `progress` is asked between the members that are written and between the blocks that
    /// are sent to a server, with the bytes written so far and those expected; it may take
    /// its time (a job that is paused waits in it), and false ends the write like a cancel.
    internal func flush(
        leavingOutArrivals: Bool,
        cancellation: CancellationFlag?,
        progress: (Int64, Int64) -> Bool
    ) throws {
        try gate.lock(long: true, cancellation: cancellation)
        defer { gate.unlock() }
        try flushLocked(leavingOutArrivals: leavingOutArrivals, cancellation: cancellation, progress: progress)
    }

    /// The write itself, with the gate held.
    internal func flushLocked(
        leavingOutArrivals: Bool,
        cancellation: CancellationFlag?,
        progress: (Int64, Int64) -> Bool
    ) throws {
        let start = Date()
        var rewrote = false
        var lostChanges = false
        try Self.check(cancellation)
        var snapshot = takeSnapshot(leavingOutArrivals: leavingOutArrivals)
        if snapshot != nil, FileSignature.of(localURL.path) != locked({ signature }) {
            // Another program replaced the archive. What was only renamed or deleted here
            // cannot be carried over; new members are added to the archive as it is now. (Should
            // it be replaced once more meanwhile, `install` notices, and the write fails.)
            lostChanges = try rebase()
            snapshot = takeSnapshot(leavingOutArrivals: leavingOutArrivals)
        }
        if let snapshot {
            let built = try build(snapshot, cancellation: cancellation, progress: progress)
            environment.whileWriting?()
            try install(built, from: snapshot)
            // The folder's entry is what makes the new file the archive after a loss of power.
            Durable.syncFolder(of: localURL)
            rewrote = built.isRewrite
        }
        if fetchedCopy != nil, locked({ uploadPending }) {
            try upload(cancellation: cancellation, progress: progress)
            rewrote = true
        }
        locked {
            if rewrote { lastRewriteDuration = Date().timeIntervalSince(start) }
            reportedFailure = nil
            failures = 0
            if !leavingOutArrivals { (immediateSpent, arrivedBytes) = (0, 0) }
        }
        if lostChanges { throw ArchiveError.changedOutside(name) }
    }

    /// Makes the archive file on the disk (or on the server it came from) hold everything
    /// that was written through writers that are closed, and the renames, deletions and
    /// changes of attributes made so far; returns when it does.
    ///
    /// This is the write of the delay, done now, on the calling thread. A write that fails throws
    /// and leaves everything as it is for the next attempt, like the delayed one. The failure is
    /// then the caller's to report: the delay does not report the same one again.
    ///
    /// `progress`: see `flush`; with it a commit that takes long can be shown, held and ended.
    internal func commit(cancellation: CancellationFlag?, progress: (Int64, Int64) -> Bool)
        throws
    {
        do {
            try flush(leavingOutArrivals: false, cancellation: cancellation, progress: progress)
        } catch {
            if cancellation?.isCancelled != true { locked { reportedFailure = error.localizedDescription } }
            throw error
        }
        // The panels that show the archive's folder hear of its new size and date.
        locked {
            notifyPending = true
            if let delay = environment.flushDelay { armTimer(after: delay) }
        }
    }

    /// Runs `body` while no write of this archive is under way, after what was waiting has
    /// been written: for whoever rewrites the archive file itself (Pack). `body` gets a check
    /// to call right before it puts its new file in the archive's place, which throws when
    /// the file is no longer the one that was there when `body` began.
    internal func whileHoldingFile<T>(
        cancellation: CancellationFlag?,
        _ body: (_ stillUnchanged: () throws -> Void) throws -> T
    ) throws -> T {
        try gate.lock(long: true, cancellation: cancellation)
        defer { gate.unlock() }
        try flushLocked(leavingOutArrivals: false, cancellation: cancellation) { _, _ in true }
        let (path, archiveName) = (localURL.path, name)
        let before = FileSignature.of(path)
        return try body {
            guard FileSignature.of(path) == before else { throw ArchiveError.changedOutside(archiveName) }
        }
    }

    /// The directory as the next write is to work from; nil when there is nothing to write.
    private func takeSnapshot(leavingOutArrivals: Bool) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard changeCount != writtenCount else {
            return nil
        }
        // (A folder that loses its last member without ever having had an entry gets one
        // then: `keepFolder`. So every folder without an entry has something in it.)
        var written = tree.ordered
        var (isComplete, hasWork, bytes) = (true, removals != writtenRemovals, UInt64(0))
        written.removeAll { entry in
            guard case .zip(let record) = entry.content else {
                return false
            }
            if record.isInArchive {
                if !record.unwritten.subtracting(.arriving).isEmpty { hasWork = true }
                return false
            }
            // A member under a job's temporary name is never written: it joins the file when
            // it has its real name. It is not a change that waits, either.
            if Self.isTransfer(entry) {
                return true
            }
            if leavingOutArrivals, record.unwritten.contains(.arriving) {
                isComplete = false
                return true
            }
            hasWork = true
            bytes = bytes.plusClamped(record.compressedSize)
            return false
        }
        guard hasWork else {
            // Every change was taken back, or written by a write that came between.
            if isComplete { writtenCount = changeCount }
            return nil
        }
        return Snapshot(
            entries: written,
            unlisted: unlisted,
            file: file,
            comment: comment,
            directoryOffset: directoryOffset,
            prefixEnd: prefixEnd,
            changeCount: changeCount,
            removals: removals,
            removesMembers: removals != writtenRemovals,
            pendingBytes: bytes,
            mayClone: clones() != .unsupported,
            isComplete: isComplete
        )
    }

    /// Whether the changes can be appended to a clone of the archive: nothing was deleted,
    /// every member lies where the directory says, whole and in front of the directory (which
    /// is cut off and written anew), and the stretches no member uses any more (left by
    /// renames, which append a member under its new name) stay below a quarter of the file.
    internal func canAppend(_ snapshot: Snapshot) -> Bool {
        guard snapshot.mayClone, !snapshot.removesMembers, snapshot.directoryOffset <= snapshot.file.size else {
            return false
        }
        var used: UInt64 = 0
        var members: UInt64 = 0
        func count(_ record: ZipRecord) -> Bool {
            guard case .archive(let offset, let file) = record.source else {
                return true
            }
            guard file === snapshot.file else {
                return true
            }
            // A member whose data ran into the directory would be cut with it.
            let end = offset.plusClamped(30 + UInt64(record.nameLength)).plusClamped(record.compressedSize)
            guard offset < snapshot.directoryOffset, end <= snapshot.directoryOffset else {
                return false
            }
            members += 1
            if !record.unwritten.contains(.name) {
                let header = 30 + UInt64(record.nameLength) + UInt64(record.extraLength)
                used = used.plusClamped(header).plusClamped(record.compressedSize)
            }
            return true
        }
        for record in snapshot.unlisted where !count(record) { return false }
        for entry in snapshot.entries {
            if case .zip(let record) = entry.content, !count(record) {
                return false
            }
        }
        let area = snapshot.directoryOffset - min(snapshot.directoryOffset, snapshot.prefixEnd)
        // Headers are counted by what the directory knows of them, which is a little less
        // than they take; that much is not held against the archive.
        let unused = area - min(area, used.plusClamped(members * 48))
        return unused <= max(area / 4, 64 << 10)
    }
}
