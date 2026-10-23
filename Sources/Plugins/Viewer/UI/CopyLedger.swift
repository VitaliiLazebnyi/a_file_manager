import Foundation

/// The copies `TemporaryCopies` keeps and who shows them: the bookkeeping without the files.
///
/// A plain value; its owner guards it with its lock.
internal struct CopyLedger {
    /// One copy: its folder and file, who shows it, when it was last used, and its size.
    internal struct Copy {
        /// The folder of its own the copy is in.
        internal var folder: URL
        /// The copy.
        internal var file: URL
        /// The panes that show it; none for an idle copy.
        internal var owners: Set<ObjectIdentifier>
        /// The tick of the ledger's clock when it was last asked for.
        internal var lastUsed: Int
        /// Its size in bytes.
        internal var size: Int64
    }

    /// What a copy that is begun remembers: the count of `removeAll` and of its owner's releases then.
    internal struct Start {
        /// How often the copies were all removed.
        internal var epoch: Int
        /// How often the owner had let go of its copies.
        internal var release: Int
    }

    private var copies: [String: Copy] = [:]
    private var clock = 0
    /// How often `removeAll` ran: a copy that was begun before one is not registered.
    private var epoch = 0
    /// How often each owner released its copies: a copy begun before is not kept for that owner.
    private var releases: [ObjectIdentifier: Int] = [:]

    /// The counts a copy for `owner` begins with.
    internal func start(for owner: ObjectIdentifier) -> Start {
        Start(epoch: epoch, release: releases[owner] ?? 0)
    }

    /// Whether `removeAll` ran since `start`.
    internal func wasCleared(since start: Start) -> Bool {
        start.epoch != epoch
    }

    /// The copy known by `key`, now shown by `owner` too; nil when there is none.
    internal mutating func use(_ key: String, by owner: ObjectIdentifier) -> URL? {
        guard var copy = copies[key] else {
            return nil
        }
        clock += 1
        copy.owners.insert(owner)
        copy.lastUsed = clock
        copies[key] = copy
        return copy.file
    }

    /// Notes a new copy; it is shown by its owner unless the owner let go of its copies since `start`.
    internal mutating func add(_ copy: Copy, key: String, owner: ObjectIdentifier, start: Start) {
        clock += 1
        var added = copy
        // The owner let go of its copies while this one was made: it is kept like the idle ones.
        added.owners = (releases[owner] ?? 0) == start.release ? [owner] : []
        added.lastUsed = clock
        copies[key] = added
    }

    /// The pane `owner` shows something else: its copies become idle.
    internal mutating func release(owner: ObjectIdentifier) {
        releases[owner, default: 0] += 1
        for key in copies.keys where copies[key]?.owners.contains(owner) == true { copies[key]?.owners.remove(owner) }
    }

    /// Forgets every copy; the copies begun before are not added.
    internal mutating func removeAll() {
        copies = [:]
        epoch += 1
    }

    /// Forgets the idle copies beyond `count` of them or `bytes` together, the least recently used first; their
    /// folders, to be deleted.
    internal mutating func evictIdle(keeping count: Int, bytes: Int64) -> [URL] {
        let idle = copies.filter(\.value.owners.isEmpty).sorted { $0.value.lastUsed > $1.value.lastUsed }
        var doomed: [URL] = []
        var kept = 0
        var keptBytes: Int64 = 0
        for (key, copy) in idle {
            if kept < count, keptBytes + copy.size <= bytes {
                kept += 1
                keptBytes += copy.size
            } else {
                copies[key] = nil
                doomed.append(copy.folder)
            }
        }
        return doomed
    }
}
