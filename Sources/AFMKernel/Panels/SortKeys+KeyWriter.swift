/// Making the records.
extension SortKeys {
    /// Writes the records of one run of items and the bytes they point into.
    ///
    /// The bytes grow, and move when they do, so the records get their pointers only at the end
    /// (`build`).
    internal struct KeyWriter {
        /// The longest key or part a record can describe.
        private static let limit = Int(UInt16.max)

        /// The bytes written so far.
        internal private(set) var bytes: UnsafeMutablePointer<UInt8>
        /// How many bytes are allocated.
        private var capacity: Int
        /// How many bytes are written.
        internal private(set) var used = 0
        /// The UTF-16 of the name at hand, which the collator wants.
        private var units: [UInt16] = []
        /// Whose keys are written.
        private let collator: NameCollator
        /// The order the records are for.
        private let order: ListOrder

        /// A writer with room for `capacity` bytes to start with.
        internal init(capacity: Int, collator: NameCollator, order: ListOrder) {
            (self.capacity, self.collator, self.order) = (capacity, collator, order)
            bytes = .allocate(capacity: capacity)
        }

        /// UTF-16 units in a run of valid UTF-8: one for every character's first byte, two
        /// for a character of four bytes.
        internal static func unitCount(_ text: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
            var count = 0
            for index in range where text[index] & 0xC0 != 0x80 { count += text[index] >= 0xF0 ? 2 : 1 }
            return count
        }

        /// The parts of a name as ranges of its bytes (see `SortKeys.init`); `baseCount` is
        /// where `FileItem.split` cuts a file's name.
        internal static func parts(count: Int, baseCount: Int, isFolder: Bool, key: SortKey)
            -> (first: Range<Int>, second: Range<Int>)
        {
            if isFolder {
                return (0..<count, 0..<0)
            }
            if key == .ext {
                return (baseCount < count ? (baseCount + 1)..<count : 0..<0, 0..<baseCount)
            }
            return (0..<baseCount, baseCount..<count)
        }

        /// Writes the record of one item; the memory is the writer's.
        internal mutating func record(of item: FileItem) -> Record {
            var record = Record()
            if item.isFolder { record.flags |= Record.folder } else { record.primary = primary(of: item, order.key) }
            // Files in the order they came need no key at all.
            guard item.isFolder || order.key != .unsorted else {
                return record
            }
            var name = item.name
            name.makeContiguousUTF8()
            let start = used
            let made = name.utf8.withContiguousStorageIfAvailable { text in
                writeParts(of: name, text, isFolder: item.isFolder, into: &record)
            }
            if made != true {
                used = start
                record.flags |= Record.keyless
            }
            return record
        }

        /// Writes the keys and the bytes of a name's parts; false when the name is too long
        /// for a record, or a key cannot be had.
        private mutating func writeParts(
            of name: String,
            _ text: UnsafeBufferPointer<UInt8>,
            isFolder: Bool,
            into record: inout Record
        ) -> Bool {
            guard text.count <= Self.limit / 4 else {
                return false
            }
            let isPlain = text.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            // Where the name is cut, as `FileItem.split` cuts it.
            let cut = isFolder ? text.count : baseCount(of: name, text)
            let (first, second) = Self.parts(count: text.count, baseCount: cut, isFolder: isFolder, key: order.key)
            // The collator wants UTF-16; a part's place in it is found by counting.
            units.removeAll(keepingCapacity: true)
            if isPlain {
                units.append(contentsOf: text.lazy.map(UInt16.init))
            } else {
                units.append(contentsOf: name.utf16)
            }
            let unitRange = { (range: Range<Int>) -> Range<Int> in
                guard !isPlain else {
                    return range
                }
                let lower = Self.unitCount(text, 0..<range.lowerBound)
                return lower..<(lower + Self.unitCount(text, range))
            }
            reserve(text.count * 2 + 64)
            guard let firstKey = appendKey(of: unitRange(first)) else {
                return false
            }
            append(UnsafeBufferPointer(rebasing: text[first]))
            reserve(text.count * 2 + 64)
            guard let secondKey = appendKey(of: unitRange(second)) else {
                return false
            }
            append(UnsafeBufferPointer(rebasing: text[second]))
            (record.firstKey, record.first) = (UInt16(firstKey), UInt16(first.count))
            (record.secondKey, record.second) = (UInt16(secondKey), UInt16(second.count))
            return true
        }

        /// Where `FileItem.split` cuts a file's name: the length of its base name in bytes.
        private func baseCount(of name: String, _ text: UnsafeBufferPointer<UInt8>) -> Int {
            guard let cut = FileItem.splitPoint(text) else {
                return FileItem.split(name).base.utf8.count
            }
            return cut == FileItem.noExtension ? text.count : cut
        }

        /// Makes room for `more` bytes after the written ones.
        private mutating func reserve(_ more: Int) {
            guard capacity - used < more else {
                return
            }
            let grown = max(capacity * 2, used + more)
            let moved = UnsafeMutablePointer<UInt8>.allocate(capacity: grown)
            moved.initialize(from: bytes, count: used)
            bytes.deallocate()
            (bytes, capacity) = (moved, grown)
        }

        /// Appends the collation key of a run of the units and returns its length; nil when
        /// there is none to be had.
        private mutating func appendKey(of range: Range<Int>) -> Int? {
            guard !range.isEmpty else {
                return 0
            }
            var length = writeKey(of: range)
            if length > capacity - used {
                // The key did not fit: it is written again once there is room for it.
                reserve(length)
                length = writeKey(of: range)
            }
            guard length > 0, length <= Self.limit, length <= capacity - used else {
                return nil
            }
            used += length
            return length
        }

        /// Writes the collation key of a run of the units after the written bytes, as far as
        /// there is room, and returns its length.
        private func writeKey(of range: Range<Int>) -> Int {
            units.withUnsafeBufferPointer { units in
                collator.writeKey(
                    of: UnsafeBufferPointer(rebasing: units[range]),
                    into: UnsafeMutableBufferPointer(start: bytes + used, count: capacity - used)
                )
            }
        }

        /// Appends bytes as they are.
        private mutating func append(_ text: UnsafeBufferPointer<UInt8>) {
            reserve(text.count)
            _ = UnsafeMutableBufferPointer(start: bytes + used, count: text.count).initialize(fromContentsOf: text)
            used += text.count
        }
    }

    /// Makes the records of a run of items and returns the memory they point into.
    internal static func build(
        _ items: [FileItem],
        _ piece: Range<Int>,
        into records: UnsafeMutableBufferPointer<Record>,
        order: ListOrder,
        collator: NameCollator
    ) -> Block {
        var writer = KeyWriter(capacity: max(256, piece.count * 48), collator: collator, order: order)
        var offsets: [Int] = []
        offsets.reserveCapacity(piece.count)
        for index in piece {
            offsets.append(writer.used)
            records.initializeElement(at: index, to: writer.record(of: items[index]))
        }
        // The memory has stopped moving: the records can point into it.
        for index in piece { records[index].bytes = UnsafePointer(writer.bytes + offsets[index - piece.lowerBound]) }
        return Block(writer.bytes)
    }
}
