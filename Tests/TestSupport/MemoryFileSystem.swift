import AFMKernel
import Foundation

/// A file system that exists only in memory (`mem:` URLs). It stands in for the kinds of
/// location the program does not have yet (archives, servers) and shows that panels, jobs and
/// search need nothing but the provider interface. It can be made slow, read-only or awkward
/// in the ways a real remote file system is.
public final class MemoryFileSystem: FileSystemProvider {
    public let scheme: String
    public var capabilities: FileSystemCapabilities {
        get { settings.withLock { _capabilities } }
        set { settings.withLock { _capabilities = newValue } }
    }
    private var _capabilities: FileSystemCapabilities = [.write]
    public let readsRootedPaths = true

    private enum Node {
        case directory
        case file(Data, Date, UInt16)
    }

    /// By path, with every byte that is not ASCII written as `%XX`: two names that differ
    /// only in how an accent is written (`é` in one character or in two) are equal as
    /// `String`s, and here they are two files, as on a server or a disk from elsewhere.
    private var nodes: [String: Node] = ["/": .directory]
    private let lock = NSLock()
    /// Guards the settings below (the `_…` values): a test changes them while other threads
    /// are inside the file system and read them. A lock of its own, because they are read
    /// with `lock` held as well.
    private let settings = NSLock()
    /// A copy within this file system reports progress in blocks of this size.
    public var copyBlockSize: Int {
        get { settings.withLock { _copyBlockSize } }
        set { settings.withLock { _copyBlockSize = newValue } }
    }
    private var _copyBlockSize: Int = 1 << 20
    /// When set, a directory is listed in batches of this many entries…
    public var listBatchSize: Int? {
        get { settings.withLock { _listBatchSize } }
        set { settings.withLock { _listBatchSize = newValue } }
    }
    private var _listBatchSize: Int?
    /// …with this pause before each batch, like a slow server.
    public var listBatchDelay: TimeInterval {
        get { settings.withLock { _listBatchDelay } }
        set { settings.withLock { _listBatchDelay = newValue } }
    }
    private var _listBatchDelay: TimeInterval = 0
    /// A pause before a listing starts to answer at all, like a server that first has to
    /// collect the whole directory.
    public var listStartDelay: TimeInterval {
        get { settings.withLock { _listStartDelay } }
        set { settings.withLock { _listStartDelay = newValue } }
    }
    private var _listStartDelay: TimeInterval = 0
    /// When true, the file system cannot copy by itself (two servers, two archives) and the
    /// caller has to stream.
    public var refusesInternalCopy: Bool {
        get { settings.withLock { _refusesInternalCopy } }
        set { settings.withLock { _refusesInternalCopy = newValue } }
    }
    private var _refusesInternalCopy: Bool = false
    /// Paths whose listing fails, like a folder without permission.
    public var unreadable: Set<String> {
        get { settings.withLock { _unreadable } }
        set { settings.withLock { _unreadable = newValue } }
    }
    private var _unreadable: Set<String> = []
    /// False makes it look like a network share (`VolumeInfo.isLocal`).
    public var isLocal: Bool {
        get { settings.withLock { _isLocal } }
        set { settings.withLock { _isLocal = newValue } }
    }
    private var _isLocal: Bool = true
    /// What `capabilities(for:)` answers; nil gives `capabilities` everywhere.
    public var capabilitiesAt: ((URL) -> FileSystemCapabilities)? {
        get { settings.withLock { _capabilitiesAt } }
        set { settings.withLock { _capabilitiesAt = newValue } }
    }
    private var _capabilitiesAt: ((URL) -> FileSystemCapabilities)?
    /// When true, a listing that was given a cancellation flag does not answer until the flag
    /// is set (or `releaseStalls()` is called), like a server that has stopped talking…
    public var stallsListings: Bool {
        get { settings.withLock { _stallsListings } }
        set { settings.withLock { _stallsListings = newValue } }
    }
    private var _stallsListings: Bool = false
    /// …and so do the reads of every reader and the writes of every writer opened meanwhile,
    /// until they are interrupted.
    public var stallsReads: Bool {
        get { settings.withLock { _stallsReads } }
        set { settings.withLock { _stallsReads = newValue } }
    }
    private var _stallsReads: Bool = false
    public var stallsWrites: Bool {
        get { settings.withLock { _stallsWrites } }
        set { settings.withLock { _stallsWrites = newValue } }
    }
    private var _stallsWrites: Bool = false
    /// When set, only listings of these paths stall (with `stallsListings`); nil stalls all.
    public var stalledPaths: Set<String>? {
        get { settings.withLock { _stalledPaths } }
        set { settings.withLock { _stalledPaths = newValue } }
    }
    private var _stalledPaths: Set<String>?
    /// When true, the changing calls that were given a cancellation flag (`createDirectory`,
    /// `remove`, `move`, `setAttributes`, `copyMetadata`, `setQuarantine`, `copy`) do not
    /// answer until the flag is set, when they throw `userCancelled` having changed
    /// nothing, or until `releaseStalls()`, when they go on.
    public var stallsChanges: Bool {
        get { settings.withLock { _stallsChanges } }
        set { settings.withLock { _stallsChanges = newValue } }
    }
    private var _stallsChanges: Bool = false
    /// The mark `quarantine(of:)` reports for every file; nil for none.
    public var quarantineValue: Data? {
        get { settings.withLock { _quarantineValue } }
        set { settings.withLock { _quarantineValue = newValue } }
    }
    private var _quarantineValue: Data?
    /// When set, `commit` fails with it.
    public var commitFailure: any Error? {
        get { settings.withLock { _commitFailure } }
        set { settings.withLock { _commitFailure = newValue } }
    }
    private var _commitFailure: any Error?
    /// False makes `copyMetadata` unsupported, as it is by default.
    public var keepsMetadata: Bool {
        get { settings.withLock { _keepsMetadata } }
        set { settings.withLock { _keepsMetadata = newValue } }
    }
    private var _keepsMetadata: Bool = false
    private var committed: [String] = []
    private var quarantined: [String: Data] = [:]
    private var metadataCopied: [(from: URL, to: String)] = []
    private var interrupted = 0
    private let stall = NSCondition()
    private var stallsReleased = false
    private var listed: [String] = []
    private var listing = 0
    private var mostListingAtOnce = 0
    /// Guarded by `stall`: what is waiting in a stall right now, by path.
    private var waitingListings: [String: Int] = [:]
    private var waitingChanges = 0
    private var flagged: [String] = []

