import Foundation

/// Remembers the last complete listing of the folders that are slow to read, so a panel that
/// returns to one can show it at once and read it afresh behind ("show old, refresh behind").
/// Everything is kept in memory only; nothing survives the end of the program.
///
/// What is kept: complete listings only, of folders on volumes that are not local (network
/// shares), and of local folders whose reading took noticeably long. An entry is identified by
/// its location (`URL.locationKey`) and the show-hidden setting it was read with, and holds the
/// items sorted in one order; asking for another order sorts them again, which the caller does
/// in the background.
///
/// What bounds it: a number of folders and a total number of entries, the least recently used
/// folder going first, and an age after which an entry is no longer handed out. The age limit
/// is what bounds how wrong a remembered listing can be for folders nobody tells us about.
///
/// Readings overlap (a refresh, a read-ahead, a reload after an operation), and the one that
/// ends last is not always the one that saw the folder last. So whoever reads takes a `Ticket`
/// before starting and hands it in with the listing: a listing that was read before the folder
/// was reported changed, or before the reading that is already remembered, is not kept.
///
/// **Threading.** Safe to use from any thread: the main thread looks entries up while
/// background readers store them. All state is protected by one lock, which is never held
/// while sorting or while anything else slow happens.
public final class ListingCache {
    public struct Limits {
        /// At most this many folders…
        public var maxFolders = 20
        /// …and this many entries in all of them together. A single folder with more entries
        /// than this is not remembered.
        public var maxEntries = 300_000
        /// An entry older than this is not handed out any more: the folder is read normally.
        public var maxAge: TimeInterval = 10 * 60
        /// A folder on a local volume is remembered only when reading it took at least this long.
        public var slowRead: TimeInterval = 0.15

        public init() {}
    }

    /// One remembered reading of a folder.
    public struct Entry {
        /// The folder with its items sorted by `order`.
        public let listing: Listing
        public let order: ListOrder
        public let showHidden: Bool
        /// When the reading was finished.
        public let readAt: Date
    }

    /// The moment a reading started, in the cache's own count of events (`startReading`).
    public struct Ticket {
        fileprivate let clock: UInt64
    }

    /// Settings key of the on/off switch (a Boolean, on when absent).
    public static let settingsKey = "listingCache.enabled"

    public let limits: Limits

    private struct Key: Hashable {
        let location: String
        let showHidden: Bool
    }

    private struct Slot {
        var entry: Entry
        /// The value of `clock` when the reading started: tells one reading from the next, and
        /// which of two is the later one.
        let started: UInt64
        /// The value of `clock` when the slot was last stored or handed out.
        var lastUsed: UInt64
    }

    private let lock = NSLock()
    private let now: () -> Date
    // Protected by `lock`.
    private var slots: [Key: Slot] = [:]
    private var clock: UInt64 = 0
    /// The value of `clock` when something was last forgotten because it had changed.
    private var lastChange: UInt64 = 0
    private var enabled = true

    /// `now` is the clock ages are measured with; tests pass their own.
    public init(limits: Limits = Limits(), now: @escaping () -> Date = Date.init) {
        self.limits = limits
        self.now = now
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Lets go of listings that were taken out of the cache. Called without the lock, and the
    /// memory of a long listing is released on a background thread: neither whoever waits
    /// for the lock nor the caller (which may be the main thread) pays for it.
    private func release(_ dropped: inout [Slot]) {
        var lists = dropped.map(\.entry.listing.items)
        // Nothing of the caller's is left to be the last holder.
        dropped = []
        for index in lists.indices { Discard.later(&lists[index]) }
    }

    /// Takes slots out; called with the lock held. The caller hands what comes back to `release`.
    private func remove(where isGoing: (Key) -> Bool) -> [Slot] {
        var dropped: [Slot] = []
        for key in slots.keys where isGoing(key) {
            if let slot = slots.removeValue(forKey: key) { dropped.append(slot) }
        }
        return dropped
    }

    /// Switched off, the cache forgets everything and remembers nothing.
    public var isEnabled: Bool {
        get { locked { enabled } }
        set {
            var dropped = locked {
                enabled = newValue
                return newValue ? [] : remove { _ in true }
            }
            release(&dropped)
        }
    }

    /// The number of remembered folders.
    public var folderCount: Int { locked { slots.count } }

    /// The number of entries in all remembered folders together.
    public var entryCount: Int { locked { totalEntries() } }

    private func totalEntries() -> Int {
        slots.values.reduce(0) { $0 + $1.entry.listing.items.count }
    }

    // MARK: Storing

    /// To be called right before a folder is read, for the ticket `store` asks for.
    public func startReading() -> Ticket {
        locked {
            clock += 1
            return Ticket(clock: clock)
        }
    }

    /// Remembers a complete listing whose items are sorted by `order`; `readTime` is how long
    /// the file system took to deliver it and `ticket` says when its reading started. Never
    /// call this with a partial listing or with one whose reading ended in an error. Returns
    /// whether the listing is remembered now.
    ///
    /// A folder that is already remembered is always brought up to date, however fast the new
    /// reading was, so a remembered listing never falls behind what a panel has just read.
    /// Not kept is a listing whose reading started before the last report of a change
    /// (`invalidate`, `forget`; any folder's, to keep this simple: it only costs one chance to
    /// remember), or before the reading that is remembered already.
    @discardableResult
    public func store(_ listing: Listing, sortedBy order: ListOrder, showHidden: Bool, readTime: TimeInterval, since ticket: Ticket) -> Bool {
        let key = Key(location: listing.directory.locationKey, showHidden: showHidden)
        let isRemote = listing.volume.map { !$0.isLocal } ?? false
        let entry = Entry(listing: listing, order: order, showHidden: showHidden, readAt: now())
        var dropped: [Slot] = []
        defer { release(&dropped) }
        return locked {
            guard enabled, ticket.clock > lastChange, (slots[key]?.started ?? 0) < ticket.clock else { return false }
            guard listing.items.count <= limits.maxEntries else {
                dropped += remove { $0 == key }
                return false
            }
            guard isRemote || readTime >= limits.slowRead || slots[key] != nil else { return false }
            clock += 1
            dropped += remove { $0 == key }
            slots[key] = Slot(entry: entry, started: ticket.clock, lastUsed: clock)
            // The least recently used folders make room. The one just stored is the most
            // recently used and fits on its own, so it is never the one to go.
            while slots.count > limits.maxFolders || totalEntries() > limits.maxEntries,
                  let oldest = slots.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                dropped += remove { $0 == oldest }
            }
            return true
        }
    }

