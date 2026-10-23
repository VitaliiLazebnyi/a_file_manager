import Foundation

/// The members of an archive as a tree of folders.
///
/// Archives list their members as a flat sequence of paths; folders that have no entry of their own
/// are made up from the paths of what lies in them (spec 08 › The archive panel). A value type:
/// whoever owns it guards it.
///
/// **Paths.** A path is cut into names at the byte `/`, never at the character: a `/` that is
/// followed by a combining mark is one character to Swift and still a separator to the disk.
/// `normalized` lets through only paths in which the two views agree, so everything that
/// handles them afterwards may use either.
internal struct ArchiveTree {
    /// A member's path may not be longer than this, in bytes (what the system takes as a path).
    internal static let maxPathBytes = 4_096
    /// …nor have more names than this: every name is a folder that has to be kept.
    internal static let maxDepth = 256
    /// The paths of the folders that were made up may take this many bytes together.
    ///
    /// Every folder above a member is kept under its whole path, so deep paths cost the square of
    /// their length; an archive made of them is refused rather than allowed to fill the memory.
    internal static let maxImplicitBytes = 48 << 20

    /// The place of the top folder, which has no entry.
    private static let top: Int32 = -1

    /// The entries, each in a place of its own that it keeps for as long as it is in the
    /// tree; a place that was given up is used again.
    ///
    /// Everything else speaks of an entry by the number of its place, which is four bytes, where
    /// its path would be a string: an archive of millions of members is kept in a few hundred bytes
    /// per member.
    private var slots: ContiguousArray<ArchiveEntry?> = []
    /// The position of the entry in each place that is taken, beside the entries: the sequence is
    /// searched by it without the entries being looked at.
    private var orders: ContiguousArray<Int> = []
    /// The places given up, to be used again.
    private var freeSlots: [Int32] = []
    /// The place of the entry at each path.
    private var index: [String: Int32] = [:]
    /// The places of the entries directly inside each folder, by the folder's place.
    private var children: [Int32: Set<Int32>] = [Self.top: []]
    /// The position the next entry that comes without one gets.
    private var nextOrder = 0
    /// The entries' places in archive order, kept up while entries come and go once `isSorted`.
    private var sequence: [Int32] = []
    /// False until the sequence is first asked for; until then it is not kept up.
    private var isSorted = false
    /// The bytes of the paths of the folders that were made up.
    internal private(set) var implicitBytes = 0

    /// The number of entries, made-up folders included.
    internal var count: Int { index.count }

    /// Every entry, in no order.
    internal var unordered: [ArchiveEntry] { slots.compactMap(\.self) }

    /// Every entry in archive order.
    ///
    /// Sorted once; after that the order is kept up as entries come and go, so a write that follows
    /// a change does not sort the whole archive again.
    internal var ordered: [ArchiveEntry] {
        mutating get {
            sort().compactMap { slots[Int($0)] }
        }
    }

    /// True when some entry matches.
    internal func contains(where matches: (ArchiveEntry) -> Bool) -> Bool {
        slots.contains { $0.map(matches) == true }
    }

    /// Makes room for this many entries at once, when their number is known beforehand, and
    /// for some folders that have to be made up besides: room that is found too small is
    /// doubled, which for a large archive is a lot of memory for a few more entries.
    internal mutating func reserve(_ count: Int) {
        slots.reserveCapacity(count + count / 16 + 256)
        orders.reserveCapacity(count + count / 16 + 256)
        index.reserveCapacity(count)
    }

    private func slot(of path: String) -> Int32? {
        path.isEmpty ? Self.top : index[path]
    }

    /// The entry at a path; nil when there is none (the top folder has none either).
    internal func entry(_ path: String) -> ArchiveEntry? {
        index[path].flatMap { slots[Int($0)] }
    }

    /// True for the top folder and for every folder entry.
    internal func isDirectory(_ path: String) -> Bool {
        path.isEmpty || entry(path)?.isDirectory == true
    }

    /// The entries directly inside a folder; empty when the path is not a folder (`isDirectory`
    /// tells the two apart).
    ///
    /// Every folder has a list of its own (`insert` makes it), the top folder from the start.
    internal func children(of path: String) -> [ArchiveEntry] {
        guard isDirectory(path), let folder = slot(of: path), let places = children[folder] else {
            return []
        }
        return places.compactMap { slots[Int($0)] }
    }

    /// True when something lies directly inside the folder at the path.
    internal func hasChildren(_ path: String) -> Bool {
        guard let folder = slot(of: path) else {
            return false
        }
        return !(children[folder] ?? []).isEmpty
    }

    /// Everything below a folder, at any depth.
    internal func descendants(of path: String) -> [ArchiveEntry] {
        guard isDirectory(path), let start = slot(of: path) else {
            return []
        }
        var found: [ArchiveEntry] = []
        var pending = [start]
        // Folders only are pending, and every folder has a list of its own.
        while let folder = pending.popLast(), let places = children[folder] {
            for (place, child) in places.compactMap({ place in slots[Int(place)].map { (place, $0) } }) {
                found.append(child)
                if child.isDirectory { pending.append(place) }
            }
        }
        return found
    }

    /// The sequence, sorted first if it has not been yet.
    @discardableResult
    private mutating func sort() -> [Int32] {
        if isSorted {
            return sequence
        }
        var places: [Int32] = []
        places.reserveCapacity(index.count)
        for place in slots.indices where slots[place] != nil { places.append(Int32(place)) }
        let positions = orders
        places.sort { positions[Int($0)] < positions[Int($1)] }
        (sequence, isSorted) = (places, true)
        return places
    }

