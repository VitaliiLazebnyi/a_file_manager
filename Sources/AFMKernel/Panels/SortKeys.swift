import Foundation

/// One compact record per item, made once: what sorting compares instead of the names.
///
/// A record holds, for each part of the name that the order looks at, the part's collation
/// key (the bytes the system's collator makes of it for the user's language) and the part
/// itself. Two records are compared part by part: by key, then by the part's own bytes.
/// That is the order of names, not an approximation of it (see `Sorter`). Only a name too
/// long for a record has none; `quick` then says so and the caller works the same
/// comparison out for the pair.
///
/// Unchecked: the records point into `blocks`, which the keys own and which nobody writes
/// once the keys are made, so the keys may be read on any number of threads.
internal struct SortKeys: @unchecked Sendable {
    /// What one item is sorted by.
    internal struct Record {
        /// The flag of a folder.
        internal static let folder: UInt16 = 1
        /// The flag of a record without key: the comparison is worked out from the names.
        internal static let keyless: UInt16 = 4

        /// Size or date of a file, mapped so that integers compare like the values.
        internal var primary: Int64 = 0
        /// The bytes of the key: first part's collation key, first part, then the second part's.
        internal var bytes: UnsafePointer<UInt8>?
        /// The length of the first part's collation key.
        internal var firstKey: UInt16 = 0
        /// The length of the first part.
        internal var first: UInt16 = 0
        /// The length of the second part's collation key.
        internal var secondKey: UInt16 = 0
        /// The length of the second part.
        internal var second: UInt16 = 0
        /// `folder` and `keyless`.
        internal var flags: UInt16 = 0

        /// Whether the item is a folder.
        internal var isFolder: Bool { flags & Self.folder != 0 }
    }

    /// One part of a name in a record: its collation key followed by its own bytes.
    internal struct Part {
        /// Where the key starts; the part's bytes follow it.
        internal let start: UnsafePointer<UInt8>
        /// The length of the key.
        internal let key: Int
        /// The length of the part.
        internal let text: Int
    }

    /// The memory the records point into, allocated while the keys are made.
    ///
    /// Unchecked: the bytes are written only while the keys are made, before the block is
    /// handed on; from then on they are only read.
    internal final class Block: @unchecked Sendable {
        /// The bytes.
        internal let bytes: UnsafeMutablePointer<UInt8>

        /// Owns `bytes` from now on.
        internal init(_ bytes: UnsafeMutablePointer<UInt8>) {
            self.bytes = bytes
        }

        deinit {
            bytes.deallocate()
        }
    }

    /// The answer of `quick` when a record is missing.
    internal static let unknown = 2

    /// The order the records are made for.
    internal let order: ListOrder
    /// Whose keys these are.
    internal let collator: NameCollator
    /// One record per item, in the order of the items.
    internal let records: [Record]
    /// The memory the records point into.
    private let blocks: [Block]

    /// The records of `items`, with the keys of the user's language.
    internal init(_ items: [FileItem], order: ListOrder) {
        self = Self(items, order: order, collator: .current)
    }

    /// The first part is the extension when sorting by it, otherwise the name without it; folders
    /// have their whole name as the only part.
    ///
    /// The second part is what is compared when the first parts are the same text: the base name
    /// after the extension, or the rest of the name (`.ext`) after the base name. A long list is
    /// worked on all cores.
    internal init(_ items: [FileItem], order: ListOrder, collator: NameCollator) {
        // An empty array is never made with `unsafeUninitializedCapacity`: for a capacity of zero
        // the standard library writes the count into the storage all empty arrays share, a write
        // that races with any other thread reading an empty array.
        precondition(!items.isEmpty)
        self.order = order
        self.collator = collator
        let pieceCount = items.count > Sorter.parallelThreshold ? ProcessInfo.processInfo.activeProcessorCount * 4 : 1
        let pieces = ListWork.evenPieces(items.count, pieceCount)
        var made: [Block] = []
        records = [Record](unsafeUninitializedCapacity: items.count) { buffer, count in
            // Each piece writes the records of its own items.
            nonisolated(unsafe) let target = buffer
            made = Parallel.map(pieces) { piece in
                Self.build(items, piece, into: target, order: order, collator: collator)
            }
            count = items.count
        }
        blocks = made
    }

