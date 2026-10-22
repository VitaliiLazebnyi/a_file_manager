import AFMKernel
import Foundation

/// One file or folder inside an archive, whatever the archive's format.
internal struct ArchiveEntry {
    /// Where the bytes of a member come from.
    internal enum Content {
        /// Nothing to read: folders, empty files.
        case none
        /// A ZIP member, with everything its directory says.
        case zip(ZipRecord)
        /// A stretch of the archive file (TAR) or of its unpacked copy.
        case range(offset: UInt64, length: UInt64)
        /// The n-th member of an archive that can only be read from the start.
        case member(index: Int)
        /// The whole decompressed file (`.gz`, `.bz2`, `.xz`).
        case whole
        /// Text held in memory: the target of a symbolic link.
        case text(String)
        /// A member that is listed but cannot be read; the text says what it is.
        case unsupported(String)
    }

    /// The path inside the archive: names joined by `/`, none at either end.
    internal var path: String
    internal var isDirectory: Bool
    /// A folder the archive has no entry for; it exists because something lies inside it.
    internal var isImplicit = false
    internal var isSymbolicLink = false
    /// A device, a pipe or a socket in the archive's own terms (`FileItem.isSpecial`).
    internal var isSpecial = false
    /// Unpacked size.
    internal var size: Int64 = 0
    /// False when the size is only what the file claims in a place that cannot be trusted
    /// (the last bytes of a large `.gz`): it is shown, and nothing is checked against it.
    internal var sizeIsExact = true
    internal var packedSize: Int64 = 0
    internal var modified = Date(timeIntervalSince1970: 0)
    internal var permissions: UInt16 = 0o644
    internal var isEncrypted = false
    /// The position in the archive; members are unpacked and rewritten in this order.
    internal var order = 0
    internal var content = Content.none

    internal var name: String { ArchiveTree.name(of: path) }

