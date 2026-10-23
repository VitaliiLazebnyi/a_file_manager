import AFMKernel
import Foundation

/// Applies an `AttributeChange` to items and, with `recurse`, to everything inside them.
///
/// **Threading.** `run` blocks and is meant for a job's thread. The files of a folder and its
/// subfolders are changed on all cores at once, by the kernel's pool (`Parallel.map`): calls
/// from inside calls share its threads, and a piece that waits for a disk or a server does
/// not take a thread away from the system's queues. The outcome is the only state the
/// threads share and is guarded by a lock. Date and permissions go through the item's file-system
/// provider, so they work wherever the provider supports them; flags and owners are POSIX
/// calls and exist for `file:` URLs only.
///
/// `outcome`, `ownerID` and `groupID` are guarded by `lock`; everything else is fixed in `init`.
internal final class AttributeJob: @unchecked Sendable {
    /// What a run did.
    internal struct Outcome {
        /// How many items were changed.
        internal var changed = 0
        /// How many items could not be changed.
        internal var failed = 0
        /// The first failures, ready to show: path and reason.
        internal var failures: [String] = []
        /// Whether the run was stopped before it got through every item.
        internal var cancelled = false
    }

    private struct LockedItem: LocalizedError {
        var errorDescription: String? {
            "The item is locked. Its permissions were not changed; choose Locked: Clear to unlock it."
        }
    }

    private struct InvalidDate: LocalizedError {
        var errorDescription: String? { "The new date does not exist in the calendar." }
    }

    private let change: AttributeChange
    private let fileSystems: FileSystemRegistry
    private let cancellation: CancellationFlag
    private let meter: ProgressMeter?
    private let now = Date()
    private let lock = NSLock()
    private var outcome = Outcome()
    /// Looked up once, on the job's thread, before the parallel work starts (under `lock`).
    private var ownerID: uid_t?
    private var groupID: gid_t?

    /// A job that applies `change` through `fileSystems`, stops when `cancellation` is set and
    /// counts every item it is done with on `meter` (nil counts nothing).
    internal init(
        change: AttributeChange,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag,
        meter: ProgressMeter?
    ) {
        self.change = change
        self.fileSystems = fileSystems
        self.cancellation = cancellation
        self.meter = meter
    }

    /// Changes `items`, and with `recurse` everything inside them, and says how it went; blocks.
    ///
    /// An owner or a group that does not exist changes nothing and fails every item.
    internal func run(_ items: [FileItem]) -> Outcome {
        if let owner = change.owner {
            guard let id = LocalInfo.userID(owner) else {
                return Outcome(failed: items.count, failures: ["There is no user called \(owner)."])
            }
            lock.withLock { ownerID = id }
        }
        if let group = change.group {
            guard let id = LocalInfo.groupID(group) else {
                return Outcome(failed: items.count, failures: ["There is no group called \(group)."])
            }
            lock.withLock { groupID = id }
        }
        each(items) { self.process($0) }
        lock.lock()
        defer { lock.unlock() }
        outcome.cancelled = cancellation.isCancelled
        return outcome
    }

    private func each(_ items: [FileItem], serialBelow threshold: Int = 2, _ body: @Sendable (FileItem) -> Void) {
        guard items.count >= threshold, items.count > 1 else {
            for item in items {
                body(item)
            }
            return
        }
        _ = Parallel.map(items, serialBelow: threshold) { body($0) }
    }

