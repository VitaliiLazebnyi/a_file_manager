import AFMKernel
import Foundation

/// Copying: files written whole under their names, with their dates, and made durable.
extension SyncExecutor {
    /// Copies one file or creates one folder; returns false when the item was left alone on the user's wish.
    internal func perform(_ copy: SyncPlan.Copy) throws -> Bool {
        let targetSystem = try fileSystems.provider(for: copy.target)
        if copy.isDirectory {
            try targetSystem.createDirectory(at: copy.target)
            directoryDates.append(
                FolderDate(url: copy.target, modified: copy.targetModified, source: copy.source, provider: targetSystem)
            )
            noteWrite(to: copy.target, in: targetSystem)
            outcome.copied += 1
            return true
        }
        // What a plugin still holds back for the source (an archive written after a delay) is written first.
        try fileSystems.flushPendingWrites(to: copy.source, cancellation: cancellation)
        let folder = copy.target.deletingLastPathComponent()
        if knownDirectories.insert(folder.locationKey).inserted, targetSystem.item(at: folder) == nil {
            try targetSystem.createDirectory(at: folder)
        }
        let existing = targetSystem.item(at: copy.target)
        if let existing {
            guard try mayReplace(existing, with: copy) else {
                return false
            }
        }
        // A file that replaces another, and any file on a file system that keeps writes back (an
        // archive): written under a temporary name and renamed, so that what is under the final name is
        // always complete and, on the latter, is found by the commit that makes it durable.
        if existing != nil || targetSystem.capabilities(for: copy.target).contains(.deferredWrites) {
            try replace(copy, in: folder, replacingExisting: existing != nil, on: targetSystem)
        } else {
            try transfer(copy, to: copy.target, in: targetSystem)
        }
        adjustDate(of: copy, in: targetSystem)
        noteWrite(to: copy.target, in: targetSystem)
        outcome.copied += 1
        return true
    }

    /// Whether a copy may replace the file that is there: false to leave it, on the user's word or an earlier
    /// "Skip All"; throws for a folder in the way, or when the user cancels.
    private func mayReplace(_ existing: FileItem, with copy: SyncPlan.Copy) throws -> Bool {
        if existing.isDirectory {
            throw FileSystemError.alreadyExists(fileSystems.displayPath(copy.target))
        }
        if skipAllExisting {
            return false
        }
        guard options.confirmOverwrites, !overwriteAll else {
            return true
        }
        switch onOverwrite(existing, copy) {
        case .overwrite:
            return true

        case .overwriteAll:
            overwriteAll = true
            return true

        case .skip:
            return false

        case .skipAll:
            skipAllExisting = true
            return false

        case .cancel:
            throw Cancelled()
        }
    }

    /// Writes the copy under a temporary name in `folder` and moves it over the target.
    ///
    /// The copy and the move are one unit: whatever stops them (a failure, the cancel after the copy was
    /// complete) does not leave the temporary behind.
    private func replace(
        _ copy: SyncPlan.Copy,
        in folder: URL,
        replacingExisting: Bool,
        on targetSystem: any FileSystemProvider
    ) throws {
        let temporary = folder.appending(name: ".\(copy.target.lastPathComponent).afm-sync")
        try? targetSystem.remove(temporary)
        do {
            try transfer(copy, to: temporary, in: targetSystem)
            if cancellation.isCancelled {
                throw Cancelled()
            }
            do {
                try targetSystem.move(temporary, to: copy.target, replacing: true)
            } catch  where replacingExisting {
                // A file system that cannot replace in one step: the old file steps aside, the
                // new one takes its place, and the old one comes back if that fails. The aside
                // name is free: a leftover from an earlier failure may be the only copy of a file.
                let aside = freeName(folder, ".\(copy.target.lastPathComponent).afm-old", in: targetSystem)
                try targetSystem.move(copy.target, to: aside, replacing: false)
                do {
                    try targetSystem.move(temporary, to: copy.target, replacing: false)
                } catch {
                    try putBack(aside, at: copy.target, on: targetSystem, temporary: temporary)
                    throw error
                }
                try? targetSystem.remove(aside)
            }
        } catch {
            try? targetSystem.remove(temporary)
            throw error
        }
    }

