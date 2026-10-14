import AFMContracts
import AFMKernel
import Foundation

/// What Synchronize is about to do, worked out from the rows and their actions
/// (spec 09 › The "Synchronize" dialog and the run). A value without behaviour: the dialog
/// shows its counts, the executor carries it out.
public struct SyncPlan: Equatable {
    public struct Copy: Equatable {
        public let source: URL
        public var target: URL
        /// The path below the start directories, for sending the copy to another folder.
        public let relativePath: String
        public let isDirectory: Bool
        public let size: Int64
        public let modified: Date
        /// The date the copy is to carry: the source's, moved by the time difference of the two
        /// sides (`SyncOptions.timeOffsetHours`) so that the pair compares equal next time.
        public let targetModified: Date
        public let permissions: UInt16
    }

    public struct Deletion: Equatable {
        public let url: URL
        public let isDirectory: Bool
    }

    public var toRight: [Copy] = []
    public var toLeft: [Copy] = []
    public var deleteLeft: [Deletion] = []
    public var deleteRight: [Deletion] = []

    /// Plans the given rows; the caller passes the visible ones, because only those are
    /// processed (spec 09 › Window and workflow). `timeOffsetHours` is the time difference that
    /// the comparison allowed for (the dates of the right side plus this are the left's).
    public init(rows: [SyncRow], timeOffsetHours: Int = 0) {
        let offset = Double(timeOffsetHours) * 3_600
        for row in rows where row.accepts(row.action) {
            func copy(_ item: FileItem, to target: URL, shift: Double) -> Copy {
                Copy(
                    source: item.url, target: target, relativePath: row.relativePath, isDirectory: row.isDirectory,
                    size: row.isDirectory ? 0 : item.size, modified: item.modified,
                    targetModified: item.modified.addingTimeInterval(shift),
                    permissions: item.permissions)
            }
            func deletion(_ item: FileItem, into list: inout [Deletion]) {
                list.append(Deletion(url: item.url, isDirectory: row.isDirectory))
            }
            switch row.action {
            case .none: break

            // Left plus nothing is right plus the offset: a copy to the right is dated back, one to the left forward.
            case .copyToRight: if let left = row.left { toRight.append(copy(left, to: row.rightURL, shift: -offset)) }
            case .copyToLeft: if let right = row.right { toLeft.append(copy(right, to: row.leftURL, shift: offset)) }
            case .deleteLeft: if let left = row.left { deletion(left, into: &deleteLeft) }
            case .deleteRight: if let right = row.right { deletion(right, into: &deleteRight) }

            case .deleteBoth:
                if let left = row.left { deletion(left, into: &deleteLeft) }
                if let right = row.right { deletion(right, into: &deleteRight) }
            }
        }
    }

    public var isEmpty: Bool { toRight.isEmpty && toLeft.isEmpty && deleteLeft.isEmpty && deleteRight.isEmpty }

    /// Sends the copies of one direction to another folder, keeping their relative paths.
    public mutating func retarget(toRight: Bool, root: URL) {
        func moved(_ copies: [Copy]) -> [Copy] {
            // The path is cut at its `/` bytes and nowhere else (`PathSafety`); a copy whose
            // path is not made of plain names (none is, as the comparison makes them) has no
            // place below the new folder and is left out.
            copies.compactMap { copy in
                guard let names = PathSafety.components(ofRelativePath: copy.relativePath) else { return nil }
                var copy = copy
                copy.target = names.reduce(root) { $0.appending(name: $1) }
                return copy
            }
        }
        if toRight { self.toRight = moved(self.toRight) } else { self.toLeft = moved(self.toLeft) }
    }

    /// `Copy 16 files, total size: 6,363,930 bytes`
    public static func describe(_ copies: [Copy]) -> String {
        let files = copies.filter { !$0.isDirectory }
        let folders = copies.count - files.count
        return
            "Copy \(files.count) files, total size: \(Format.bytes(files.reduce(Int64(0)) { $0.addingSaturated($1.size) })) bytes"
            + (folders > 0 ? ", create \(folders) directories" : "")
    }
}

