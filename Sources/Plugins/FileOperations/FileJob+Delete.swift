import AFMKernel
import Foundation

/// Delete: to the Trash, or for good one entry at a time, with the questions about protected
/// items, folders that are not empty and other volumes.
extension FileJob {
    /// Moves a source to the Trash; where there is none, the user may have it deleted for good instead.
    ///
    /// False when it stays.
    internal func trash(_ source: URL) throws -> Bool {
        report(["Deleting: \(display(source))"])
        defer { add(Measure(items: 1)) }
        let item = try entry(at: source)
        var unsupported: any Error?
        let trashed = try attempt(.trash, at: source, target: nil) {
            do {
                try self.flushBeforeRemoving(source, item)
                let removed = try self.removing(item, at: source) {
                    try self.fileSystems.provider(for: source).trash(source)
                }
                self.record(.trash, source, nil, removed ? .done : .skipped)
                return removed
            } catch let error where Self.isNoTrash(error) {
                // A network share or a disk without a Trash refuses; the system has no way to ask
                // beforehand. The item is still there, so the user may have it deleted for good.
                unsupported = error
                return false
            }
        }
        guard let error = unsupported else {
            return trashed
        }
        guard let item else {
            return try attempt(.trash, at: source, target: nil) { throw error }
        }
        guard try confirm(.noTrash, .delete, item) else {
            record(.trash, source, nil, .skipped)
            return false
        }
        return try deleteTree(source, item: item, isTopLevel: true, tree: nil, depth: 0)
    }

    /// Deletes an item and everything below it, one entry at a time, so every entry is counted,
    /// can fail on its own, and the job can be cancelled in between.
    ///
    /// The files of a folder are deleted by a few workers at once where the disk allows it.
    ///
    /// `tree` is the job's own source that `url` lies below, nil for such a source itself;
    /// see `remove(_:below:)`.
    internal func deleteTree(_ url: URL, item: FileItem?, isTopLevel: Bool, tree: URL?, depth: Int) throws -> Bool {
        try checkCancelled()
        report { ["Deleting: \(self.display(url))"] }
        var complete = true
        // Asked once more of the disk: a folder that somebody swapped for a link since it was
        // listed is a link, and is removed as one, never walked into.
        let isFolder = item?.isRealDirectory == true && !FileIdentity.isSymlink(url)
        if let item, isFolder {
            guard depth < depthLimit else {
                add(measuredBefore(item))
                _ = try attempt(.removeFolder, at: url, target: nil) {
                    throw FileJobError.nestedTooDeep(self.display(url))
                }
                return false
            }
            // A folder that is another volume (a mounted disk image, a share) is not walked
            // into without somebody saying so: "deleting the folder" would erase that volume.
            guard try mayEnter(item, for: .delete) else {
                add(measuredBefore(item))
                record(.removeFolder, url, nil, .skipped)
                return false
            }
            // A folder that cannot be read is not deleted blindly.
            guard let listed = try listing(of: url, sorted: false) else {
                add(measuredBefore(item))
                return false
            }
            if isTopLevel, !listed.items.isEmpty, try !mayDeleteNonEmpty(url) {
                add(measuredBefore(item))
                record(.removeFolder, url, nil, .skipped)
                return false
            }
            if listed.rejected > 0 { complete = false }
            if try !deleteChildren(of: listed.items, tree: tree ?? url, depth: depth + 1) { complete = false }
        }
        defer { add(Measure(items: 1)) }
        // Something inside could not be deleted, so the folder stays.
        guard complete else {
            return false
        }
        return try deleteEntry(url, item: item, isFolder: isFolder, tree: tree)
    }

    /// Removes one file, link or empty folder, after the questions about protected items.
    private func deleteEntry(_ url: URL, item: FileItem?, isFolder: Bool, tree: URL?) throws -> Bool {
        let verb: OperationRecord.Verb = isFolder ? .removeFolder : .delete
        if let item, !isFolder, try !mayTouch(item, for: .delete) {
            record(verb, url, nil, .skipped)
            return false
        }
        return try attempt(verb, at: url, target: nil) {
            if !isFolder { try self.flushBeforeRemoving(url, item) }
            let removed = try self.removing(item, at: url) { try self.remove(url, below: tree) }
            self.record(verb, url, nil, removed ? .done : .skipped)
            return removed
        }
    }

    /// A file that some plugin still holds changes for (an archive that is written after a
    /// delay) is brought up to date before it goes: otherwise the late writing would find
    /// its file gone, or put a file back that the user deleted.
    ///
    /// Files only.
    private func flushBeforeRemoving(_ url: URL, _ item: FileItem?) throws {
        guard let item, !item.isDirectory, !item.isSymlink else {
            return
        }
        try fileSystems.flushPendingWrites(to: url, cancellation: cancellation)
    }

    private func deleteLeaf(_ leaf: FileItem, tree: URL?) throws -> Bool {
        try checkCancelled()
        report { ["Deleting: \(self.display(leaf.url))"] }
        defer { add(Measure(items: 1)) }
        return try deleteEntry(leaf.url, item: leaf, isFolder: false, tree: tree)
    }