    public init(scheme: String = "mem") {
        self.scheme = scheme
    }

    public struct NotFound: LocalizedError {
        let path: String
        public var errorDescription: String? { "\(path) does not exist." }
    }

    public struct Unreadable: LocalizedError {
        let path: String
        public var errorDescription: String? { "\(path) cannot be read." }
    }

    // MARK: Test helpers

    public func url(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url!
    }

    @discardableResult
    public func addFile(
        _ path: String, _ content: String = "x", modified: Date = Date(timeIntervalSince1970: 1_000_000),
        permissions: UInt16 = 0o644
    ) -> URL {
        let url = url(path)
        try? createDirectory(at: url.deletingLastPathComponent())
        synchronized { nodes[key(url)] = .file(Data(content.utf8), modified, permissions) }
        return url
    }

    @discardableResult
    public func addDirectory(_ path: String) -> URL {
        let url = url(path)
        try? createDirectory(at: url)
        return url
    }

    public func contents(_ path: String) -> String? {
        synchronized {
            if case .file(let data, _, _)? = nodes[key(url(path))] { return String(data: data, encoding: .utf8) }
            return nil
        }
    }

    public func exists(_ path: String) -> Bool {
        synchronized { nodes[key(url(path))] != nil }
    }

    /// Removes a path and everything below it, as another program would.
    public func removeTree(_ path: String) {
        let path = key(url(path))
        synchronized {
            for candidate in nodes.keys where candidate == path || candidate.hasPrefix(path + "/") {
                nodes[candidate] = nil
            }
        }
    }

    /// The directories a listing was asked for piece by piece (the way panels read), in the
    /// order of the requests: for counting how often the "server" was asked.
    public var listRequests: [String] { synchronized { listed } }

    public func listRequests(for path: String) -> Int { listRequests.filter { $0 == path }.count }

    /// The locations `commit` was called for, in order.
    public var commits: [String] { synchronized { committed } }
    /// Path → the mark `setQuarantine` put there.
    public var quarantineMarks: [String: Data] { synchronized { quarantined } }
    /// Every `copyMetadata` that was carried out: from which location to which path.
    public var metadataCopies: [(from: URL, to: String)] { synchronized { metadataCopied } }
    /// How many readers and writers were interrupted.
    public var interruptions: Int { synchronized { interrupted } }

