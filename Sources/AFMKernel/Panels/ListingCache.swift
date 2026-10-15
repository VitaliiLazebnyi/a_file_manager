public import Foundation
import os

/// Remembers the last complete listing of the folders that are slow to read, so a panel that
/// returns to one can show it at once and read it afresh behind ("show old, refresh behind").
///
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
/// background readers store them. All state is behind one lock, which is never held while
/// sorting or while anything else slow happens.
public final class ListingCache: Sendable {
    /// How much is remembered, and for how long.
    public struct Limits: Sendable {
        /// At most this many folders.
        public var maxFolders = 20
        /// …and this many entries in all of them together.
        ///
        /// A single folder with more entries than this is not remembered.
        public var maxEntries = 300_000
        /// An entry older than this is not handed out any more: the folder is read normally.
        public var maxAge: TimeInterval = 10 * 60
        /// A folder on a local volume is remembered only when reading it took at least this long.
        public var slowRead: TimeInterval = 0.15

        /// The limits the program uses.
        public init() {
            // Every limit as declared.
        }
    }

    /// One remembered reading of a folder.
    public struct Entry: Sendable {
        /// The folder with its items sorted by `order`.
        public let listing: Listing
        /// The order the items are in.
        public let order: ListOrder
        /// When the reading was finished.
        public let readAt: Date
    }

    /// The moment a reading started, in the cache's own count of events (`startReading`).
    public struct Ticket: Sendable {
        /// The count when the reading started.
        internal let clock: UInt64
    }

