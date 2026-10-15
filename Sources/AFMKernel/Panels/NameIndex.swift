/// Finds an entry of a list by its name as it is written, byte for byte.
///
/// Made in one pass over the list, the hashing on all cores; a value that can be made on any thread
/// and handed on.
///
/// The hash is the standard library's, keyed anew for every run of the program, so names
/// chosen by somebody else (an archive, a server) cannot be made to collide.
internal struct NameIndex: Sendable {
    /// The upper half of a slot: a part of the name's hash.
    private static let tag: UInt64 = 0xFFFF_FFFF_0000_0000

    /// The upper half holds a part of the name's hash, the lower the place plus one; zero is free.
    private var slots: [UInt64]
    /// The slot count less one: the slots are a power of two.
    private let mask: Int
    /// For a name that occurs more than once: the further places, by the first.
    private var twins: [UInt32: [UInt32]] = [:]

    /// The index of the names of `items`.
    internal init(_ items: [FileItem]) {
        var capacity = 16
        while capacity < items.count * 2 { capacity <<= 1 }
        mask = capacity - 1
        let hashes = Self.hashes(of: items)
        var table = [UInt64](repeating: 0, count: capacity)
        var found: [UInt32: [UInt32]] = [:]
        for place in items.indices {
            let hash = hashes[place]
            var slot = Int(truncatingIfNeeded: hash) & mask
            while table[slot] != 0 {
                let other = Int(table[slot] & ~Self.tag) - 1
                if table[slot] & Self.tag == hash & Self.tag, ExactName.areSame(items[other].name, items[place].name) {
                    found[UInt32(other), default: []].append(UInt32(place))
                    break
                }
                slot = (slot + 1) & mask
            }
            if table[slot] == 0 { table[slot] = hash & Self.tag | UInt64(place + 1) }
        }
        (slots, twins) = (table, found)
    }

    private init(slots: [UInt64], mask: Int, twins: [UInt32: [UInt32]]) {
        (self.slots, self.mask, self.twins) = (slots, mask, twins)
    }

    /// The hash of a name's bytes.
    private static func hash(_ name: String) -> UInt64 {
        var hasher = Hasher()
        ExactName.combine(name, into: &hasher)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// The hashes of the names of a list, a long one on all cores.
    private static func hashes(of items: [FileItem]) -> [UInt64] {
        guard items.count > ListWork.pieceSize * 2 else {
            return items.map { hash($0.name) }
        }
        return [UInt64](unsafeUninitializedCapacity: items.count) { buffer, count in
            // Each piece writes its own places and only reads the list.
            nonisolated(unsafe) let target = buffer
            _ = Parallel.map(ListWork.pieces(items.count, of: ListWork.pieceSize)) { piece in
                for place in piece { target.initializeElement(at: place, to: hash(items[place].name)) }
            }
            count = items.count
        }
    }

    /// The first place of the name in `items`, which must be the list the index was made of.
    internal func place(of name: String, in items: [FileItem]) -> Int? {
        let hash = Self.hash(name)
        var slot = Int(truncatingIfNeeded: hash) & mask
        while slots[slot] != 0 {
            let other = Int(slots[slot] & ~Self.tag) - 1
            if slots[slot] & Self.tag == hash & Self.tag, ExactName.areSame(items[other].name, name) {
                return other
            }
            slot = (slot + 1) & mask
        }
        return nil
    }

    /// Every place of the name, in rising order.
    internal func places(of name: String, in items: [FileItem]) -> [Int] {
        guard let first = place(of: name, in: items) else {
            return []
        }
        guard !twins.isEmpty, let others = twins[UInt32(first)] else {
            return [first]
        }
        return [first] + others.map(Int.init)
    }

    /// The index of the same entries after they changed places: `moves[old]` is the new place.
    internal func moved(by moves: [UInt32]) -> Self {
        var slots = slots
        for slot in slots.indices where slots[slot] != 0 {
            let held = slots[slot]
            slots[slot] = held & Self.tag | UInt64(moves[Int(held & ~Self.tag) - 1] + 1)
        }
        guard !twins.isEmpty else {
            return Self(slots: slots, mask: mask, twins: [:])
        }
        // The lowest place of a name stands for it, as in an index made afresh.
        var moved: [UInt32: [UInt32]] = [:]
        var firsts: [UInt32: UInt32] = [:]
        for (first, others) in twins {
            let places = ([first] + others).map { moves[Int($0)] }.sorted()
            moved[places[0]] = Array(places.dropFirst())
            firsts[moves[Int(first)]] = places[0]
        }
        for slot in slots.indices where slots[slot] != 0 {
            let place = UInt32(slots[slot] & ~Self.tag) - 1
            if let first = firsts[place] { slots[slot] = slots[slot] & Self.tag | UInt64(first + 1) }
        }
        return Self(slots: slots, mask: mask, twins: moved)
    }
}
