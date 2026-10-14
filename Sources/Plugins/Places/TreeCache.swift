import AFMKernel
import Foundation

/// The directory trees that were read, kept so the tree window opens at once (spec 12 ›
/// Reading the tree and the tree cache). Each root (with and without hidden folders, which
/// are different trees) has its list of folders in memory and in a file of its own: the
/// specification's `treeinfo.wc`, except that the files live in the program's Application
/// Support folder and never in the folders that were scanned.
///
/// The file is plain text: a `root=<url>` line, an optional `state=partial` line, then one
/// `[relative/path]` line per folder and one `(relative/path)` line per folder that was not
/// read (a volume mounted inside, or a place the scan did not reach).
///
/// The files and their folder are private to the user (modes 0600 and 0700): they list the
/// folders of every disk that was scanned. A file is read and written up to `fileLimit` bytes
/// only, and a path with a line break in it is not written (it would add lines).
///
/// **Threading.** Safe to use from any thread. Reading and writing files blocks, so everything
/// but `noteFolder` is meant for a background thread. The files for folders added by
/// `noteFolder` are written a little later, on the cache's own queue, one write for a burst of
/// additions.
public final class TreeCache {
    /// What the cache holds for one root.
    public struct Entry: Equatable {
        /// The folders below the root as relative paths, parents before their children.
        public var paths: [String]
        /// The folders among them whose subfolders are not known.
        public var unscanned: [String] = []
        /// False for a scan that was stopped half-way.
        public var isComplete = true
    }

    /// Above this size a file is only rewritten by a scan, not for single new folders
    /// (`TreeUpdateLimit`, 2048 KB).
    public static let updateLimit = 2048 * 1024
    /// How long additions are collected before the file is written.
    public static let writeDelay: TimeInterval = 2
    /// The most a cache file is read from or written to; a tree of more folders is kept in
    /// memory only (as a partial tree on disk) and read again by the scan.
    public static let fileLimit = 64 << 20
    /// How many trees are kept in memory; the others are read from their files when needed.
    static let memoryLimit = 8
    /// How many folders all the trees in memory may have together (about 100 bytes each, so
    /// ~200 MB): above that, trees that are not waiting to be written are let go, whatever their number.
    static let memoryPathLimit = 2_000_000

    private final class Slot {
        var entry: Entry
        let root: URL
        let showHidden: Bool
        /// The set of `entry.paths`, made when a folder is first noted.
        var known: Set<String>?
        /// The size of the file as it would be written.
        var bytes: Int
        var isDirty = false

        init(_ entry: Entry, root: URL, showHidden: Bool) {
            self.entry = entry
            self.root = root
            self.showHidden = showHidden
            bytes = entry.paths.reduce(0) { $0 + $1.utf8.count + 3 }
        }
    }

    private let directory: URL?
    private let lock = NSLock()
    private var memory: [String: Slot] = [:]
    private var writeIsScheduled = false
    /// Which write of each file is the latest asked for: an older one that comes late is not
    /// written, so a file never goes back to an earlier state.
    private var tickets: [String: Int] = [:]
    private var nextTicket = 0
    private let writeLock = NSLock()
    private let updates = DispatchQueue(label: "afm.places.tree-cache", qos: .utility)

    /// `directory` is where the files go; nil keeps the trees in memory only.
    public init(directory: URL?) {
        self.directory = directory
    }

    private static func key(_ root: URL, _ showHidden: Bool) -> String {
        root.locationKey + (showHidden ? "\u{0}hidden" : "")
    }

    /// The file of a root; nil for a cache without files.
    public func fileURL(for root: URL, showHidden: Bool = false) -> URL? {
        let key = TreeCache.key(root, showHidden)
        // A readable name, plus a checksum of the whole key so two roots never share a file.
        let readable = String(root.locationKey.map { $0.isLetter || $0.isNumber ? $0 : "_" }.suffix(60))
        let checksum = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return directory?.appendingPathComponent(
            "treeinfo-\(readable)-\(String(checksum, radix: 16)).txt", isDirectory: false)
    }

    /// What is known of the tree below `root`, from memory or from the file; nil when the
    /// tree was never read.
    public func entry(for root: URL, showHidden: Bool = false) -> Entry? {
        let key = TreeCache.key(root, showHidden)
        lock.lock()
        let remembered = memory[key]?.entry
        lock.unlock()
        if let remembered { return remembered }
        guard let file = fileURL(for: root, showHidden: showHidden), let data = TreeCache.read(file),
            let text = String(data: data, encoding: .utf8), let entry = TreeCache.parseEntry(text, root: root)
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Another thread may have been quicker, or stored something newer. The entry is copied
        // while the lock is held: `note` appends to it under the lock.
        let slot = memory[key] ?? Slot(entry, root: root, showHidden: showHidden)
        memory[key] = slot
        trimMemory(keeping: key)
        return slot.entry
    }

    /// Lets the trees go from memory that are not waiting to be written, down to the limit.
    /// Under the lock.
    private func trimMemory(keeping key: String) {
        var total = memory.values.reduce(0) { $0 + $1.entry.paths.count }
        while memory.count > TreeCache.memoryLimit || total > TreeCache.memoryPathLimit,
            let other = memory.first(where: { $0.key != key && !$0.value.isDirty })
        {
            total -= other.value.entry.paths.count
            memory[other.key] = nil
        }
    }