    /// How many listings of `path` are waiting in a stall at this moment. A test that needs
    /// a listing to be under way waits for this to be 1 (a condition, not a length of time)
    /// and lets it go with `releaseStalls()` or its flag.
    public func stalledListings(of path: String) -> Int {
        stall.lock()
        defer { stall.unlock() }
        return waitingListings[path] ?? 0
    }

    /// How many changing calls are waiting in a stall at this moment (`stallsChanges`).
    public var stalledChanges: Int {
        stall.lock()
        defer { stall.unlock() }
        return waitingChanges
    }

    /// The changing calls that came with a cancellation flag, in order, as `"remove /a/b"`
    /// (`createDirectory`, `remove`, `move`, `setAttributes`, `copyMetadata`,
    /// `setQuarantine`, `copy`, with the path of the item changed): for checking that a
    /// caller that holds a flag passes it.
    public var flaggedChanges: [String] { synchronized { flagged } }

    /// Lets everything that stalls go on, as when the server answers after all.
    public func releaseStalls() {
        stall.lock()
        stallsReleased = true
        stall.broadcast()
        stall.unlock()
    }

    /// What a reader or writer waits on: `isInterrupted` is set under `stall`.
    fileprivate final class Stall {
        let condition: NSCondition
        let isReleased: () -> Bool
        let onInterrupt: () -> Void
        var isInterrupted = false

        init(_ condition: NSCondition, isReleased: @escaping () -> Bool, onInterrupt: @escaping () -> Void) {
            self.condition = condition
            self.isReleased = isReleased
            self.onInterrupt = onInterrupt
        }

        /// Returns when released; throws once interrupted, and from then on.
        func wait(stalling: Bool) throws {
            condition.lock()
            defer { condition.unlock() }
            while stalling, !isInterrupted, !isReleased() { condition.wait() }
            if isInterrupted { throw Interrupted() }
        }

        func interrupt() {
            condition.lock()
            let isFirst = !isInterrupted
            isInterrupted = true
            condition.broadcast()
            condition.unlock()
            if isFirst { onInterrupt() }
        }
    }

    public struct Interrupted: LocalizedError {
        public var errorDescription: String? { "The transfer was interrupted." }
    }

    private func makeStall() -> Stall {
        Stall(
            stall, isReleased: { [unowned self] in stallsReleased },
            onInterrupt: { [weak self] in self?.synchronized { self?.interrupted += 1 } })
    }

    /// The largest number of such listings that were ever under way at the same time.
    public var mostListingsAtOnce: Int { synchronized { mostListingAtOnce } }