    internal func item(at url: URL) -> FileItem {
        FileItem(
            url: url,
            name: name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymbolicLink,
                isHidden: name.hasPrefix("."),
                isSpecial: isSpecial
            ),
            stat: .init(size: isDirectory ? 0 : size, modified: modified, permissions: permissions)
        )
    }
}

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
    private var freeSlots: [Int32] = []
    /// The place of the entry at each path.
    private var index: [String: Int32] = [:]
    /// The places of the entries directly inside each folder, by the folder's place.
    private var children: [Int32: Set<Int32>] = [Self.top: []]
    private var nextOrder = 0
    /// The entries' places in archive order, kept up while entries come and go.
    ///
    /// Nil until it is first asked for.
    private var sequence: [Int32]?
    /// The bytes of the paths of the folders that were made up.
    internal private(set) var implicitBytes = 0

    internal var count: Int { index.count }

    /// Every entry, in no order.
    internal var unordered: [ArchiveEntry] { slots.compactMap { $0 } }

    /// Every entry in archive order.
    ///
    /// Sorted once; after that the order is kept up as entries come and go, so a write that follows
    /// a change does not sort the whole archive again.
    internal var ordered: [ArchiveEntry] {
        mutating get {
            sort().compactMap { slots[Int($0)] }
        }
    }

    internal static func name(of path: String) -> String {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: 0x2F) else {
            return path
        }
        return String(decoding: bytes[bytes.index(after: slash)...], as: UTF8.self)
    }

    internal static func parent(of path: String) -> String {
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: 0x2F) else {
            return ""
        }
        return String(decoding: bytes[..<slash], as: UTF8.self)
    }

    internal static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// The names of a path, cut at the byte `/`.
    internal static func names(of path: String) -> [String] {
        path.utf8.split(separator: 0x2F, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The part of `path` below `folder`; nil when it does not lie below it.
    ///
    /// Compared byte by byte: two paths that look alike but are written differently are two paths.
    internal static func relative(_ path: String, to folder: String) -> String? {
        if folder.isEmpty {
            return path
        }
        let (bytes, prefix) = (path.utf8, folder.utf8)
        guard bytes.count > prefix.count + 1, bytes.starts(with: prefix),
            bytes[bytes.index(bytes.startIndex, offsetBy: prefix.count)] == 0x2F
        else {
            return nil
        }
        return String(decoding: bytes.dropFirst(prefix.count + 1), as: UTF8.self)
    }

    /// A member's path as the tree keys it; nil for a path that is not shown.
    ///
    /// Leading slashes and `.` are dropped. A path is refused altogether when it has a `..` or a
    /// NUL byte, is longer or deeper than the limits above, or holds a `/` that Swift would not see
    /// as a character of its own (one followed by a combining mark, or preceded by a character that
    /// binds what follows): no member can then name a place outside the folder an archive is
    /// unpacked into, whichever way its path is taken apart.
    internal static func normalized(_ raw: String) -> String? {
        let bytes = raw.utf8
        var parts: [Substring.UTF8View.SubSequence] = []
        var (total, isASCII) = (0, true)
        for part in bytes.split(separator: 0x2F, omittingEmptySubsequences: true) {
            var dots = 0
            for byte in part {
                if byte == 0 {
                    return nil
                }
                if byte >= 0x80 { isASCII = false }
                dots = byte == 0x2E && dots >= 0 ? dots + 1 : -1
            }
            if dots == 1, part.count == 1 { continue }
            if dots == 2, part.count == 2 {
                return nil
            }
            parts.append(part)
            total += part.count + 1
            guard parts.count <= maxDepth, total - 1 <= maxPathBytes else {
                return nil
            }
        }
        guard !parts.isEmpty else {
            return nil
        }
        var joined: String
        if total - 1 == bytes.count {
            // Nothing was dropped: the path is the text as it came, and shares its storage.
            joined = raw
            joined.makeContiguousUTF8()
        } else {
            joined = parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
        }
        // Plain ASCII has no character that joins its neighbour.
        if !isASCII, joined.split(separator: "/", omittingEmptySubsequences: false).count != parts.count {
            return nil
        }
        return joined
    }

    internal func contains(where matches: (ArchiveEntry) -> Bool) -> Bool {
        slots.contains { $0.map(matches) == true }
    }

    /// Makes room for this many entries at once, when their number is known beforehand, and
    /// for some folders that have to be made up besides: room that is found too small is
    /// doubled, which for a large archive is a lot of memory for a few more entries.
    internal mutating func reserve(_ count: Int) {
        slots.reserveCapacity(count + count / 16 + 256)
        index.reserveCapacity(count)
    }

    private func slot(of path: String) -> Int32? {
        path.isEmpty ? Self.top : index[path]
    }

    internal func entry(_ path: String) -> ArchiveEntry? {
        index[path].flatMap { slots[Int($0)] }
    }

    internal func isDirectory(_ path: String) -> Bool {
        path.isEmpty || entry(path)?.isDirectory == true
    }

    /// The entries directly inside a folder; nil when the path is not a folder.
    ///
    /// Every folder has a list of its own (`insert` makes it), the top folder from the start.
    internal func children(of path: String) -> [ArchiveEntry]? {
        guard isDirectory(path), let folder = slot(of: path), let places = children[folder] else {
            return nil
        }
        return places.compactMap { slots[Int($0)] }
    }

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

    /// The position of the entry in a place that is taken: the sequence holds only those, and
    /// an entry is listed and unlisted while it stands in its place.
    private func order(at place: Int32) -> Int {
        slots[Int(place)]!.order
    }

    /// The sequence, sorted first if it has not been yet.
    @discardableResult
    private mutating func sort() -> [Int32] {
        if let sorted = sequence {
            return sorted
        }
        var places: [Int32] = []
        places.reserveCapacity(index.count)
        for place in slots.indices where slots[place] != nil { places.append(Int32(place)) }
        places.sort { order(at: $0) < order(at: $1) }
        sequence = places
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
            if self.order(at: sequence[middle]) < order { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // The sequence is changed where it lies: no copy of it is ever held beside it. Both are
    // called while the entry stands in its place.
    private mutating func list(_ place: Int32) {
        guard sequence != nil else {
            return
        }
        let order = self.order(at: place)
        if let last = sequence!.last, self.order(at: last) >= order {
            let position = self.place(of: order, in: sequence!)
            sequence!.insert(place, at: position)
        } else {
            sequence!.append(place)
        }
    }

    private mutating func unlist(_ place: Int32) {
        guard sequence != nil else {
            return
        }
        // The entries that share its position stand together from here, and it is among them.
        let start = self.place(of: order(at: place), in: sequence!)
        let position = sequence![start...].firstIndex(of: place)
        if let position { sequence!.remove(at: position) }
    }

    /// Puts an entry into a free place.
    private mutating func seat(_ entry: ArchiveEntry) -> Int32 {
        let place: Int32
        if let free = freeSlots.popLast() {
            slots[Int(free)] = entry
            place = free
        } else {
            slots.append(entry)
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
        guard let place = index[path], slots[Int(place)] != nil else {
            return
        }
        change(&slots[Int(place)]!)
    }

    /// Adds an entry, or replaces the one at the same path; missing folders above it are made
    /// up.
    ///
    /// With `keepingOrder` the entry keeps the position it carries.
    internal mutating func insert(_ entry: ArchiveEntry, keepingOrder: Bool = false) {
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
        var place: Int32
        if let taken, let existing {
            place = taken
            if existing.order != entry.order {
                unlist(place)
                slots[Int(place)] = entry
                list(place)
            } else {
                slots[Int(place)] = entry
            }
        } else {
            place = seat(entry)
        }
        if entry.isImplicit { implicitBytes += entry.path.utf8.count }
        if entry.isDirectory, children[place] == nil { children[place] = [] }
        var path = entry.path
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
                            modified: entry.modified,
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

/// A `FileReader` over a member of an archive.
///
/// Members are streams: reading on is cheap, going back means starting again from the front, and a
/// member behind a long stretch of decompression is a long way off. Used by one thread; only
/// `interrupt()` may be called from another, which ends the read or seek that is under way and
/// every later one.
///
/// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` touches only
/// `slot`, which is safe from any thread.
internal final class ArchiveMemberReader: FileReader, @unchecked Sendable {
    private let open: (InterruptSlot) throws -> any ByteStream
    private let slot = InterruptSlot()
    private var stream: any ByteStream?
    private var position: UInt64 = 0

    /// `cancellation` ends the opening (and only that) once it is set.
    internal init(cancellation: CancellationFlag? = nil, _ open: @escaping (InterruptSlot) throws -> any ByteStream)
        throws
    {
        self.open = open
        let slot = self.slot
        let registration = cancellation?.onCancel { [weak slot] in slot?.interrupt() }
        defer { withExtendedLifetime(registration) {} }
        // Opened at once, so that a missing password or a damaged header fails here.
        stream = try open(slot)
        do { try checkInterrupted() } catch {
            closeStream()
            throw error
        }
    }

    private func checkInterrupted() throws {
        if slot.isInterrupted { throw ArchiveError.cancelled }
    }

    internal func interrupt() {
        slot.interrupt()
    }

    internal func read(upToCount count: Int) throws -> Data? {
        try checkInterrupted()
        if stream == nil { stream = try open(slot) }
        guard let block = try stream?.read(upToCount: count) else {
            return nil
        }
        position += UInt64(block.count)
        return block
    }

    internal func seek(to offset: UInt64) throws {
        try checkInterrupted()
        if stream == nil {
            stream = try open(slot)
            position = 0
        }
        // A member that lies in a file as it is (TAR, an unpacked copy) is read at any place.
        if let seekable = stream as? (any SeekableStream) {
            seekable.seek(to: offset)
            position = offset
            return
        }
        if offset < position {
            closeStream()
            stream = try open(slot)
            position = 0
        }
        while position < offset {
            try checkInterrupted()
            guard let block = try stream?.read(upToCount: Int(min(offset - position, 1 << 18))) else { break }
            position += UInt64(block.count)
        }
    }

    internal func close() {
        closeStream()
    }

    /// The slot lets go of the stream first: a stream that is kept for the next reader must
    /// not hear of a request that comes after this reader is done with it.
    private func closeStream() {
        slot.release()
        stream?.close()
        stream = nil
    }
}