    /// The path of the entry that has this position in the archive; nil when none has.
    internal mutating func path(atOrder order: Int) -> String? {
        let listed = sort()
        let place = self.place(of: order, in: listed)
        guard place < listed.count, let entry = slots[Int(listed[place])], entry.order == order else {
            return nil
        }
        return entry.path
    }

    /// Where an entry with this position stands, or would stand, in the sequence.
    private func place(of order: Int, in sequence: [Int32]) -> Int {
        var (low, high) = (0, sequence.count)
        while low < high {
            let middle = (low + high) / 2
            if orders[Int(sequence[middle])] < order { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // The sequence is changed where it lies: no copy of it is ever held beside it. Both are
    // called while the entry stands in its place.
    private mutating func list(_ place: Int32) {
        guard isSorted else {
            return
        }
        let order = orders[Int(place)]
        if let last = sequence.last, orders[Int(last)] >= order {
            let position = self.place(of: order, in: sequence)
            sequence.insert(place, at: position)
        } else {
            sequence.append(place)
        }
    }

    private mutating func unlist(_ place: Int32) {
        guard isSorted else {
            return
        }
        // The entries that share its position stand together from here, and it is among them.
        let start = self.place(of: orders[Int(place)], in: sequence)
        let position = sequence[start...].firstIndex(of: place)
        if let position { sequence.remove(at: position) }
    }

    /// Puts an entry into a free place.
    private mutating func seat(_ entry: ArchiveEntry) -> Int32 {
        let place: Int32
        if let free = freeSlots.popLast() {
            slots[Int(free)] = entry
            orders[Int(free)] = entry.order
            place = free
        } else {
            slots.append(entry)
            orders.append(entry.order)
            place = Int32(slots.count - 1)
        }
        index[entry.path] = place
        list(place)
        return place
    }

    /// Changes an entry where it is.
    ///
    /// Path, kind and position are not to be changed this way.
    internal mutating func update(_ path: String, _ change: (inout ArchiveEntry) -> Void) {
        guard let place = index[path], var entry = slots[Int(place)] else {
            return
        }
        // Taken out while it changes, so that the change does not copy what the entry holds.
        slots[Int(place)] = nil
        change(&entry)
        slots[Int(place)] = entry
    }

    /// Adds an entry, or replaces the one at the same path; missing folders above it are made
    /// up.
    ///
    /// With `keepingOrder` the entry keeps the position it carries.
    internal mutating func insert(_ entry: ArchiveEntry, keepingOrder: Bool) {
        var entry = entry
        let taken = index[entry.path]
        let existing = taken.flatMap { slots[Int($0)] }
        if let existing {
            // A folder that had been made up gets its real entry; anything else is replaced.
            if !keepingOrder { entry.order = existing.isImplicit ? nextOrder : existing.order }
            if existing.isImplicit { implicitBytes -= entry.path.utf8.count }
        } else if !keepingOrder {
            entry.order = nextOrder
        }
        nextOrder = max(nextOrder, entry.order) + 1
        let place: Int32
        if let taken, let existing {
            place = taken
            replace(existing, at: place, with: entry)
        } else {
            place = seat(entry)
        }
        if entry.isImplicit { implicitBytes += entry.path.utf8.count }
        if entry.isDirectory, children[place] == nil { children[place] = [] }
        listInFolders(place, path: entry.path, modified: entry.modified)
    }

    /// Puts `entry` in the place of `existing`, moving it in the sequence when its position changes.
    private mutating func replace(_ existing: ArchiveEntry, at place: Int32, with entry: ArchiveEntry) {
        if existing.order != entry.order {
            unlist(place)
            slots[Int(place)] = entry
            orders[Int(place)] = entry.order
            list(place)
        } else {
            slots[Int(place)] = entry
        }
    }

    /// Lists the entry in the place at `path` in its folder, and each folder in the one above,
    /// making up the folders that have no entry (dated `modified`).
    private mutating func listInFolders(_ entryPlace: Int32, path entryPath: String, modified: Date) {
        var (path, place) = (entryPath, entryPlace)
        while !path.isEmpty {
            let parent = Self.parent(of: path)
            var folder = Self.top
            if !parent.isEmpty {
                if let known = index[parent] {
                    folder = known
                } else {
                    folder = seat(
                        ArchiveEntry(
                            path: parent,
                            isDirectory: true,
                            isImplicit: true,
                            modified: modified,
                            permissions: 0o755,
                            order: nextOrder
                        )
                    )
                    implicitBytes += parent.utf8.count
                    nextOrder += 1
                }
            }
            // A folder that already lists the entry is itself listed all the way up: a
            // thousand files in one folder walk the path above them once.
            guard children[folder, default: []].insert(place).inserted else { break }
            (path, place) = (parent, folder)
        }
    }

    /// Takes one entry out.
    ///
    /// What lies below it stays; the callers remove only files and empty folders.
    @discardableResult
    internal mutating func remove(_ path: String) -> ArchiveEntry? {
        guard let place = index[path], let entry = slots[Int(place)] else {
            return nil
        }
        unlist(place)
        index[path] = nil
        slots[Int(place)] = nil
        freeSlots.append(place)
        if entry.isImplicit { implicitBytes -= path.utf8.count }
        children[place] = nil
        if let folder = slot(of: Self.parent(of: path)) { children[folder]?.remove(place) }
        return entry
    }
}