public struct SyncRunOptions {
    public var copyToRight = true
    public var copyToLeft = true
    public var deleteLeft = true
    public var deleteRight = true
    /// Ask before a copy replaces an existing file.
    public var confirmOverwrites = true
    /// Deleted items go to the Trash where the file system has one.
    public var useTrash = true
    /// Asymmetric only: afterwards every empty directory below this one is deleted
    /// ("Right: Delete all empty directories").
    public var removeEmptyDirectoriesBelow: URL?
    /// When the target cannot keep a copied file's date, the source file gets the target's
    /// date instead, so the pair compares equal next time (spec 09 › Synchronizing with FTP).
    public var mayChangeSourceDates = true
    /// Dates this close need no correcting.
    public var toleranceSeconds = 3

    public init() {}
}

public enum SyncOverwriteAnswer {
    case overwrite, overwriteAll, skip, skipAll, cancel
}

public enum SyncErrorAnswer {
    case retry, skip, skipAll, cancel
}

public struct SyncOutcome {
    public var copied = 0
    public var deleted = 0
    public var skipped = 0
    public var errors: [String] = []
    public var wasCancelled = false
    /// What was written to a file system that keeps writes back could not be made durable: the
    /// run ended there, and nothing was deleted.
    public var commitFailed = false
    /// The folders whose contents changed, for refreshing the panels.
    public var changedDirectories: [URL] = []
}

/// Carries out a plan through the file-system providers, so it works between any two file
/// systems (spec 09 › The "Synchronize" dialog and the run). Right-to-left copies run first,
/// then left-to-right, then the deletions.
///
/// **Threading.** `run` blocks and belongs on a job's thread; the three callbacks are called
/// on that thread and may block while the user decides. `cancellation` may be set from any
/// thread. A file that replaces another is written next to it under a temporary name and
/// moved over it, so an interrupted copy never leaves a half-written target.
public final class SyncExecutor {
    private let plan: SyncPlan
    private let options: SyncRunOptions
    private let fileSystems: FileSystemRegistry
    private let cancellation: CancellationFlag

    /// Asked when a copy would replace `target`, if overwrites are to be confirmed.
    public var onOverwrite: (_ target: FileItem, _ copy: SyncPlan.Copy) -> SyncOverwriteAnswer = { _, _ in .overwrite }
    public var onError: (_ url: URL, _ error: Error) -> SyncErrorAnswer = { _, _ in .skip }
    public var onProgress: (JobProgress) -> Void = { _ in }

    private var outcome = SyncOutcome()
    private var overwriteAll = false
    private var skipAllExisting = false
    private var skipAllErrors = false
    private var itemsDone = 0
    private var itemsTotal = 0
    private var bytesDone: Int64 = 0
    private var bytesTotal: Int64 = 0
    private var changed: [String: URL] = [:]
    private var knownDirectories: Set<String> = []
    private var directoryDates: [(url: URL, modified: Date, source: URL)] = []
    /// The roots of the file systems with deferred writes that something was written to, by
    /// location, still to be committed.
    private var uncommitted: [String: (provider: FileSystemProvider, root: URL)] = [:]
    /// What the progress window says about the item being worked on.
    private var currentLines: [String] = []

    private struct Cancelled: Error {}

    public init(
        plan: SyncPlan, options: SyncRunOptions, fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag()
    ) {
        self.plan = plan
        self.options = options
        self.fileSystems = fileSystems
        self.cancellation = cancellation
    }