    /// The contents of a folder: its files first, then its subfolders one by one.
    ///
    /// False when something was kept.
    private func deleteChildren(of children: [FileItem], tree: URL, depth: Int) throws -> Bool {
        var complete = true
        let (folders, leaves) = (children.filter(\.isRealDirectory), children.filter { !$0.isRealDirectory })
        // The files that are going to ask a question come first, in name order, so that the
        // questions are asked as they always were; the listing itself is not sorted.
        let asking = Sorter.sorted(leaves.filter(mayAsk), byName: \.name)
        let quiet = leaves.filter { !mayAsk($0) }
        if let deletePool, quiet.count >= Self.parallelDeleteThreshold {
            if try !deleteLeaves(asking: asking, quiet: quiet, tree: tree, with: deletePool) { complete = false }
        } else {
            for leaf in asking + quiet where try autoreleasepool(invoking: { try !deleteLeaf(leaf, tree: tree) }) {
                complete = false
            }
        }
        for folder in folders
        where try autoreleasepool(invoking: {
            try !deleteTree(folder.url, item: folder, isTopLevel: false, tree: tree, depth: depth)
        }) {
            complete = false
        }
        return complete
    }

    /// Deletes files by the pool.
    ///
    /// A file that is going to ask a question (read-only, hidden) is done here, in the order given,
    /// while the workers delete the others; a question a worker meets later (a locked file) is
    /// asked under the same lock as any other. An Abort or Cancel in any of them stops the others,
    /// and the function returns only when the workers are done.
    private func deleteLeaves(asking: [FileItem], quiet: [FileItem], tree: URL, with pool: Pool) throws -> Bool {
        // What the workers found out, under a lock of its own. Unchecked `Sendable`: all state
        // is guarded by `lock`.
        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var kept = false
            var failure: (any Error)?

            deinit {
                // Nothing to release.
            }
        }
        let tally = Tally()
        let group = DispatchGroup()
        for leaf in quiet {
            if isStopping { break }
            pool.slots.wait()
            pool.start(in: group) {
                do {
                    if try !self.deleteLeaf(leaf, tree: tree) { tally.lock.withLock { tally.kept = true } }
                } catch {
                    // Abort or Cancel in a question a worker asked: the whole job ends. The error is
                    // kept before the others are stopped, so it is not the stop they meet that is told.
                    tally.lock.withLock { tally.failure = tally.failure ?? error }
                    self.halt()
                }
            }
        }
        // The workers are busy meanwhile with the files that ask nothing.
        var keptAsked = false
        do {
            for leaf in asking where try !deleteLeaf(leaf, tree: tree) {
                keptAsked = true
            }
        } catch {
            tally.lock.withLock { tally.failure = tally.failure ?? error }
            halt()
        }
        group.wait()
        return try tally.lock.withLock {
            if let failure = tally.failure { throw failure }
            if isStopping { throw Cancelled() }
            return !tally.kept && !keptAsked
        }
    }

    /// Whether the questions about protected items may come up for this file.
    private func mayAsk(_ item: FileItem) -> Bool {
        if options.ignoresProtection || item.isSymlink {
            return false
        }
        return (options.asksAboutReadOnly && item.permissions & 0o222 == 0)
            || (options.asksAboutHidden && item.isHidden)
    }

    private func mayDeleteNonEmpty(_ url: URL) throws -> Bool {
        guard options.asksAboutNonEmptyFolders else {
            return true
        }
        return try decisions.withLock {
            if deleteAllNonEmpty {
                return true
            }
            switch try delegateOrStop().job(self, confirmDeleteNonEmpty: url) {
            case .delete:
                return true

            case .all:
                deleteAllNonEmpty = true
                return true

            case .skip:
                return false

            case .cancel:
                throw Cancelled()
            }
        }
    }

    /// Runs a removal.
    ///
    /// When the system refuses because the item is locked, the user is asked, the item unlocked
    /// (the provider does that when it is made writable) and the removal tried once more. False:
    /// the user wants to keep the item.
    ///
    /// "Not permitted" has other reasons than a lock (a folder that only lets owners delete,
    /// a locked folder above): on a local disk only an item that really carries a lock is
    /// unlocked. A link is never unlocked this way, because the change of permissions would
    /// land on whatever it points to. And an item that could not be removed after all gets
    /// back the permissions and the lock it had.
    internal func removing(_ item: FileItem?, at url: URL, _ remove: () throws -> Void) throws -> Bool {
        do {
            try remove()
            return true
        } catch let error where Self.isRefusedAsLocked(error) {
            guard let item, !item.isSymlink, !FileIdentity.isSymlink(url), FileIdentity.mayBeLocked(url) else {
                throw error
            }
            if !options.ignoresProtection, try !confirm(.locked, .delete, item) {
                return false
            }
            let provider = try fileSystems.provider(for: url)
            let flags = FileIdentity.flags(of: url)
            try? provider.setAttributes(
                FileAttributes(permissions: item.permissions | 0o200),
                of: url,
                cancellation: cancellation
            )
            do {
                try remove()
                return true
            } catch {
                if item.permissions & 0o200 == 0 {
                    try? provider.setAttributes(
                        FileAttributes(permissions: item.permissions),
                        of: url,
                        cancellation: patience(with: provider)
                    )
                }
                if let flags { FileIdentity.restoreFlags(flags, of: url) }
                throw error
            }
        }
    }

    /// Deletes every source, to the Trash or for good; job thread.
    internal func runDelete(toTrash: Bool, _ result: inout JobResult) {
        do {
            for (slot, source) in sources.enumerated() {
                try checkCancelled()
                let deleted = try autoreleasepool { () throws -> Bool in
                    guard try hasSafeName(source, verb: toTrash ? .trash : .delete) else {
                        return false
                    }
                    return try toTrash
                        ? trash(source)
                        : deleteTree(source, item: topItem(slot, source), isTopLevel: true, tree: nil, depth: 0)
                }
                if deleted { result.completed.append(source) }
            }
        } catch {
            result.cancelled = true
            halt()
        }
    }
}