    // MARK: Looking up

    /// The remembered listing of a location, in whatever order it is kept; nil when there is
    /// none or it is older than `Limits.maxAge` (it is then dropped). Cheap: a lookup, no
    /// sorting. Being handed out counts as use.
    public func entry(for location: URL, showHidden: Bool) -> Entry? {
        slot(for: Key(location: location.locationKey, showHidden: showHidden))?.entry
    }

    private func slot(for key: Key) -> Slot? {
        let time = now()
        var dropped: [Slot] = []
        defer { release(&dropped) }
        return locked {
            guard let slot = slots[key] else { return nil }
            guard time.timeIntervalSince(slot.entry.readAt) <= limits.maxAge else {
                dropped += remove { $0 == key }
                return nil
            }
            clock += 1
            slots[key]?.lastUsed = clock
            return slot
        }
    }

    /// The remembered listing of a location with its items sorted by `order`. When it is kept
    /// in another order, the items are sorted here (on all cores when there are many) and the
    /// entry is kept in the new order from then on: **call this on a background thread**.
    public func entry(for location: URL, showHidden: Bool, sortedBy order: ListOrder) -> Entry? {
        let key = Key(location: location.locationKey, showHidden: showHidden)
        guard let slot = slot(for: key) else { return nil }
        let found = slot.entry
        guard found.order != order else { return found }
        let old = found.listing
        // Sorted outside the lock.
        let sorted = Entry(listing: Listing(directory: old.directory, items: Sorter.sort(old.items, by: order), parent: old.parent,
                                            root: old.root, volume: old.volume),
                           order: order, showHidden: showHidden, readAt: found.readAt)
        locked {
            // Kept only if nobody stored a newer reading or dropped the entry meanwhile.
            if slots[key]?.started == slot.started { slots[key]?.entry = sorted }
        }
        return sorted
    }

    /// How old the remembered listing of a location is; nil when there is none. Does not count
    /// as use.
    public func age(of location: URL, showHidden: Bool) -> TimeInterval? {
        let key = Key(location: location.locationKey, showHidden: showHidden)
        let time = now()
        return locked { slots[key].map { time.timeIntervalSince($0.entry.readAt) } }
    }

    // MARK: Forgetting

    /// Drops what is remembered of a folder and of everything below it, in both show-hidden
    /// variants: the folder is gone, was renamed, or could not be read.
    public func forget(_ directory: URL) {
        let key = directory.locationKey
        var dropped = locked { forget(key: key) }
        release(&dropped)
    }

    /// Called with the lock held; what was dropped is for `release`.
    private func forget(key: String) -> [Slot] {
        clock += 1
        lastChange = clock
        let below = key.utf8.last == 0x2F ? key : key + "/"
        return remove { $0.location == key || $0.location.utf8.starts(with: below.utf8) }
    }

    /// The contents of these folders were changed by an operation of the program. Dropped are:
    /// the folders themselves, everything below them (a copied or deleted tree changes folders
    /// further down, a renamed folder moves them), and the folder directly above each, whose
    /// listing shows the changed folder's date.
    public func invalidate(_ directories: [URL]) {
        let keys = directories.map(\.locationKey)
        let parents = Set(directories.map { $0.deletingLastPathComponent().locationKey })
        var dropped = locked {
            keys.flatMap(forget(key:)) + remove { parents.contains($0.location) }
        }
        release(&dropped)
    }

    public func removeAll() {
        var dropped = locked {
            clock += 1
            lastChange = clock
            return remove { _ in true }
        }
        release(&dropped)
    }
}