    public func run() -> SyncOutcome {
        let toLeft = options.copyToLeft ? plan.toLeft : []
        let toRight = options.copyToRight ? plan.toRight : []
        let deletions = (options.deleteLeft ? plan.deleteLeft : []) + (options.deleteRight ? plan.deleteRight : [])
        itemsTotal = toLeft.count + toRight.count + deletions.count
        bytesTotal = (toLeft + toRight).reduce(Int64(0)) { $0.addingSaturated($1.size) }

        let passes: [(String, [SyncPlan.Copy])] = [("Right -> Left", toLeft), ("Left -> Right", toRight)]
        run: do {
            for (caption, copies) in passes {
                for (index, copy) in copies.enumerated() {
                    guard
                        step(
                            copy.target,
                            lines: [
                                "\(caption)  (\(index + 1) / \(copies.count))",
                                "From: " + fileSystems.displayPath(copy.source),
                                "To: " + fileSystems.displayPath(copy.target)
                            ], { try self.perform(copy) })
                    else { break run }
                    bytesDone = bytesDone.addingSaturated(copy.size)
                }
            }
            // What was written must be where it belongs before anything is deleted.
            if !deletions.isEmpty, !commitWrites() { break run }
            // Files go before the folders that hold them, the deepest folders first.
            let ordered =
                deletions.filter { !$0.isDirectory }
                + deletions.filter(\.isDirectory).sorted { $0.url.pathComponents.count > $1.url.pathComponents.count }
            for deletion in ordered {
                guard
                    step(
                        deletion.url, lines: ["Delete: " + fileSystems.displayPath(deletion.url)],
                        { try self.perform(deletion) })
                else { break run }
            }
            if let root = options.removeEmptyDirectoriesBelow { removeEmptyDirectories(below: root, isRoot: true) }
        }
        // Folders get their dates last: copying into a folder changes its date. What they
        // carry besides (tags, flags, a lock) comes after that, as a lock would stop the date.
        for entry in directoryDates {
            guard let provider = try? fileSystems.provider(for: entry.url) else { continue }
            try? provider.setAttributes(FileAttributes(modified: entry.modified), of: entry.url)
            try? provider.copyMetadata(from: entry.source, to: entry.url)
        }
        _ = commitWrites()
        outcome.wasCancelled = outcome.wasCancelled || cancellation.isCancelled
        outcome.changedDirectories = Array(changed.values)
        return outcome
    }

    /// Does one item with the user's say on failures. Returns false when the run is to stop.
    private func step(_ url: URL, lines: [String], _ work: () throws -> Bool) -> Bool {
        defer { itemsDone += 1 }
        while true {
            if cancellation.isCancelled { return false }
            currentLines = lines
            onProgress(
                JobProgress(
                    lines: lines, itemsDone: itemsDone, itemsTotal: itemsTotal, bytesDone: bytesDone,
                    bytesTotal: bytesTotal))
            do {
                if try work() {
                    let folder = url.deletingLastPathComponent()
                    changed[folder.locationKey] = folder
                } else {
                    outcome.skipped += 1
                }
                return true
            } catch is Cancelled {
                outcome.wasCancelled = true
                return false
            } catch {
                outcome.errors.append("\(fileSystems.displayPath(url)): \(error.localizedDescription)")
                outcome.skipped += 1
                if skipAllErrors { return true }
                switch onError(url, error) {
                case .retry:
                    outcome.errors.removeLast()
                    outcome.skipped -= 1

                case .skip: return true

                case .skipAll:
                    skipAllErrors = true
                    return true

                case .cancel:
                    outcome.wasCancelled = true
                    return false
                }
            }
        }
    }

    // MARK: Copying