    /// Moves the old file back under its name after the new one could not take it; throws, saying where the old
    /// file is kept, when that fails too.
    private func putBack(
        _ aside: URL,
        at target: URL,
        on targetSystem: any FileSystemProvider,
        temporary: URL
    ) throws {
        do {
            try targetSystem.move(aside, to: target, replacing: false)
        } catch {
            // Neither is under the name; the old file is not deleted, and the user is told where it is.
            try? targetSystem.remove(temporary)
            throw NSError(
                domain: "AFMSync",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The old file could not be put back and is kept as \(fileSystems.displayPath(aside))."
                ]
            )
        }
    }

    /// `base`, or `base-2`, `base-3`, … : the first name in `folder` that nothing has.
    private func freeName(_ folder: URL, _ base: String, in provider: any FileSystemProvider) -> URL {
        var candidate = folder.appending(name: base)
        var number = 2
        while provider.item(at: candidate) != nil {
            candidate = folder.appending(name: "\(base)-\(number)")
            number += 1
        }
        return candidate
    }

    /// Remembers that something was written to a file system that keeps writes back.
    private func noteWrite(to url: URL, in provider: any FileSystemProvider) {
        guard provider.capabilities(for: url).contains(.deferredWrites) else {
            return
        }
        let root = provider.root(of: url)
        uncommitted[root.locationKey] = (provider, root)
    }

    /// Makes what the copies wrote durable.
    ///
    /// False when that failed: nothing below the root can be relied on, so the run ends as failed
    /// and deletes nothing.
    internal func commitWrites() -> Bool {
        let pending = uncommitted
        uncommitted = [:]
        for (_, entry) in pending {
            do {
                try entry.provider.commit(entry.root, cancellation: cancellation)
            } catch {
                if cancellation.isCancelled {
                    outcome.wasCancelled = true
                } else {
                    outcome.errors.append("\(fileSystems.displayPath(entry.root)): \(error.localizedDescription)")
                    outcome.commitFailed = true
                }
                return false
            }
        }
        return true
    }

    /// Copies the file to a free name: inside one file system by the file system itself,
    /// otherwise by reading from one and writing to the other.
    ///
    /// Nothing stays behind on failure.
    private func transfer(_ copy: SyncPlan.Copy, to destination: URL, in targetSystem: any FileSystemProvider) throws {
        let sourceSystem = try fileSystems.provider(for: copy.source)
        let report: (Int64) -> Void = { bytes in
            self.onProgress?(
                JobProgress(
                    lines: self.currentLines,
                    itemsDone: self.itemsDone,
                    itemsTotal: self.itemsTotal,
                    bytesDone: self.bytesDone.addingSaturated(bytes),
                    bytesTotal: self.bytesTotal
                )
            )
        }
        if sourceSystem === targetSystem, try copyInside(copy, to: destination, on: sourceSystem, report: report) {
            return
        }
        try stream(copy, to: destination, from: sourceSystem, into: targetSystem, report: report)
    }

    /// Copies inside one file system; false where it cannot (the two places are on different volumes), so that
    /// the file is streamed instead.
    private func copyInside(
        _ copy: SyncPlan.Copy,
        to destination: URL,
        on system: any FileSystemProvider,
        report: (Int64) -> Void
    ) throws -> Bool {
        do {
            try system.copy(copy.source, to: destination) { bytes in
                report(bytes)
                return !self.cancellation.isCancelled
            }
            if cancellation.isCancelled {
                throw Cancelled()
            }
            return true
        } catch FileSystemError.crossesVolumes {
            return false
        } catch {
            if cancellation.isCancelled {
                throw Cancelled()
            }
            throw error
        }
    }

    /// Reads the file from one file system and writes it to the other, with its date, permissions, metadata
    /// and quarantine mark; what was written is removed when that fails.
    private func stream(
        _ copy: SyncPlan.Copy,
        to destination: URL,
        from sourceSystem: any FileSystemProvider,
        into targetSystem: any FileSystemProvider,
        report: (Int64) -> Void
    ) throws {
        let reader = try sourceSystem.read(copy.source, cancellation: cancellation)
        defer { reader.close() }
        let writer = try targetSystem.write(destination, cancellation: cancellation)
        // A read or write blocked on a server ends as soon as the run is cancelled.
        let tokens = [cancellation.interrupting(reader), cancellation.interrupting(writer)]
        defer {
            withExtendedLifetime(tokens) {
                // The reader and the writer can be interrupted up to here.
            }
        }
        do {
            try pour(reader, into: writer, report: report)
            try writer.close(attributes: FileAttributes(modified: copy.targetModified, permissions: copy.permissions))
            // What a copy inside one file system takes along (tags, flags, extended attributes) is asked of the
            // target's file system between two; a file system that cannot do it does not stop the copy.
            try? targetSystem.copyMetadata(from: copy.source, to: destination)
            // A file that came from elsewhere keeps saying so; a mark that cannot be put on does not stop the copy.
            if let mark = sourceSystem.quarantine(of: copy.source) {
                try? targetSystem.setQuarantine(mark, of: destination)
            }
        } catch {
            // Closed before the file is removed, whatever stopped the copy.
            try? writer.close(attributes: FileAttributes())
            try? targetSystem.remove(destination)
            if cancellation.isCancelled {
                throw Cancelled()
            }
            throw error
        }
    }

    /// Writes what the reader hands out, a megabyte at a time, telling `report` the bytes written so far.
    private func pour(_ reader: any FileReader, into writer: any FileWriter, report: (Int64) -> Void) throws {
        var written: Int64 = 0
        var hasMore = true
        while hasMore {
            hasMore = try autoreleasepool { () throws -> Bool in
                guard let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else {
                    return false
                }
                if cancellation.isCancelled {
                    throw Cancelled()
                }
                try writer.write(block)
                written += Int64(block.count)
                report(written)
                return true
            }
        }
    }

    /// A target that did not keep the date it is to have would look different again at the next
    /// comparison.
    ///
    /// The target's date is set; where that is not possible, the source takes the target's date
    /// (spec 09 › Synchronizing with FTP, the timestamp problem), moved by the same amount the
    /// target's was.
    private func adjustDate(of copy: SyncPlan.Copy, in targetSystem: any FileSystemProvider) {
        guard let arrived = targetSystem.item(at: copy.target), !arrived.isSymlink,
            abs(arrived.modified.timeIntervalSince(copy.targetModified)) > Double(options.toleranceSeconds)
        else {
            return
        }
        do {
            try targetSystem.setAttributes(FileAttributes(modified: copy.targetModified), of: copy.target)
        } catch {
            guard options.mayChangeSourceDates, let sourceSystem = try? fileSystems.provider(for: copy.source),
                sourceSystem.item(at: copy.source)?.isSymlink == false
            else {
                return
            }
            let shift = copy.modified.timeIntervalSince(copy.targetModified)
            try? sourceSystem.setAttributes(
                FileAttributes(modified: arrived.modified.addingTimeInterval(shift)),
                of: copy.source
            )
        }
    }
}