    /// Every path below the root, sorted; for checking that nothing was left behind.
    public var allPaths: [String] {
        synchronized { nodes.keys.filter { $0 != "/" }.map(decoded).sorted() }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func key(_ url: URL) -> String {
        let path = url.standardized.path
        if path.isEmpty { return "/" }
        let trimmed = path.utf8.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.utf8.contains(where: { $0 >= 0x80 || $0 == 0x25 }) else { return trimmed }
        return trimmed.utf8.reduce(into: "") { key, byte in
            if byte >= 0x80 || byte == 0x25 {
                key += String(format: "%%%02X", byte)
            } else {
                key.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
    }

    /// The path a key stands for, as it was written.
    private func decoded(_ key: String) -> String {
        guard key.utf8.contains(0x25) else { return key }
        var bytes: [UInt8] = []
        var rest = key.utf8[...]
        while let byte = rest.first {
            if byte == 0x25, let value = UInt8(String(decoding: rest.dropFirst().prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(value)
                rest = rest.dropFirst(3)
            } else {
                bytes.append(byte)
                rest = rest.dropFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func parentKey(_ key: String) -> String {
        let parent = (key as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func makeItem(_ key: String, _ node: Node) -> FileItem {
        let key = decoded(key)
        // Cut by hand: the system's own way of taking the last part may rewrite the accents.
        let name = key == "/" ? key : String(key[key.index(after: key.lastIndex(of: "/") ?? key.startIndex)...])
        switch node {
        case .directory:
            return FileItem(
                url: url(key), name: name, isDirectory: true, isHidden: name.hasPrefix("."), permissions: 0o755)

        case .file(let data, let modified, let permissions):
            return FileItem(
                url: url(key), name: name, isDirectory: false, isHidden: name.hasPrefix("."),
                size: Int64(data.count), modified: modified, permissions: permissions)
        }
    }

    // MARK: FileSystemProvider

    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try synchronized {
            let parent = key(directory)
            if unreadable.contains(decoded(parent)) { throw Unreadable(path: decoded(parent)) }
            guard case .directory? = nodes[parent] else { throw NotFound(path: parent) }
            return nodes.filter { $0.key != "/" && parentKey($0.key) == parent }
                .map { makeItem($0.key, $0.value) }
                .filter { showHidden || !$0.isHidden }
                // Names that read the same keep one order: by their bytes.
                .sorted {
                    $0.name != $1.name ? $0.name < $1.name : $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
                }
        }
    }

    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try list(directory, showHidden: showHidden, cancellation: nil, receive: receive)
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try list(directory, showHidden: showHidden, cancellation: Optional(cancellation), receive: receive)
    }

    /// With a flag, a listing that stalls or pauses ends as soon as the flag is set, having
    /// delivered what it had: quietly, as a file system may.
    private func list(
        _ directory: URL, showHidden: Bool, cancellation: CancellationFlag?, receive: ([FileItem]) -> Bool
    ) throws {
        synchronized {
            listed.append(decoded(key(directory)))
            listing += 1
            mostListingAtOnce = max(mostListingAtOnce, listing)
        }
        defer { synchronized { listing -= 1 } }
        let waiting = cancellation.map { flag in
            flag.onCancel { [stall] in
                stall.lock()
                stall.broadcast()
                stall.unlock()
            }
        }
        defer { _ = waiting }
        /// False when the flag was set meanwhile.
        func pause(_ time: TimeInterval, stalling: Bool = false) -> Bool {
            guard let cancellation else {
                if time > 0 { Thread.sleep(forTimeInterval: time) }
                return true
            }
            let end = Date(timeIntervalSinceNow: time)
            let path = decoded(key(directory))
            stall.lock()
            defer { stall.unlock() }
            if stalling { waitingListings[path, default: 0] += 1 }
            while !cancellation.isCancelled, stalling ? !stallsReleased : end.timeIntervalSinceNow > 0 {
                if stalling { stall.wait() } else { stall.wait(until: end) }
            }
            if stalling { waitingListings[path, default: 1] -= 1 }
            return !cancellation.isCancelled
        }
        let stalls = stallsListings && (stalledPaths?.contains(decoded(key(directory))) ?? true)
        guard pause(listStartDelay), pause(0, stalling: stalls) else { return }
        let items = try list(directory, showHidden: showHidden)
        guard let size = listBatchSize, size > 0 else {
            _ = receive(items)
            return
        }
        for start in stride(from: 0, to: items.count, by: size) {
            guard pause(listBatchDelay) else { return }
            if !receive(Array(items[start..<min(start + size, items.count)])) { return }
        }
    }

    /// The whole directory at once, as sizes are added up; it stalls like the other, and is
    /// not counted among the `listRequests`, like `list(_:showHidden:)`.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        let waiting = cancellation.onCancel { [stall] in
            stall.lock()
            stall.broadcast()
            stall.unlock()
        }
        defer { _ = waiting }
        let path = decoded(key(directory))
        let stalls = stallsListings && (stalledPaths?.contains(path) ?? true)
        stall.lock()
        if stalls { waitingListings[path, default: 0] += 1 }
        while stalls, !stallsReleased, !cancellation.isCancelled { stall.wait() }
        if stalls { waitingListings[path, default: 1] -= 1 }
        stall.unlock()
        return cancellation.isCancelled ? [] : try list(directory, showHidden: showHidden)
    }

    public func capabilities(for url: URL) -> FileSystemCapabilities {
        capabilitiesAt?(url) ?? capabilities
    }

    public func item(at url: URL) -> FileItem? {
        synchronized { nodes[key(url)].map { makeItem(key(url), $0) } }
    }

    public func parent(of directory: URL) -> URL? {
        let own = key(directory)
        return own == "/" ? nil : url(decoded(parentKey(own)))
    }

    private final class Reader: FileReader {
        private let data: Data
        private var position = 0
        private let stall: Stall
        private let stalls: Bool

        init(_ data: Data, stall: Stall, stalls: Bool) {
            self.data = data
            self.stall = stall
            self.stalls = stalls
        }

        func interrupt() { stall.interrupt() }

        func read(upToCount count: Int) throws -> Data? {
            try stall.wait(stalling: stalls)
            guard position < data.count else { return nil }
            let block = data.subdata(in: position..<min(position + count, data.count))
            position += block.count
            return block
        }

        func seek(to offset: UInt64) { position = min(Int(offset), data.count) }
        func close() {}
    }

    public func read(_ url: URL) throws -> any FileReader {
        try synchronized {
            guard case .file(let data, _, _)? = nodes[key(url)] else { throw NotFound(path: decoded(key(url))) }
            return Reader(data, stall: makeStall(), stalls: stallsReads)
        }
    }

    public func createDirectory(at url: URL) {
        synchronized {
            var path = key(url)
            while path != "/" {
                if nodes[path] == nil { nodes[path] = .directory }
                path = parentKey(path)
            }
        }
    }

    private final class Writer: FileWriter {
        private var data: Data
        private let store: (Data, FileAttributes) -> Void
        private let stall: Stall
        private let stalls: Bool

        init(_ data: Data = Data(), stall: Stall, stalls: Bool, store: @escaping (Data, FileAttributes) -> Void) {
            self.data = data
            self.stall = stall
            self.stalls = stalls
            self.store = store
        }

        func interrupt() { stall.interrupt() }

        func write(_ data: Data) throws {
            try stall.wait(stalling: stalls)
            self.data.append(data)
        }

        func close(attributes: FileAttributes) { store(data, attributes) }
    }

    public func write(_ url: URL) throws -> any FileWriter {
        let path = key(url)
        try synchronized {
            guard case .directory? = nodes[parentKey(path)] else { throw NotFound(path: decoded(parentKey(path))) }
            guard nodes[path] == nil else { throw FileSystemError.alreadyExists(decoded(path)) }
            nodes[path] = .file(Data(), Date(), 0o644)
        }
        return Writer(stall: makeStall(), stalls: stallsWrites) { [weak self] data, attributes in
            self?.synchronized {
                self?.nodes[path] = .file(data, attributes.modified ?? Date(), attributes.permissions ?? 0o644)
            }
        }
    }

    /// Offered when `capabilities` holds `.append`; what has been written shows when the
    /// writer is closed, with the date and permissions the file had unless others are given.
    public func append(to url: URL, at offset: Int64?, cancellation _: CancellationFlag) throws -> any FileWriter {
        guard capabilities(for: url).contains(.append) else { throw FileSystemError.notSupported("Continuing a file") }
        let path = key(url)
        let (head, modified, permissions): (Data, Date, UInt16) = try synchronized {
            guard case .file(let data, let modified, let permissions)? = nodes[path] else {
                throw NotFound(path: decoded(path))
            }
            guard let offset else { return (data, modified, permissions) }
            guard offset >= 0, offset <= Int64(data.count) else {
                throw FileSystemError.notSupported("Continuing \(decoded(path)) at \(offset)")
            }
            nodes[path] = .file(data.prefix(Int(offset)), modified, permissions)
            return (data.prefix(Int(offset)), modified, permissions)
        }
        return Writer(head, stall: makeStall(), stalls: stallsWrites) { [weak self] data, attributes in
            self?.synchronized {
                self?.nodes[path] = .file(data, attributes.modified ?? modified, attributes.permissions ?? permissions)
            }
        }
    }

    public func copyMetadata(from source: URL, to destination: URL) throws {
        guard keepsMetadata else { throw FileSystemError.notSupported("Copying metadata") }
        try synchronized {
            guard nodes[key(destination)] != nil else { throw NotFound(path: decoded(key(destination))) }
            metadataCopied.append((source, decoded(key(destination))))
        }
    }

    public func commit(_ url: URL, cancellation _: CancellationFlag) throws {
        synchronized { committed.append(decoded(key(url))) }
        if let commitFailure { throw commitFailure }
    }

    /// How often a commit asks `progress` before it commits: a commit that takes long, in
    /// that many steps. 0 asks once, as the protocol's default does.
    public var commitSteps: Int {
        get { settings.withLock { _commitSteps } }
        set { settings.withLock { _commitSteps = newValue } }
    }
    private var _commitSteps: Int = 0

    public func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        for step in 0..<max(commitSteps, 1)
        where cancellation.isCancelled || !progress(Int64(step), Int64(commitSteps)) {
            throw CocoaError(.userCancelled)
        }
        try commit(url, cancellation: cancellation)
    }

    public func quarantine(of _: URL) -> Data? { quarantineValue }

    public func setQuarantine(_ value: Data, of url: URL) throws {
        try synchronized {
            guard nodes[key(url)] != nil else { throw NotFound(path: decoded(key(url))) }
            quarantined[decoded(key(url))] = value
        }
    }

    public func remove(_ url: URL) throws {
        let path = key(url)
        try synchronized {
            guard nodes[path] != nil else { throw NotFound(path: decoded(path)) }
            guard !nodes.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
                throw FileSystemError.notSupported("Removing the non-empty \(decoded(path))")
            }
            nodes[path] = nil
        }
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        let (from, to) = (key(source), key(destination))
        try synchronized {
            guard nodes[from] != nil else { throw NotFound(path: decoded(from)) }
            if nodes[to] != nil, !replacing { throw FileSystemError.alreadyExists(decoded(to)) }
            for candidate in nodes.keys.sorted() where candidate == from || candidate.hasPrefix(from + "/") {
                nodes[to + candidate.dropFirst(from.count)] = nodes[candidate]
                nodes[candidate] = nil
            }
        }
    }

    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        if refusesInternalCopy { throw FileSystemError.crossesVolumes }
        let (data, modified, permissions): (Data, Date, UInt16) = try synchronized {
            guard case .file(let data, let modified, let permissions)? = nodes[key(source)] else {
                throw NotFound(path: decoded(key(source)))
            }
            guard nodes[key(destination)] == nil else { throw FileSystemError.alreadyExists(decoded(key(destination))) }
            return (data, modified, permissions)
        }
        var copied = 0
        while copied < data.count {
            copied = min(data.count, copied + copyBlockSize)
            if !progress(Int64(copied)) { throw CocoaError(.userCancelled) }
        }
        synchronized { nodes[key(destination)] = .file(data, modified, permissions) }
    }

    // MARK: Changes with a flag

    /// Notes a changing call that came with a flag, and holds it while `stallsChanges`.
    private func flaggedChange(_ what: String, _ url: URL, _ cancellation: CancellationFlag) throws {
        synchronized { flagged.append(what + " " + decoded(key(url))) }
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        guard stallsChanges else { return }
        let waiting = cancellation.onCancel { [stall] in
            stall.lock()
            stall.broadcast()
            stall.unlock()
        }
        defer { _ = waiting }
        stall.lock()
        waitingChanges += 1
        while !cancellation.isCancelled, !stallsReleased { stall.wait() }
        waitingChanges -= 1
        stall.unlock()
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
    }

    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("createDirectory", url, cancellation)
        try createDirectory(at: url)
    }

    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("remove", url, cancellation)
        try remove(url)
    }

