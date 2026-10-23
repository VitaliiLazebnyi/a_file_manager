import AFMKernel
import Foundation

/// What is known about single entries from the listings read a moment ago, so that the many
/// questions a copy job asks about its targets do not each travel to the server.
///
/// A listing is forgotten after a few seconds. What this program itself changes in a directory (a
/// file written, a folder made or removed, a rename) is entered into the listing at once, so the
/// next question about the directory is still answered from it; a change that cannot be entered
/// exactly makes the directory forgotten. Safe from any thread.
///
/// A listing that was under way while the directory changed would bring the old state back
/// when it is stored. Changes are therefore also noted for a while in a journal, and a
/// listing that finishes is brought up to date with the changes made since it started.
///
/// All state is guarded by `lock`.
internal final class EntryCache: @unchecked Sendable {
    /// A listing as it was read.
    private struct Directory {
        /// When it was read; it is forgotten `lifetime` later.
        let read: Date
        /// Whether the hidden entries were asked for; without them, a dot name is not known to be absent.
        let includesHidden: Bool
        /// The entries by name, as changed since.
        var entries: [String: RemoteEntry]
    }

    /// One change of a directory.
    ///
    /// No name: everything about the directory is unknown.
    private struct Change {
        /// When it was made.
        let time: Date
        /// The name that changed; nil when the whole directory is unknown.
        let name: String?
        /// Nil: the name is gone.
        let entry: RemoteEntry?
    }

    /// What a remembered listing says about a name.
    internal enum Answer {
        /// Not there. `hasNameAlike`: the listing holds a name that a server may take for this
        /// one although it is spelled differently (in another case, or composed differently).
        case absent(hasNameAlike: Bool)
        /// The entry, as listed and changed since.
        case entry(RemoteEntry)
        /// No fresh listing, or one without the hidden entries for a dot name: the server must be asked.
        case unknown
    }

    /// How long a listing is believed.
    private static let lifetime: TimeInterval = 10
    /// How many listings are kept; when there are more, all are forgotten.
    private static let capacity = 64
    /// How long a change stays in the journal.
    private static let journalLifetime: TimeInterval = 300
    /// How many changes of one directory the journal holds; more make the directory unknown.
    private static let journalLimit = 1_024

    /// The clock: the system's, or a test's.
    internal let now: @Sendable () -> Date
    /// Guards `directories` and `journal`.
    private let lock = NSLock()
    /// The fresh listings, by location.
    private var directories: [String: Directory] = [:]
    /// The recent changes, by the location of their directory, oldest first.
    private var journal: [String: [Change]] = [:]

    /// An empty cache whose listings age by `now`.
    internal init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// Stores a complete listing that was started at `startedAt`.
    internal func store(_ entries: [RemoteEntry], for directory: URL, includesHidden: Bool, startedAt: Date) {
        var byName = Dictionary(entries.map { ($0.name, $0) }) { first, _ in first }
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        for change in journal[key] ?? [] where change.time >= startedAt {
            // Something about the directory is not known: this listing may be out of date.
            guard let name = change.name else {
                return
            }
            byName[name] = change.entry
        }
        if directories.count >= Self.capacity { directories.removeAll() }
        directories[key] = Directory(read: now(), includesHidden: includesHidden, entries: byName)
    }

    /// What the listing of `directory` says about `name`; whether a name alike is there is
    /// looked for only `lookingForAlike` (it costs a pass over the listing).
    internal func lookUp(_ name: String, in directory: URL, lookingForAlike: Bool) -> Answer {
        lock.lock()
        defer { lock.unlock() }
        guard let known = fresh(directory.locationKey) else {
            return .unknown
        }
        if let entry = known.entries[name] {
            return .entry(entry)
        }
        guard known.includesHidden || !name.hasPrefix(".") else {
            return .unknown
        }
        let alike =
            lookingForAlike
            && known.entries.keys.contains { listed in
                listed.compare(name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
                    == .orderedSame
            }
        return .absent(hasNameAlike: alike)
    }

    /// Changes what is known of an entry, when it is known; nothing else happens.
    ///
    /// For news that arrive on their own (a link resolved in the background): they must not make a
    /// listing be forgotten that they do not concern.
    internal func updateIfKnown(_ name: String, in directory: URL, _ change: (inout RemoteEntry) -> Void) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        guard fresh(key) != nil, var entry = directories[key]?.entries[name] else {
            return
        }
        change(&entry)
        note(key, name: name, entry: entry)
        directories[key]?.entries[name] = entry
    }