    /// What an entry is found by.
    private struct Key: Hashable {
        /// The folder's `locationKey`.
        let location: String
        /// Whether the reading listed hidden files.
        let showHidden: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.location == rhs.location && lhs.showHidden == rhs.showHidden
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(location)
            hasher.combine(showHidden)
        }
    }

    /// An entry with what tells it from other readings of its folder.
    private struct Slot {
        /// The reading.
        var entry: Entry
        /// The value of `clock` when the reading started: tells one reading from the next, and
        /// which of two is the later one.
        let started: UInt64
        /// The value of `clock` when the slot was last stored or handed out.
        var lastUsed: UInt64
    }

    /// Everything that changes, behind the lock.
    private struct State {
        /// The remembered readings.
        var slots: [Key: Slot] = [:]
        /// Counts the events: readings started, entries stored and handed out, changes.
        var clock: UInt64 = 0
        /// The value of `clock` when something was last forgotten because it had changed.
        var lastChange: UInt64 = 0
        /// Whether the cache remembers anything.
        var enabled = true

        /// The number of entries in all remembered folders together.
        var totalEntries: Int { slots.values.reduce(0) { $0 + $1.entry.listing.items.count } }

        /// Takes slots out; the caller hands what comes back to `release`, without the lock.
        mutating func remove(where isGoing: (Key) -> Bool) -> [Slot] {
            var dropped: [Slot] = []
            for key in slots.keys where isGoing(key) {
                if let slot = slots.removeValue(forKey: key) { dropped.append(slot) }
            }
            return dropped
        }

        /// Takes out a folder and everything below it, and notes the change.
        mutating func forget(key: String) -> [Slot] {
            clock += 1
            lastChange = clock
            let below = key.utf8.last == 0x2F ? key : key + "/"
            return remove { $0.location == key || $0.location.utf8.starts(with: below.utf8) }
        }
    }

    /// Settings key of the on/off switch (a Boolean, on when absent).
    public static let settingsKey = "listingCache.enabled"

    /// How much is remembered, and for how long.
    public let limits: Limits
    /// The clock ages are measured with.
    private let now: @Sendable () -> Date
    /// Everything that changes.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Switched off, the cache forgets everything and remembers nothing.
    public var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            var dropped = state.withLock { current in
                current.enabled = newValue
                return newValue ? [] : current.remove { _ in true }
            }
            Self.release(&dropped)
        }
    }

    /// `now` is the clock ages are measured with; tests pass their own.
    @preconcurrency
    public init(limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.now = now
    }

    /// Lets go of listings that were taken out of the cache.
    ///
    /// Called without the lock, and the memory of a long listing is released on a background
    /// thread: neither whoever waits for the lock nor the caller (which may be the main thread)
    /// pays for it.
    private static func release(_ dropped: inout [Slot]) {
        var lists = dropped.map(\.entry.listing.items)
        // Nothing of the caller's is left to be the last holder.
        dropped = []
        for index in lists.indices { Discard.later(&lists[index]) }
    }

    /// To be called right before a folder is read, for the ticket `store` asks for.
    public func startReading() -> Ticket {
        state.withLock { current in
            current.clock += 1
            return Ticket(clock: current.clock)
        }
    }

    /// Remembers a complete listing whose items are sorted by `order`; `readTime` is how long the
    /// file system took to deliver it and `ticket` says when its reading started.
    ///
    /// Never call this with a partial listing or with one whose reading ended in an error. Returns
    /// whether the listing is remembered now.
    ///
    /// A folder that is already remembered is always brought up to date, however fast the new
    /// reading was, so a remembered listing never falls behind what a panel has just read.
    /// Not kept is a listing whose reading started before the last report of a change
    /// (`invalidate`, `forget`; any folder's, to keep this simple: it only costs one chance to
    /// remember), or before the reading that is remembered already.
    @discardableResult
    public func store(
        _ listing: Listing,
        sortedBy order: ListOrder,
        showHidden: Bool,
        readTime: TimeInterval,
        since ticket: Ticket
    ) -> Bool {
        let key = Key(location: listing.directory.locationKey, showHidden: showHidden)
        let isWanted = (listing.volume.map { !$0.isLocal } ?? false) || readTime >= limits.slowRead
        let slot = Slot(entry: Entry(listing: listing, order: order, readAt: now()), started: ticket.clock, lastUsed: 0)
        let bounds = limits
        let outcome = state.withLock { current in
            guard current.enabled, ticket.clock > current.lastChange, (current.slots[key]?.started ?? 0) < ticket.clock
            else {
                return (false, [Slot]())
            }
            guard listing.items.count <= bounds.maxEntries else {
                return (false, current.remove { $0 == key })
            }
            guard isWanted || current.slots[key] != nil else {
                return (false, [])
            }
            current.clock += 1
            var dropped = current.remove { $0 == key }
            current.slots[key] = Slot(entry: slot.entry, started: slot.started, lastUsed: current.clock)
            // The least recently used folders make room. The one just stored is the most
            // recently used and fits on its own, so it is never the one to go.
            while current.slots.count > bounds.maxFolders || current.totalEntries > bounds.maxEntries,
                let oldest = current.slots.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            {
                dropped += current.remove { $0 == oldest }
            }
            return (true, dropped)
        }
        var dropped = outcome.1
        Self.release(&dropped)
        return outcome.0
    }

    /// The remembered listing of a location, in whatever order it is kept; nil when there is none
    /// or it is older than `Limits.maxAge` (it is then dropped).
    ///
    /// Cheap: a lookup, no sorting. Being handed out counts as use.
    public func entry(for location: URL, showHidden: Bool) -> Entry? {
        slot(for: Key(location: location.locationKey, showHidden: showHidden))?.entry
    }

    /// The remembered listing of a location with its items sorted by `order`.
    ///
    /// When it is kept in another order, the items are sorted here (on all cores when there are
    /// many) and the entry is kept in the new order from then on: **call this on a background
    /// thread**.
    public func entry(for location: URL, showHidden: Bool, sortedBy order: ListOrder) -> Entry? {
        let key = Key(location: location.locationKey, showHidden: showHidden)
        guard let slot = slot(for: key) else {
            return nil
        }
        let found = slot.entry
        guard found.order != order else {
            return found
        }
        let old = found.listing
        // Sorted outside the lock.
        let sorted = Entry(
            listing: Listing(
                directory: old.directory,
                items: Sorter.sort(old.items, by: order),
                parent: old.parent,
                root: old.root,
                volume: old.volume
            ),
            order: order,
            readAt: found.readAt
        )
        state.withLock { current in
            // Kept only if nobody stored a newer reading or dropped the entry meanwhile.
            if current.slots[key]?.started == slot.started { current.slots[key]?.entry = sorted }
        }
        return sorted
    }

    /// How old the remembered listing of a location is; nil when there is none.
    ///
    /// Does not count as use.
    public func age(of location: URL, showHidden: Bool) -> TimeInterval? {
        let key = Key(location: location.locationKey, showHidden: showHidden)
        let time = now()
        return state.withLock { current in current.slots[key].map { time.timeIntervalSince($0.entry.readAt) } }
    }

    /// Drops what is remembered of a folder and of everything below it, in both show-hidden
    /// variants: the folder is gone, was renamed, or could not be read.
    public func forget(_ directory: URL) {
        let key = directory.locationKey
        var dropped = state.withLock { $0.forget(key: key) }
        Self.release(&dropped)
    }

    /// The contents of these folders were changed by an operation of the program.
    ///
    /// Dropped are: the folders themselves, everything below them (a copied or deleted tree changes
    /// folders further down, a renamed folder moves them), and the folder directly above each,
    /// whose listing shows the changed folder's date.
    public func invalidate(_ directories: [URL]) {
        let keys = directories.map(\.locationKey)
        let parents = Set(directories.map { $0.deletingLastPathComponent().locationKey })
        var dropped = state.withLock { current in
            keys.flatMap { current.forget(key: $0) } + current.remove { parents.contains($0.location) }
        }
        Self.release(&dropped)
    }

    /// The slot of a key, if it is fresh; one that is too old is dropped.
    private func slot(for key: Key) -> Slot? {
        let time = now()
        let maxAge = limits.maxAge
        let outcome = state.withLock { current -> (Slot?, [Slot]) in
            guard let slot = current.slots[key] else {
                return (nil, [])
            }
            guard time.timeIntervalSince(slot.entry.readAt) <= maxAge else {
                return (nil, current.remove { $0 == key })
            }
            current.clock += 1
            current.slots[key]?.lastUsed = current.clock
            return (slot, [])
        }
        var dropped = outcome.1
        Self.release(&dropped)
        return outcome.0
    }

    deinit {
        // Nothing to release: what the cache holds goes with it.
    }
}