    public func remove(_ url: URL, below root: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("remove below " + decoded(key(root)), url, cancellation)
        try remove(url)
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try flaggedChange("move", source, cancellation)
        try move(source, to: destination, replacing: replacing)
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("setAttributes", url, cancellation)
        try setAttributes(attributes, of: url)
    }

    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("copyMetadata", destination, cancellation)
        try copyMetadata(from: source, to: destination)
    }

    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try flaggedChange("setQuarantine", url, cancellation)
        try setQuarantine(value, of: url)
    }

    public func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        try flaggedChange("copy", destination, cancellation)
        try copy(source, to: destination) { progress($0) && !cancellation.isCancelled }
    }

    public func displayPath(_ url: URL) -> String {
        "\(scheme):\(decoded(key(url)))"
    }

    /// Reads both its own short notation (`mem:/work`) and the full URL (`mem:///work`).
    public func location(from text: String) -> URL? {
        guard text.hasPrefix(scheme + ":") else { return nil }
        let path = String(text.dropFirst(scheme.count + 1))
        return url(path.hasPrefix("//") ? String(path.drop(while: { $0 == "/" })) : path)
    }

    public func places() -> [Place] {
        [Place(name: "Memory", url: url("/"), kind: .externalDisk)]
    }

    public func volume(of _: URL) -> VolumeInfo? {
        VolumeInfo(name: "Memory", isLocal: isLocal)
    }
}