    /// The listing of a directory unless it is too old.
    ///
    /// Called with the lock held.
    private func fresh(_ key: String) -> Directory? {
        guard let known = directories[key] else {
            return nil
        }
        // Too old: forgotten.
        if now().timeIntervalSince(known.read) >= Self.lifetime {
            directories[key] = nil
            return nil
        }
        return known
    }

    /// Enters a change of the directory `key` into the journal, and lets the old changes go.
    ///
    /// Called with the lock held.
    private func note(_ key: String, name: String?, entry: RemoteEntry?) {
        let moment = now()
        var changes = journal[key] ?? []
        let cutoff = moment.addingTimeInterval(-Self.journalLifetime)
        if let first = changes.firstIndex(where: { $0.time >= cutoff }), first > 0 { changes.removeFirst(first) }
        if changes.count >= Self.journalLimit { changes = [Change(time: moment, name: nil, entry: nil)] }
        changes.append(Change(time: moment, name: name, entry: entry))
        journal[key] = changes
        if journal.count > 256 { journal = journal.filter { $0.value.contains { change in change.time >= cutoff } } }
    }

    /// A name that now exists in the directory (a file just created, a folder just made).
    internal func insert(_ entry: RemoteEntry, in directory: URL) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        note(key, name: entry.name, entry: entry)
        if fresh(key) != nil { directories[key]?.entries[entry.name] = entry }
    }

    /// A name that is gone from the directory.
    internal func remove(_ name: String, from directory: URL) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        note(key, name: name, entry: nil)
        if fresh(key) != nil { directories[key]?.entries[name] = nil }
    }

    /// Changes what is known of an entry; the directory is forgotten when the entry is not known.
    internal func update(_ name: String, in directory: URL, _ change: (inout RemoteEntry) -> Void) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        if fresh(key) != nil, var entry = directories[key]?.entries[name] {
            change(&entry)
            note(key, name: name, entry: entry)
            directories[key]?.entries[name] = entry
        } else {
            note(key, name: nil, entry: nil)
            directories[key] = nil
        }
    }

    /// An entry that went from one directory to another, or to another name.
    internal func move(_ name: String, from source: URL, to destination: URL, as newName: String) {
        let (origin, target) = (source.locationKey, destination.locationKey)
        lock.lock()
        defer { lock.unlock() }
        guard fresh(origin) != nil, var entry = directories[origin]?.entries[name] else {
            // Nothing is known of what moved, so nothing of where it arrived.
            note(origin, name: nil, entry: nil)
            note(target, name: nil, entry: nil)
            directories[origin] = nil
            directories[target] = nil
            return
        }
        note(origin, name: name, entry: nil)
        directories[origin]?.entries[name] = nil
        entry.name = newName
        note(target, name: newName, entry: entry)
        if fresh(target) != nil { directories[target]?.entries[newName] = entry }
    }

    /// Forgets the listings of these directories, and notes that nothing is known about them.
    internal func forget(_ directories: URL...) {
        lock.lock()
        defer { lock.unlock() }
        for directory in directories {
            let key = directory.locationKey
            note(key, name: nil, entry: nil)
            self.directories[key] = nil
        }
    }

    /// Forgets a directory and everything below it, after it was removed or moved.
    internal func forgetTree(_ root: URL) {
        let key = root.locationKey
        lock.lock()
        defer { lock.unlock() }
        for known in directories.keys where known == key || known.hasPrefix(key + "/") {
            note(known, name: nil, entry: nil)
            directories[known] = nil
        }
    }

    deinit {
        // Nothing to release.
    }
}
