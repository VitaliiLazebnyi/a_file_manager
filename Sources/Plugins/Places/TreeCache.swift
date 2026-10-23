import AFMKernel
public import Foundation

/// The directory trees that were read, kept so the tree window opens at once (spec 12 ›
/// Reading the tree and the tree cache).
///
/// Each root (with and without hidden folders, which are different trees) has its list of folders
/// in memory and in a file of its own: the specification's `treeinfo.wc`, except that the files
/// live in the program's Application Support folder and never in the folders that were scanned.
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
///
/// All state is guarded by `lock` (the slots too: they are only touched while it is held);
/// `writeLock` keeps two writes of the files from running at once.
public final class TreeCache: @unchecked Sendable {
    /// What the cache holds for one root.
    public struct Entry: Equatable, Sendable {
        /// The folders below the root as relative paths, parents before their children.
        public var paths: [String]
        /// The folders among them whose subfolders are not known.
        public var unscanned: [String] = []
        /// False for a scan that was stopped half-way.
        public var isComplete = true
    }

    /// The tree of one root in memory, with what it takes to write it.
    private final class Slot {
        /// The tree.
        var entry: Entry
        /// The root it is the tree of.
        let root: URL
        /// Whether it is the tree with hidden folders.
        let showHidden: Bool
        /// The set of `entry.paths`, made when a folder is first noted; empty until then, and
        /// again after a write of a long tree.
        var known: Set<String> = []
        /// The size of the file as it would be written.
        var bytes: Int
        /// Whether the tree changed since its file was last written.
        var isDirty = false

        /// A slot for `entry`, the tree of `root`, with nothing to write yet.
        init(_ entry: Entry, root: URL, showHidden: Bool) {
            self.entry = entry
            self.root = root
            self.showHidden = showHidden
            bytes = entry.paths.reduce(0) { $0 + $1.utf8.count + 3 }
        }

        deinit {
            // Nothing to release.
        }
    }

    /// A tree to be written, copied while the lock is held.
    private struct Write {
        /// The tree.
        let entry: Entry
        /// The root it is the tree of.
        let root: URL
        /// Whether it is the tree with hidden folders.
        let showHidden: Bool
        /// The write's ticket: it is written only while it is the latest asked for.
        let ticket: Int
    }

    /// Above this size a file is only rewritten by a scan, not for single new folders
    /// (`TreeUpdateLimit`, 2048 KB).
    public static let updateLimit = 2_048 * 1_024
    /// How long additions are collected before the file is written.
    public static let writeDelay: TimeInterval = 2
    /// The most a cache file is read from or written to; a tree of more folders is kept in
    /// memory only (as a partial tree on disk) and read again by the scan.
    public static let fileLimit = 64 << 20
    /// How many trees are kept in memory; the others are read from their files when needed.
    internal static let memoryLimit = 8
    /// How many folders all the trees in memory may have together (about 100 bytes each, so
    /// ~200 MB): above that, trees that are not waiting to be written are let go, whatever their number.
    internal static let memoryPathLimit = 2_000_000

    /// Where the files go; nil keeps the trees in memory only.
    private let directory: URL?
    /// Guards everything below and the slots.
    private let lock = NSLock()
    /// The trees in memory, by `key(_:_:)`.
    private var memory: [String: Slot] = [:]
    /// Whether a write of the noted folders is waiting on `updates`.
    private var writeIsScheduled = false
    /// Which write of each file is the latest asked for: an older one that comes late is not
    /// written, so a file never goes back to an earlier state.
    private var tickets: [String: Int] = [:]
    /// The last ticket handed out.
    private var nextTicket = 0
    /// Keeps two writes of the files from running at once.
    private let writeLock = NSLock()
    /// The cache's own queue, for noted folders and the writes they cause.
    private let updates = DispatchQueue(label: "afm.places.tree-cache", qos: .utility)

    /// `directory` is where the files go; nil keeps the trees in memory only.
    public init(directory: URL?) {
        self.directory = directory
    }

    /// The key of a tree in `memory` and in the file names.
    private static func key(_ root: URL, _ showHidden: Bool) -> String {
        root.locationKey + (showHidden ? "\u{0}hidden" : "")
    }