    private func process(_ item: FileItem) {
        guard !cancellation.isCancelled else {
            return
        }
        guard change.recurse, item.isRealDirectory else {
            apply(to: item)
            return
        }
        // The contents come first and the folder last, so that taking a folder's own
        // permissions away does not lock the job out of it. A folder that cannot be read
        // yet is changed first: the change may be what opens it.
        // Listed with the job's flag, so that a server that has stopped answering does not
        // hold the job (and a thread of the pool) after Cancel.
        let list = {
            try? self.fileSystems.provider(for: item.url)
                .list(
                    item.url,
                    showHidden: true,
                    cancellation: self.cancellation
                )
        }
        var children = list()
        // A listing that ended because of the cancel says nothing about the folder.
        guard !cancellation.isCancelled else {
            return
        }
        let changedFirst = children == nil
        if changedFirst {
            apply(to: item)
            children = list()
        }
        guard !cancellation.isCancelled else {
            return
        }
        let contents = children ?? []
        each(contents.filter { !$0.isRealDirectory }, serialBelow: 64) { self.apply(to: $0) }
        each(contents.filter(\.isRealDirectory)) { self.process($0) }
        if !changedFirst { apply(to: item) }
    }

    private func apply(to item: FileItem) {
        guard !cancellation.isCancelled else {
            return
        }
        do {
            try change(item)
            lock.lock()
            outcome.changed += 1
            lock.unlock()
        } catch {
            // What ended because the job was stopped did not fail.
            guard !cancellation.isCancelled else {
                return
            }
            lock.lock()
            outcome.failed += 1
            if outcome.failures.count < 20 {
                outcome.failures.append("\(fileSystems.displayPath(item.url)): \(error.localizedDescription)")
            }
            lock.unlock()
        }
        meter?.add(1, at: fileSystems.displayPath(item.url))
    }

    private func change(_ listed: FileItem) throws {
        let url = listed.url
        let provider = try fileSystems.provider(for: url)
        if change.needsLocalFileSystem, !url.isFileURL {
            throw FileSystemError.notSupported("Changing flags and owners")
        }
        // A locked item takes no other change, so the lock comes off first and goes on last.
        if change.locked == .clear { try LocalInfo.setFlag(UInt32(UF_IMMUTABLE), false, of: url) }
        try changeModeAndDate(of: listed, through: provider)
        let (owner, group) = lock.withLock { (ownerID, groupID) }
        if owner != nil || group != nil { try LocalInfo.setOwner(owner, group: group, of: url) }
        if change.hidden != .keep { try LocalInfo.setFlag(UInt32(UF_HIDDEN), change.hidden == .set, of: url) }
        if change.locked == .set { try LocalInfo.setFlag(UInt32(UF_IMMUTABLE), true, of: url) }
    }

    /// Writes the new permissions and date through the provider; a link is left alone.
    private func changeModeAndDate(of listed: FileItem, through provider: any FileSystemProvider) throws {
        let url = listed.url
        // A change that starts from what the item has (`u+x`, a date with parts left as they
        // are) starts from what it has now, not from what a listing said a while ago.
        let timestamp = change.timestamp.flatMap { $0.changesNothing ? nil : $0 }
        let needsCurrent = change.permissions.needsCurrentMode || (timestamp.map { !$0.usesCurrentTime } ?? false)
        let item = needsCurrent ? (provider.item(at: url, cancellation: cancellation) ?? listed) : listed
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        // Permissions and dates of a link would land on the item it points to. The disk is
        // asked once more: what was a file when the folder was listed may be a link by now.
        guard !item.isSymlink, !LocalInfo.isSymlink(url) else {
            return
        }
        var attributes = FileAttributes()
        if change.permissions != .unchanged {
            attributes.permissions = change.permissions.applied(to: item.permissions, isDirectory: item.isDirectory)
        }
        if let timestamp {
            guard let date = timestamp.applied(to: item.modified, now: now, calendar: .current) else {
                throw InvalidDate()
            }
            attributes.modified = date
        }
        // The file system unlocks an item that is made writable. With the lock left
        // "unchanged" that would be a change nobody asked for: a locked item is reported.
        if attributes.permissions != nil, change.locked == .keep, LocalInfo.details(url)?.isLocked == true {
            throw LockedItem()
        }
        if attributes.permissions != nil || attributes.modified != nil {
            try provider.setAttributes(attributes, of: url, cancellation: cancellation)
        }
    }

    deinit {
        // Nothing to release.
    }
}