    /// A cache file's bytes; nil when it is missing, unreadable or over `fileLimit`.
    private static func read(_ file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileLimit + 1), data.count <= fileLimit else { return nil }
        return data
    }

    /// The folders below `root` as relative paths; nil when the tree was never read.
    public func paths(for root: URL, showHidden: Bool = false) -> [String]? {
        entry(for: root, showHidden: showHidden)?.paths
    }

    /// Keeps the tree of `root` and writes its file.
    public func store(
        _ paths: [String], unscanned: [String] = [], isComplete: Bool = true, for root: URL, showHidden: Bool = false
    ) {
        let entry = Entry(paths: paths, unscanned: unscanned, isComplete: isComplete)
        let key = TreeCache.key(root, showHidden)
        lock.lock()
        memory[key] = Slot(entry, root: root, showHidden: showHidden)
        trimMemory(keeping: key)
        let ticket = newTicket(for: key)
        lock.unlock()
        write(entry, for: root, showHidden: showHidden, ticket: ticket)
    }

    /// Forgets the trees of `root`, with and without hidden folders, in memory and on disk.
    public func remove(for root: URL) {
        var removals: [(file: URL, ticket: Int, key: String)] = []
        lock.lock()
        for hidden in [false, true] {
            let key = TreeCache.key(root, hidden)
            memory[key] = nil
            // A write of this tree that is still on its way must not bring the file back.
            if let file = fileURL(for: root, showHidden: hidden) { removals.append((file, newTicket(for: key), key)) }
        }
        lock.unlock()
        writeLock.lock()
        defer { writeLock.unlock() }
        for removal in removals { try? FileManager.default.removeItem(at: removal.file) }
    }

    /// A folder is known to exist (a panel is showing it): if the tree of `root` is in memory
    /// and does not have it, it is added, in the background and without scanning anything.
    /// Returns at once.
    public func noteFolder(_ relativePath: String, below root: URL) {
        updates.async { [self] in note(relativePath, below: root) }
    }

    /// The same for a folder whose root is worked out on the cache's queue (asking the disks
    /// for it takes a while): `resolve` gives the path below the root, or nil.
    public func noteFolder(resolving resolve: @escaping () -> (path: String, root: URL)?) {
        updates.async { [self] in
            if let found = resolve() { note(found.path, below: found.root) }
        }
    }

    private func note(_ relativePath: String, below root: URL) {
        guard !relativePath.isEmpty else { return }
        let names = DirectoryTree.components(of: relativePath)
        guard !names.isEmpty else { return }
        let chain = names.indices.map { names[...$0].joined(separator: "/") }
        // A tree without hidden folders has no place for a folder below a hidden one.
        let isHidden = names.contains { $0.utf8.first == UInt8(ascii: ".") }
        lock.lock()
        defer { lock.unlock() }
        for showHidden in isHidden ? [true] : [false, true] {
            guard let slot = memory[TreeCache.key(root, showHidden)] else { continue }
            if slot.known == nil { slot.known = Set(slot.entry.paths) }
            guard slot.known?.contains(relativePath) == false else { continue }
            // The folder's parents come with it; a reader takes the lines in any order. Nobody
            // has read these folders, so their subfolders are not known: the tree reads them
            // when they are opened (it would otherwise show them as folders with nothing in them).
            for path in chain where slot.known?.insert(path).inserted == true {
                slot.entry.paths.append(path)
                slot.entry.unscanned.append(path)
                slot.bytes += path.utf8.count + 3
            }
            slot.isDirty = slot.bytes <= TreeCache.updateLimit
        }
        guard !writeIsScheduled else { return }
        writeIsScheduled = true
        updates.asyncAfter(deadline: .now() + TreeCache.writeDelay) { [self] in flush() }
    }

    /// Writes the files of the trees that changed.
    public func flush() {
        var pending: [(root: URL, hidden: Bool, entry: Entry)] = []
        lock.lock()
        writeIsScheduled = false
        var tickets: [Int] = []
        for (key, slot) in memory where slot.isDirty {
            slot.isDirty = false
            pending.append((slot.root, slot.showHidden, slot.entry))
            tickets.append(newTicket(for: key))
        }
        // The set that tells whether a folder is known doubles the memory of a long list; a long
        // tree gets it made again when the next folder is noted.
        for slot in memory.values where slot.entry.paths.count > 100_000 { slot.known = nil }
        lock.unlock()
        for (item, ticket) in zip(pending, tickets) {
            write(item.entry, for: item.root, showHidden: item.hidden, ticket: ticket)
        }
    }

    /// Writes what is waiting and waits until the updates handed to `noteFolder` are done; for tests.
    public func waitForUpdates() {
        updates.sync {}
        flush()
    }

    /// Under the lock.
    private func newTicket(for key: String) -> Int {
        nextTicket += 1
        tickets[key] = nextTicket
        return nextTicket
    }

    private func write(_ entry: Entry, for root: URL, showHidden: Bool, ticket: Int) {
        guard let directory, let file = fileURL(for: root, showHidden: showHidden) else { return }
        let key = TreeCache.key(root, showHidden)
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let isLatest = tickets[key] == ticket
        lock.unlock()
        guard isLatest else { return }
        // Private to the user: the folder and the file are made so from the start.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        // Too big for a file: what is there would be out of date, so it goes.
        if !TreeCache.writePrivately(entry, root: root, to: file) { try? FileManager.default.removeItem(at: file) }
    }

    /// Writes a file nobody else can read: a new file of mode 0600 that replaces the old one.
    static func writePrivately(_ data: Data, to file: URL) {
        let temporary = file.path + ".tmp\(getpid())"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        let ok = data.withUnsafeBytes { buffer in write(descriptor, buffer) }
        close(descriptor)
        if ok, rename(temporary, file.path) == 0 { return }
        unlink(temporary)
    }

    /// The tree written to the file in pieces of about a megabyte, so that a tree of a million
    /// folders is never held again as one text (and then as one `Data`). False when it would
    /// be more than `fileLimit` (nothing replaces the old file then).
    @discardableResult
    static func writePrivately(_ entry: Entry, root: URL, to file: URL) -> Bool {
        let temporary = file.path + ".tmp\(getpid())"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return true }
        var total = 0
        var fits = true
        var ok = true
        format(entry, root: root) { piece in
            total += piece.count
            guard total <= fileLimit else {
                fits = false
                return false
            }
            ok = piece.withUnsafeBytes { buffer in write(descriptor, buffer) }
            return ok
        }
        close(descriptor)
        if fits, ok, rename(temporary, file.path) == 0 { return true }
        unlink(temporary)
        return fits
    }

    private static func write(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) -> Bool {
        var written = 0
        while written < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
            if count <= 0 { return false }
            written += count
        }
        return true
    }

    static func format(_ paths: [String], root: URL) -> String {
        format(Entry(paths: paths), root: root)
    }

    static func format(_ entry: Entry, root: URL) -> String {
        var data = Data()
        format(entry, root: root) { piece in
            data.append(piece)
            return true
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The file's text in pieces of about a megabyte, for as long as `emit` says to go on.
    static func format(_ entry: Entry, root: URL, emit: (Data) -> Bool) {
        // A path with a line break would add lines to the file; such a folder is left out, and
        // the tree then is not complete.
        func isPlain(_ path: String) -> Bool { !path.utf8.contains { $0 == 0x0A || $0 == 0x0D } }
        let isComplete = entry.isComplete && entry.paths.allSatisfy(isPlain)
        var piece = Data("root=\(DirectoryHistory.stored(root))\n".utf8)
        if !isComplete { piece.append(contentsOf: "state=partial\n".utf8) }
        piece.reserveCapacity(1 << 20 + 4096)
        func line(_ open: UInt8, _ path: String, _ close: UInt8) -> Bool {
            piece.append(open)
            piece.append(contentsOf: path.utf8)
            piece.append(close)
            piece.append(0x0A)
            guard piece.count >= 1 << 20 else { return true }
            defer { piece.removeAll(keepingCapacity: true) }
            return emit(piece)
        }
        for path in entry.paths where isPlain(path) { if !line(0x5B, path, 0x5D) { return } }
        for path in entry.unscanned where isPlain(path) { if !line(0x28, path, 0x29) { return } }
        if !piece.isEmpty { _ = emit(piece) }
    }

    /// The paths of a cache file; nil when the file is not one for `root`.
    static func parse(_ text: String, root: URL) -> [String]? {
        parseEntry(text, root: root)?.paths
    }

    /// Read byte by byte: the lines end at the line feed byte and are told apart by their
    /// first and last byte, not by characters (a combining mark after `[` makes one
    /// character with it, and a name that began with one would be lost).
    static func parseEntry(_ text: String, root: URL) -> Entry? {
        var text = text
        return text.withUTF8 { bytes -> Entry? in
            var entry = Entry(paths: [])
            var isFirst = true
            var position = 0
            while position < bytes.count {
                var end = position
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[position..<end])
                position = end + 1
                guard !line.isEmpty else { continue }
                if isFirst {
                    isFirst = false
                    let prefix = Array("root=".utf8)
                    guard line.count >= prefix.count, Array(line.prefix(prefix.count)) == prefix,
                        URL(string: String(decoding: line.dropFirst(prefix.count), as: UTF8.self))?.locationKey
                            == root.locationKey
                    else { return nil }
                    continue
                }
                let (first, last) = (line[0], line[line.count - 1])
                if line.count > 2, first == 0x5B, last == 0x5D {
                    entry.paths.append(String(decoding: line.dropFirst().dropLast(), as: UTF8.self))
                } else if line.count > 2, first == 0x28, last == 0x29 {
                    entry.unscanned.append(String(decoding: line.dropFirst().dropLast(), as: UTF8.self))
                } else if line.count == "state=partial".utf8.count, Array(line) == Array("state=partial".utf8) {
                    entry.isComplete = false
                }
            }
            return isFirst ? nil : entry
        }
    }
}