    /// Returns false when the item was left alone on the user's wish.
    private func perform(_ copy: SyncPlan.Copy) throws -> Bool {
        let targetSystem = try fileSystems.provider(for: copy.target)
        if copy.isDirectory {
            try targetSystem.createDirectory(at: copy.target)
            directoryDates.append((copy.target, copy.targetModified, copy.source))
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
            if existing.isDirectory { throw FileSystemError.alreadyExists(fileSystems.displayPath(copy.target)) }
            if skipAllExisting { return false }
            if options.confirmOverwrites, !overwriteAll {
                switch onOverwrite(existing, copy) {
                case .overwrite: break
                case .overwriteAll: overwriteAll = true
                case .skip: return false

                case .skipAll:
                    skipAllExisting = true
                    return false

                case .cancel: throw Cancelled()
                }
            }
        }
        // A file that replaces another, and any file on a file system that keeps writes back (an
        // archive): written under a temporary name and renamed, so that what is under the final name is
        // always complete and, on the latter, is found by the commit that makes it durable.
        let defers = targetSystem.capabilities(for: copy.target).contains(.deferredWrites)
        guard existing != nil || defers else {
            try transfer(copy, to: copy.target, in: targetSystem)
            adjustDate(of: copy, in: targetSystem)
            noteWrite(to: copy.target, in: targetSystem)
            outcome.copied += 1
            return true
        }
        let temporary = folder.appending(name: ".\(copy.target.lastPathComponent).afm-sync")
        try? targetSystem.remove(temporary)
        // The copy and the move are one unit: whatever stops them (a failure, the cancel after the
        // copy was complete) must not leave the temporary behind.
        do {
            try transfer(copy, to: temporary, in: targetSystem)
            if cancellation.isCancelled { throw Cancelled() }
            do {
                try targetSystem.move(temporary, to: copy.target, replacing: true)
            } catch  where existing != nil {
                // A file system that cannot replace in one step: the old file steps aside, the
                // new one takes its place, and the old one comes back if that fails. The aside
                // name is free: a leftover from an earlier failure may be the only copy of a file.
                let aside = freeName(folder, ".\(copy.target.lastPathComponent).afm-old", in: targetSystem)
                try targetSystem.move(copy.target, to: aside, replacing: false)
                do {
                    try targetSystem.move(temporary, to: copy.target, replacing: false)
                } catch {
                    do {
                        try targetSystem.move(aside, to: copy.target, replacing: false)
                    } catch {
                        // Neither is under the name; the old file is not deleted, and the user is told where it is.
                        try? targetSystem.remove(temporary)
                        throw NSError(
                            domain: "AFMSync", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "The old file could not be put back and is kept as \(fileSystems.displayPath(aside))."
                            ])
                    }
                    throw error
                }
                try? targetSystem.remove(aside)
            }
        } catch {
            try? targetSystem.remove(temporary)
            throw error
        }
        adjustDate(of: copy, in: targetSystem)
        noteWrite(to: copy.target, in: targetSystem)
        outcome.copied += 1
        return true
    }

    /// `base`, or `base-2`, `base-3`, … : the first name in `folder` that nothing has.
    private func freeName(_ folder: URL, _ base: String, in provider: FileSystemProvider) -> URL {
        var candidate = folder.appending(name: base)
        var number = 2
        while provider.item(at: candidate) != nil {
            candidate = folder.appending(name: "\(base)-\(number)")
            number += 1
        }
        return candidate
    }

    /// Remembers that something was written to a file system that keeps writes back.
    private func noteWrite(to url: URL, in provider: FileSystemProvider) {
        guard provider.capabilities(for: url).contains(.deferredWrites) else { return }
        let root = provider.root(of: url)
        uncommitted[root.locationKey] = (provider, root)
    }

    /// Makes what the copies wrote durable. False when that failed: nothing below the root
    /// can be relied on, so the run ends as failed and deletes nothing.
    private func commitWrites() -> Bool {
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
    /// otherwise by reading from one and writing to the other. Nothing stays behind on failure.
    private func transfer(_ copy: SyncPlan.Copy, to destination: URL, in targetSystem: FileSystemProvider) throws {
        let sourceSystem = try fileSystems.provider(for: copy.source)
        let report = { (bytes: Int64) in
            self.onProgress(
                JobProgress(
                    lines: self.currentLines, itemsDone: self.itemsDone, itemsTotal: self.itemsTotal,
                    bytesDone: self.bytesDone.addingSaturated(bytes), bytesTotal: self.bytesTotal))
        }
        if sourceSystem === targetSystem {
            do {
                try sourceSystem.copy(copy.source, to: destination) { bytes in
                    report(bytes)
                    return !self.cancellation.isCancelled
                }
                if cancellation.isCancelled { throw Cancelled() }
                return
            } catch FileSystemError.crossesVolumes {
                // Falls through to streaming.
            } catch {
                if cancellation.isCancelled { throw Cancelled() }
                throw error
            }
        }
        let reader = try sourceSystem.read(copy.source, cancellation: cancellation)
        defer { reader.close() }
        let writer = try targetSystem.write(destination, cancellation: cancellation)
        // A read or write blocked on a server ends as soon as the run is cancelled.
        let tokens = [cancellation.interrupting(reader), cancellation.interrupting(writer)]
        defer { withExtendedLifetime(tokens) {} }
        var written: Int64 = 0
        do {
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else { return false }
                if cancellation.isCancelled { throw Cancelled() }
                try writer.write(block)
                written += Int64(block.count)
                report(written)
                return true
            }) {}
            try writer.close(attributes: FileAttributes(modified: copy.targetModified, permissions: copy.permissions))
            // What a copy inside one file system takes along (tags, flags, extended attributes) is asked of the target's
            // file system between two; a file system that cannot do it does not stop the copy.
            try? targetSystem.copyMetadata(from: copy.source, to: destination)
            // A file that came from elsewhere keeps saying so; a mark that cannot be put on does not stop the copy.
            if let mark = sourceSystem.quarantine(of: copy.source) {
                try? targetSystem.setQuarantine(mark, of: destination)
            }
        } catch {
            // Closed before the file is removed, whatever stopped the copy.
            try? writer.close(attributes: FileAttributes())
            try? targetSystem.remove(destination)
            if cancellation.isCancelled { throw Cancelled() }
            throw error
        }
    }

    /// A target that did not keep the date it is to have would look different again at the next
    /// comparison. The target's date is set; where that is not possible, the source takes
    /// the target's date (spec 09 › Synchronizing with FTP, the timestamp problem), moved by the
    /// same amount the target's was.
    private func adjustDate(of copy: SyncPlan.Copy, in targetSystem: FileSystemProvider) {
        guard let arrived = targetSystem.item(at: copy.target), !arrived.isSymlink,
            abs(arrived.modified.timeIntervalSince(copy.targetModified)) > Double(options.toleranceSeconds)
        else { return }
        do {
            try targetSystem.setAttributes(FileAttributes(modified: copy.targetModified), of: copy.target)
        } catch {
            guard options.mayChangeSourceDates, let sourceSystem = try? fileSystems.provider(for: copy.source),
                sourceSystem.item(at: copy.source)?.isSymlink == false
            else { return }
            let shift = copy.modified.timeIntervalSince(copy.targetModified)
            try? sourceSystem.setAttributes(
                FileAttributes(modified: arrived.modified.addingTimeInterval(shift)), of: copy.source)
        }
    }

    // MARK: Deleting

    private func perform(_ deletion: SyncPlan.Deletion) throws -> Bool {
        let fileSystem = try fileSystems.provider(for: deletion.url)
        try fileSystems.flushPendingWrites(to: deletion.url, cancellation: cancellation)
        // A folder that still holds something (a file the user kept) stays.
        if deletion.isDirectory {
            let contents = try fileSystem.list(deletion.url, showHidden: true, cancellation: cancellation)
            // A listing that the cancel cut short is not an empty folder.
            if cancellation.isCancelled { throw Cancelled() }
            if !contents.isEmpty { return false }
        }
        try remove(deletion.url, in: fileSystem)
        outcome.deleted += 1
        return true
    }

    private func remove(_ url: URL, in fileSystem: FileSystemProvider) throws {
        if options.useTrash, fileSystem.capabilities(for: url).contains(.trash) {
            try fileSystem.trash(url)
        } else {
            try fileSystem.remove(url)
        }
    }

    /// Deletes the empty folders of a tree from the bottom up; returns whether `directory`
    /// itself is empty afterwards. Failures are ignored: the folder simply stays.
    @discardableResult
    private func removeEmptyDirectories(below directory: URL, isRoot: Bool = false) -> Bool {
        guard !cancellation.isCancelled, let fileSystem = try? fileSystems.provider(for: directory),
            let items = try? fileSystem.list(directory, showHidden: true, cancellation: cancellation),
            !cancellation.isCancelled
        else { return false }
        var isEmpty = true
        for item in items {
            guard item.isRealDirectory, removeEmptyDirectories(below: item.url) else {
                isEmpty = false
                continue
            }
            if (try? remove(item.url, in: fileSystem)) != nil {
                outcome.deleted += 1
                changed[directory.locationKey] = directory
            } else {
                isEmpty = false
            }
        }
        return isEmpty && !isRoot
    }
}