    /// The keys of two lists merged: each place takes the next key of the first or second list.
    internal init(merging first: Self, _ second: Self, fromSecond: [Bool]) {
        var merged: [Record] = []
        merged.reserveCapacity(fromSecond.count)
        var (next, nextSecond) = (0, 0)
        for isSecond in fromSecond {
            if isSecond {
                merged.append(second.records[nextSecond])
                nextSecond += 1
            } else {
                merged.append(first.records[next])
                next += 1
            }
        }
        self = Self(order: first.order, collator: first.collator, records: merged, blocks: first.blocks + second.blocks)
    }

    private init(order: ListOrder, collator: NameCollator, records: [Record], blocks: [Block]) {
        (self.order, self.collator, self.records, self.blocks) = (order, collator, records, blocks)
    }

    /// What files are ordered by before their names: the size, or the date as a number that
    /// compares like it (the bits of a floating-point number, turned round where negative).
    internal static func primary(of item: FileItem, _ key: SortKey) -> Int64 {
        switch key {
        case .size:
            return item.size

        case .date:
            let bits = Int64(bitPattern: (item.modified.timeIntervalSinceReferenceDate + 0).bitPattern)
            return bits < 0 ? bits ^ Int64.max : bits

        default:
            return 0
        }
    }

    /// Negative when the first item comes before the second, positive when after, zero when
    /// neither has to come first, `unknown` when one of them has no key.
    internal static func quick(_ lhs: Record, _ rhs: Record, _ order: ListOrder) -> Int {
        if (lhs.flags ^ rhs.flags) & Record.folder != 0 {
            return lhs.flags & Record.folder != 0 ? -1 : 1
        }
        if lhs.flags & Record.folder != 0 {
            return names(lhs, rhs)
        }
        if order.key == .unsorted {
            return 0
        }
        if lhs.primary != rhs.primary {
            return (lhs.primary < rhs.primary) != order.descending ? -1 : 1
        }
        let result = names(lhs, rhs)
        return order.descending && result != unknown ? -result : result
    }

    /// Two runs of bytes in the order of their bytes; the shorter of two that start alike first.
    internal static func bytewise(_ lhs: UnsafeBufferPointer<UInt8>, _ rhs: UnsafeBufferPointer<UInt8>) -> Int {
        let length = min(lhs.count, rhs.count)
        let common = length == 0 ? 0 : memcmp(lhs.baseAddress, rhs.baseAddress, length)
        if common != 0 {
            return common < 0 ? -1 : 1
        }
        return lhs.count == rhs.count ? 0 : (lhs.count < rhs.count ? -1 : 1)
    }

    /// Two texts in the order of their UTF-8 bytes.
    internal static func bytewise(_ lhs: String, _ rhs: String) -> Int {
        var (first, second) = (lhs, rhs)
        return first.withUTF8 { left in second.withUTF8 { bytewise(left, $0) } }
    }

    /// The names of two records, part by part; `unknown` when one has no key.
    private static func names(_ lhs: Record, _ rhs: Record) -> Int {
        guard (lhs.flags | rhs.flags) & Record.keyless == 0, let left = lhs.bytes, let right = rhs.bytes else {
            return unknown
        }
        let result = part(
            Part(start: left, key: Int(lhs.firstKey), text: Int(lhs.first)),
            Part(start: right, key: Int(rhs.firstKey), text: Int(rhs.first))
        )
        if result != 0 {
            return result
        }
        return part(
            Part(start: left + Int(lhs.firstKey) + Int(lhs.first), key: Int(lhs.secondKey), text: Int(lhs.second)),
            Part(start: right + Int(rhs.firstKey) + Int(rhs.first), key: Int(rhs.secondKey), text: Int(rhs.second))
        )
    }

    /// One part of two names: by collation key, and by the part's own bytes if those are equal.
    @inline(__always)
    private static func part(_ lhs: Part, _ rhs: Part) -> Int {
        let keys = bytewise(
            UnsafeBufferPointer(start: lhs.start, count: lhs.key),
            UnsafeBufferPointer(start: rhs.start, count: rhs.key)
        )
        guard keys == 0 else {
            return keys
        }
        return bytewise(
            UnsafeBufferPointer(start: lhs.start + lhs.key, count: lhs.text),
            UnsafeBufferPointer(start: rhs.start + rhs.key, count: rhs.text)
        )
    }

    /// The keys of the same items in another order.
    internal func permuted(by indexes: [UInt32]) -> Self {
        Self(order: order, collator: collator, records: indexes.map { records[Int($0)] }, blocks: blocks)
    }
}