    /// A cache file's bytes; nil when it is missing, unreadable or over `fileLimit`.
    private static func read(_ file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileLimit + 1), data.count <= fileLimit else {
            return nil
        }
        return data
    }

    /// The file of a root; nil for a cache without files.
    public func fileURL(for root: URL, showHidden: Bool = false) -> URL? {
        let key = Self.key(root, showHidden)
        // A readable name, plus a checksum of the whole key so two roots never share a file.
        let readable = String(root.locationKey.map { $0.isLetter || $0.isNumber ? $0 : "_" }.suffix(60))
        let checksum = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return directory?
            .appendingPathComponent(
                "treeinfo-\(readable)-\(String(checksum, radix: 16)).txt",
                isDirectory: false
            )
    }

    /// What is known of the tree below `root`, from memory or from the file; nil when the
    /// tree was never read.
    public func entry(for root: URL, showHidden: Bool = false) -> Entry? {
        let key = Self.key(root, showHidden)
        lock.lock()
        let remembered = memory[key]?.entry
        lock.unlock()
        if let remembered {
            return remembered
        }
        guard let file = fileURL(for: root, showHidden: showHidden), let data = Self.read(file),
            let text = String(data: data, encoding: .utf8), let entry = Self.parseEntry(text, root: root)
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
    ///
    /// Under the lock.
    private func trimMemory(keeping key: String) {
        var total = memory.values.reduce(0) { $0 + $1.entry.paths.count }
        while memory.count > Self.memoryLimit || total > Self.memoryPathLimit,
            let other = memory.first(where: { $0.key != key && !$0.value.isDirty })
        {
            total -= other.value.entry.paths.count
            memory[other.key] = nil
        }
    }

    /// Keeps the tree of `root` and writes its file.
    public func store(
        _ paths: [String],
        for root: URL,
        unscanned: [String] = [],
        isComplete: Bool = true,
        showHidden: Bool = false
    ) {
        let entry = Entry(paths: paths, unscanned: unscanned, isComplete: isComplete)
        let key = Self.key(root, showHidden)
        lock.lock()
        memory[key] = Slot(entry, root: root, showHidden: showHidden)
        trimMemory(keeping: key)
        let ticket = newTicket(for: key)
        lock.unlock()
        write(Write(entry: entry, root: root, showHidden: showHidden, ticket: ticket))
    }

    /// Forgets the trees of `root`, with and without hidden folders, in memory and on disk.
    public func remove(for root: URL) {
        var files: [URL] = []
        lock.lock()
        for hidden in [false, true] {
            let key = Self.key(root, hidden)
            memory[key] = nil
            // A write of this tree that is still on its way must not bring the file back: it no
            // longer has the latest ticket.
            if let file = fileURL(for: root, showHidden: hidden) {
                _ = newTicket(for: key)
                files.append(file)
            }
        }
        lock.unlock()
        writeLock.lock()
        defer { writeLock.unlock() }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A folder is known to exist (a panel is showing it): if the tree of `root` is in memory
    /// and does not have it, it is added, in the background and without scanning anything.
    ///
    /// Returns at once.
    public func noteFolder(_ relativePath: String, below root: URL) {
        updates.async { [self] in note(relativePath, below: root) }
    }

    /// The same for a folder whose root is worked out on the cache's queue (asking the disks
    /// for it takes a while): `resolve` gives the path below the root, or nil.
    @preconcurrency
    public func noteFolder(resolving resolve: @escaping @Sendable () -> (path: String, root: URL)?) {
        updates.async { [self] in
            if let found = resolve() {
                note(found.path, below: found.root)
            }
        }
    }

    /// Adds `relativePath` and its parents to the trees of `root` in memory that lack them; on `updates`.
    private func note(_ relativePath: String, below root: URL) {
        guard !relativePath.isEmpty else {
            return
        }
        let names = DirectoryTree.components(of: relativePath)
        guard !names.isEmpty else {
            return
        }
        let chain = names.indices.map { names[...$0].joined(separator: "/") }
        // A tree without hidden folders has no place for a folder below a hidden one.
        let isHidden = names.contains { $0.utf8.first == UInt8(ascii: ".") }
        lock.lock()
        defer { lock.unlock() }
        for showHidden in isHidden ? [true] : [false, true] {
            guard let slot = memory[Self.key(root, showHidden)] else { continue }
            if slot.known.isEmpty {
                slot.known = Set(slot.entry.paths)
            }
            guard !slot.known.contains(relativePath) else { continue }
            // The folder's parents come with it; a reader takes the lines in any order. Nobody
            // has read these folders, so their subfolders are not known: the tree reads them
            // when they are opened (it would otherwise show them as folders with nothing in them).
            for path in chain where slot.known.insert(path).inserted {
                slot.entry.paths.append(path)
                slot.entry.unscanned.append(path)
                slot.bytes += path.utf8.count + 3
            }
            slot.isDirty = slot.bytes <= Self.updateLimit
        }
        guard !writeIsScheduled else {
            return
        }
        writeIsScheduled = true
        updates.asyncAfter(deadline: .now() + Self.writeDelay) { [self] in flush() }
    }

    /// Writes the files of the trees that changed.
    public func flush() {
        var pending: [Write] = []
        lock.lock()
        writeIsScheduled = false
        for (key, slot) in memory where slot.isDirty {
            slot.isDirty = false
            pending.append(
                Write(entry: slot.entry, root: slot.root, showHidden: slot.showHidden, ticket: newTicket(for: key))
            )
        }
        // The set that tells whether a folder is known doubles the memory of a long list; a long
        // tree gets it made again when the next folder is noted.
        for slot in memory.values where slot.entry.paths.count > 100_000 {
            slot.known = []
        }
        lock.unlock()
        for item in pending {
            write(item)
        }
    }

    /// Writes what is waiting and waits until the updates handed to `noteFolder` are done; for tests.
    public func waitForUpdates() {
        updates.sync {
            // Nothing to do: that this runs at all means the updates before it are done.
        }
        flush()
    }

    /// A ticket for the next write of the tree under `key`, which makes every earlier one stale.
    ///
    /// Under the lock.
    private func newTicket(for key: String) -> Int {
        nextTicket += 1
        tickets[key] = nextTicket
        return nextTicket
    }

    /// Writes the file of a tree, unless a later write was asked for in the meantime; blocks.
    private func write(_ item: Write) {
        guard let directory, let file = fileURL(for: item.root, showHidden: item.showHidden) else {
            return
        }
        let key = Self.key(item.root, item.showHidden)
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let isLatest = tickets[key] == item.ticket
        lock.unlock()
        guard isLatest else {
            return
        }
        // Private to the user: the folder and the file are made so from the start.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(directory.path, 0o700)
        // Too big for a file: what is there would be out of date, so it goes.
        if !Self.writePrivately(item.entry, root: item.root, to: file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    deinit {
        // Nothing to release: a write still waiting on `updates` holds the cache until it ran.
    }
}
