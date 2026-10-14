import AFMKernel
import Foundation

/// The servers the program is connected to, and how to reach the ones it is not connected to
/// yet (spec 11 › A connection is a panel location). The file-system providers find their
/// sessions here by the server part of a URL; a URL of a server without a session connects on
/// first use, with a saved connection's settings when one fits and as an anonymous guest
/// otherwise.
///
/// **Threading.** Safe from any thread; the state is guarded by a lock. `onChange` is called on
/// the thread that connected or disconnected.
public final class ConnectionCenter {
    public let environment: SessionEnvironment
    private let lock = NSLock()
    private var sessions: [ServerKey: RemoteSession] = [:]
    private var announced: [ServerKey: ConnectionProfile] = [:]
    private var saved: [ConnectionProfile] = []
    private var lastPaths: [ServerKey: String] = [:]
    /// Builds the session for a profile; the plugin sets it for the protocols it speaks.
    var makeSession: (ConnectionProfile, SessionEnvironment) -> RemoteSession? = { _, _ in nil }
    /// The stored password of a saved connection: of this very server and login, not of
    /// whatever connection carries the same identifier. Called on the thread that connects.
    public var storedPassword: (ConnectionProfile) -> String? = { _ in nil }
    /// The servers the user chose to connect to (a saved connection, the connection dialogs, an
    /// earlier yes). A server that is none of these is asked about before the first login.
    private var chosen: Set<ServerKey> = []

    /// The name of this program, for the mark on what it downloads (`RemoteFileSystem.quarantine`).
    public var agentName = "A File Manager"

    public init(environment: SessionEnvironment = SessionEnvironment()) {
        self.environment = environment
    }

    /// Makes a profile known before its server is first used: a quick connection, or the user
    /// name and password that were part of a typed URL.
    ///
    /// `chosen` says that the user asked for this connection (a dialog of this program). An
    /// address that merely stood somewhere (a typed location, a tab file, a list) is announced
    /// without it, and the user is asked before the first login to its server.
    public func announce(_ profile: ConnectionProfile, chosen isChosen: Bool = false) {
        lock.lock()
        let isNewlyChosen = isChosen && chosen.insert(profile.key).inserted
        // Announced again as it is known already (a location that is read once more): nothing changes.
        if !isNewlyChosen, let known = announced[profile.key],
            (known.user, known.password, known.tls, known.anonymous, known.savedID)
                == (profile.user, profile.password, profile.tls, profile.anonymous, profile.savedID)
        {
            lock.unlock()
            return
        }
        announced[profile.key] = profile
        let stale = dropUnconnected([profile.key])
        lock.unlock()
        stale.forEach { $0.disconnect() }
    }

    /// The user named this server in person just now (an address typed into the command line or
    /// the path field): it is not asked about before the first login. Nothing else changes; how
    /// to log in is what `announce` or a saved connection said.
    public func noteChosen(_ key: ServerKey) {
        lock.lock()
        // A session made before this was known would still ask; one that is logging in is left alone.
        let stale = chosen.insert(key).inserted ? dropUnconnected([key]) : []
        lock.unlock()
        stale.forEach { $0.disconnect() }
    }

    /// Takes out the sessions of these servers that never got as far as a login, so the next
    /// attempt starts with what is known now. A session that is in the middle of its login is
    /// left alone: the user may be answering its question. Called with the lock held.
    private func dropUnconnected(_ keys: [ServerKey]) -> [RemoteSession] {
        keys.compactMap { key in
            guard let session = sessions[key], !session.isConnected, !session.isConnecting else { return nil }
            sessions[key] = nil
            return session
        }
    }

    /// The saved connections, for URLs that name one of their servers.
    public func setSaved(_ profiles: [ConnectionProfile]) {
        lock.lock()
        saved = profiles
        let stale = dropUnconnected(profiles.map(\.key))
        lock.unlock()
        stale.forEach { $0.disconnect() }
    }

    private func profile(for key: ServerKey) -> ConnectionProfile {
        lock.lock()
        let fromSaved = saved.first { $0.key == key }
        let known = announced[key] ?? fromSaved
        let isChosen = chosen.contains(key) || fromSaved != nil
        lock.unlock()
        guard var profile = known else {
            // Nothing is known: a guest on an FTP server, the Mac's user on a secure shell
            // (with the keys and the configuration that user has). Not without asking.
            var guest = ConnectionProfile(
                key: key, user: key.scheme == "sftp" ? NSUserName() : nil, anonymous: key.scheme != "sftp")
            guest.asksBeforeConnecting = !isChosen
            return guest
        }
        profile.asksBeforeConnecting = !isChosen
        if profile.password == nil, profile.savedID != nil { profile.password = storedPassword(profile) }
        return profile
    }

    func session(for key: ServerKey) throws -> RemoteSession {
        lock.lock()
        if let session = sessions[key] {
            lock.unlock()
            return session
        }
        lock.unlock()
        // The password comes from the Keychain, which may take a moment; not under the lock.
        let profile = self.profile(for: key)
        guard let created = makeSession(profile, environment) else {
            throw FileSystemError.notSupported("Connections of the type \(key.scheme)")
        }
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] { return session }
        sessions[key] = created
        return created
    }

    /// The session of a server when there is one.
    func existingSession(for key: ServerKey) -> RemoteSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[key]
    }

    /// The servers with a login that succeeded, in the order of their names.
    public var connected: [ConnectionProfile] {
        lock.lock()
        let all = Array(sessions.values)
        lock.unlock()
        return all.filter(\.isConnected).map(\.profile).sorted { $0.key.description < $1.key.description }
    }

    public func isConnected(_ key: ServerKey) -> Bool {
        existingSession(for: key)?.isConnected ?? false
    }

    /// The profile a live session was opened with.
    public func profile(of key: ServerKey) -> ConnectionProfile? {
        existingSession(for: key)?.profile
    }

    /// Connects if necessary; returns the folder the login leads to.
    public func connect(_ key: ServerKey, cancellation: CancellationFlag? = nil) throws -> String {
        try session(for: key).connect(cancellation: cancellation)
    }

    public func disconnect(_ key: ServerKey) {
        detach(key)()
    }

    /// Forgets the connection at once and returns the work that closes it, which waits for
    /// the server and is therefore run off the main thread.
    public func detach(_ key: ServerKey) -> () -> Void {
        lock.lock()
        let session = sessions.removeValue(forKey: key)
        announced[key] = nil
        lastPaths[key] = nil
        chosen.remove(key)
        lock.unlock()
        return { session?.disconnect() }
    }

    public func disconnectAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions = [:]
        announced = [:]
        lock.unlock()
        all.forEach { $0.disconnect() }
    }

    func noteVisited(_ path: String, on key: ServerKey) {
        lock.lock()
        lastPaths[key] = path
        lock.unlock()
    }

    /// The folder last listed on a server.
    public func lastPath(on key: ServerKey) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lastPaths[key]
    }
}

/// What is known about single entries from the listings read a moment ago, so that the many
/// questions a copy job asks about its targets do not each travel to the server. A listing is
/// forgotten after a few seconds. What this program itself changes in a directory (a file
/// written, a folder made or removed, a rename) is entered into the listing at once, so the
/// next question about the directory is still answered from it; a change that cannot be
/// entered exactly makes the directory forgotten. Safe from any thread.
///
/// A listing that was under way while the directory changed would bring the old state back
/// when it is stored. Changes are therefore also noted for a while in a journal, and a
/// listing that finishes is brought up to date with the changes made since it started.
private final class EntryCache {
    private struct Directory {
        let read: Date
        let includesHidden: Bool
        var entries: [String: RemoteEntry]
    }

    /// One change of a directory. No name: everything about the directory is unknown.
    private struct Change {
        let at: Date
        let name: String?
        /// Nil: the name is gone.
        let entry: RemoteEntry?
    }

    private let lock = NSLock()
    private var directories: [String: Directory] = [:]
    private var journal: [String: [Change]] = [:]
    private static let lifetime: TimeInterval = 10
    private static let capacity = 64
    private static let journalLifetime: TimeInterval = 300
    private static let journalLimit = 1024

    /// Stores a complete listing that was started at `startedAt`.
    func store(_ entries: [RemoteEntry], for directory: URL, includesHidden: Bool, startedAt: Date) {
        var byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        for change in journal[key] ?? [] where change.at >= startedAt {
            // Something about the directory is not known: this listing may be out of date.
            guard let name = change.name else { return }
            byName[name] = change.entry
        }
        if directories.count >= EntryCache.capacity { directories.removeAll() }
        directories[key] = Directory(read: Date(), includesHidden: includesHidden, entries: byName)
    }

    enum Answer {
        case entry(RemoteEntry)
        case absent, unknown
    }

    func lookUp(_ name: String, in directory: URL) -> Answer {
        lock.lock()
        defer { lock.unlock() }
        guard let known = fresh(directory.locationKey) else { return .unknown }
        if let entry = known.entries[name] { return .entry(entry) }
        return known.includesHidden || !name.hasPrefix(".") ? .absent : .unknown
    }

    /// Whether the listing of the directory holds a name that a server may take for `name`
    /// although it is spelled differently: in another case, or composed differently.
    func hasNameAlike(_ name: String, in directory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let known = fresh(directory.locationKey) else { return false }
        return known.entries.keys.contains {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
    }

    /// Changes what is known of an entry, when it is known; nothing else happens. For news that
    /// arrive on their own (a link resolved in the background): they must not make a listing
    /// be forgotten that they do not concern.
    func updateIfKnown(_ name: String, in directory: URL, _ change: (inout RemoteEntry) -> Void) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        guard fresh(key) != nil, var entry = directories[key]?.entries[name] else { return }
        change(&entry)
        note(key, name: name, entry: entry)
        directories[key]?.entries[name] = entry
    }

    /// The listing of a directory unless it is too old. Called with the lock held.
    private func fresh(_ key: String) -> Directory? {
        guard let known = directories[key] else { return nil }
        if Date().timeIntervalSince(known.read) < EntryCache.lifetime { return known }
        directories[key] = nil
        return nil
    }

    private func note(_ key: String, name: String?, entry: RemoteEntry?) {
        let now = Date()
        var changes = journal[key] ?? []
        let cutoff = now.addingTimeInterval(-EntryCache.journalLifetime)
        if let first = changes.firstIndex(where: { $0.at >= cutoff }), first > 0 { changes.removeFirst(first) }
        if changes.count >= EntryCache.journalLimit { changes = [Change(at: now, name: nil, entry: nil)] }
        changes.append(Change(at: now, name: name, entry: entry))
        journal[key] = changes
        if journal.count > 256 { journal = journal.filter { $0.value.last.map { $0.at >= cutoff } ?? false } }
    }

    /// A name that now exists in the directory (a file just created, a folder just made).
    func insert(_ entry: RemoteEntry, in directory: URL) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        note(key, name: entry.name, entry: entry)
        if fresh(key) != nil { directories[key]?.entries[entry.name] = entry }
    }

    /// A name that is gone from the directory.
    func remove(_ name: String, from directory: URL) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        note(key, name: name, entry: nil)
        if fresh(key) != nil { directories[key]?.entries[name] = nil }
    }

    /// Changes what is known of an entry; the directory is forgotten when the entry is not known.
    func update(_ name: String, in directory: URL, _ change: (inout RemoteEntry) -> Void) {
        let key = directory.locationKey
        lock.lock()
        defer { lock.unlock() }
        if fresh(key) != nil, var entry = directories[key]?.entries[name] {
            change(&entry)
            note(key, name: name, entry: entry)
            directories[key]?.entries[name] = entry
        } else {
            note(key, name: nil, entry: nil)
            directories[key] = nil
        }
    }

    /// An entry that went from one directory to another, or to another name.
    func move(_ name: String, from source: URL, to destination: URL, as newName: String) {
        let (from, to) = (source.locationKey, destination.locationKey)
        lock.lock()
        defer { lock.unlock() }
        guard fresh(from) != nil, var entry = directories[from]?.entries[name] else {
            // Nothing is known of what moved, so nothing of where it arrived.
            note(from, name: nil, entry: nil)
            note(to, name: nil, entry: nil)
            directories[from] = nil
            directories[to] = nil
            return
        }
        note(from, name: name, entry: nil)
        directories[from]?.entries[name] = nil
        entry.name = newName
        note(to, name: newName, entry: entry)
        if fresh(to) != nil { directories[to]?.entries[newName] = entry }
    }

    func forget(_ directories: URL...) {
        lock.lock()
        defer { lock.unlock() }
        for directory in directories {
            let key = directory.locationKey
            note(key, name: nil, entry: nil)
            self.directories[key] = nil
        }
    }

    /// Forgets a directory and everything below it, after it was removed or moved.
    func forgetTree(_ root: URL) {
        let key = root.locationKey
        lock.lock()
        defer { lock.unlock() }
        for known in directories.keys where known == key || known.hasPrefix(key + "/") {
            note(known, name: nil, entry: nil)
            directories[known] = nil
        }
    }
}

/// Servers as a file system (spec 11 › The connected panel): `ftp:`, `ftps:` and `sftp:` URLs
/// of the form `scheme://host[:port]/path`. A URL never carries a user name or password; those
/// belong to the connection (`ConnectionCenter`). One instance serves one scheme.
///
/// **Threading.** Every method is safe to call from several threads at once: the sessions take
/// care of their connections, and the little state kept here is guarded by locks. The calls
/// that must answer at once (`parent(of:)`, `displayPath(_:)`, `places()`) work on text and
/// on what the center already knows.
public final class RemoteFileSystem: FileSystemProvider {
    public let scheme: String
    public let capabilities: FileSystemCapabilities = [.write, .append]
    /// Showing a location of this file system may log in to a server.
    public var connectsToServer: Bool { true }
    private let center: ConnectionCenter
    private let cache = EntryCache()

    public init(scheme: String, center: ConnectionCenter) {
        self.scheme = scheme
        self.center = center
    }

    private func resolve(_ url: URL, cancellation: CancellationFlag? = nil) throws -> (
        session: RemoteSession, key: ServerKey, path: String
    ) {
        if cancellation?.isCancelled == true { throw NetworkError.cancelled }
        guard let key = ServerKey(url), key.scheme == scheme else { throw FileSystemError.noProvider(url) }
        // Every name of the path must read as a name of its own (see `RemotePath.normalized`).
        guard RemotePath.hasSeparableNames(url.path) else {
            throw FileSystemError.notSupported("A name that begins or ends with a combining character")
        }
        return (try center.session(for: key), key, RemotePath.of(url))
    }

    private func parentURL(_ url: URL) -> URL {
        parent(of: url) ?? url
    }

    // MARK: Reading

    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden) { batch in
            items += batch
            return true
        }
        return items
    }

    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try read(directory, showHidden: showHidden, isVisit: true, cancellation: nil, receive: receive)
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        try read(directory, showHidden: showHidden, isVisit: true, cancellation: cancellation, receive: receive)
    }

    /// Reads a directory and remembers the listing. A visit is what the panels do; reading
    /// the directory to answer a question about one entry is not. A cancelled listing is not remembered.
    private func read(
        _ directory: URL, showHidden: Bool, isVisit: Bool, cancellation: CancellationFlag?,
        receive: ([FileItem]) -> Bool
    ) throws {
        let (session, key, path) = try resolve(directory)
        let base = key.url(path: path)
        var all: [RemoteEntry] = []
        var complete = true
        let started = Date()
        // A link the session resolves after the listing was delivered is a folder in what is remembered, too.
        session.onLinkResolved { [weak self] link, isDirectory in
            guard let self, let parent = RemotePath.parent(of: link) else { return }
            self.cache.updateIfKnown(RemotePath.name(of: link), in: key.url(path: parent)) {
                $0.isDirectory = isDirectory
            }
        }
        try session.list(path, showHidden: showHidden, cancellation: cancellation) { entries in
            all += entries
            let visible = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
            if !visible.isEmpty, !receive(visible.map { $0.item(in: base) }) { complete = false }
            if cancellation?.isCancelled == true { complete = false }
            return complete
        }
        guard complete, cancellation?.isCancelled != true else { return }
        cache.store(all, for: base, includesHidden: showHidden, startedAt: started)
        if isVisit { center.noteVisited(path, on: key) }
    }

    /// The entry at a location; nil when nothing is there.
    ///
    /// `beforeOverwriting` is for the question "is this name free?" asked before a step that
    /// would silently replace what is there (an upload, a rename). A listing that is a few
    /// seconds old is then not believed when it says "nothing there": the server is asked,
    /// where one question is cheap, and in any case when the listing holds a name that differs
    /// only in case or composition, which a server that does not tell those apart takes for the same file.
    private func entry(at url: URL, cancellation: CancellationFlag? = nil, beforeOverwriting: Bool = false) throws
        -> RemoteEntry?
    {
        let (session, key, path) = try resolve(url)
        guard let parent = RemotePath.parent(of: path) else { return RemoteEntry(name: key.host, isDirectory: true) }
        let (parentURL, name) = (key.url(path: parent), RemotePath.name(of: path))
        switch cache.lookUp(name, in: parentURL) {
        case .entry(let entry): return entry
        case .absent:
            guard beforeOverwriting, session.singleLookupsAreCheap || cache.hasNameAlike(name, in: parentURL) else {
                return nil
            }
            return try session.entry(at: path, cancellation: cancellation)
        case .unknown: break
        }
        // Where one question costs several commands and a listing, the listing is read once
        // and answers the questions that follow, about the entries that are not there as well.
        if !session.singleLookupsAreCheap,
            (try? read(parentURL, showHidden: true, isVisit: false, cancellation: cancellation) { _ in true }) != nil
        {
            switch cache.lookUp(name, in: parentURL) {
            case .entry(let entry): return entry
            case .absent: return nil
            case .unknown: break
            }
        }
        return try session.entry(at: path, cancellation: cancellation)
    }

    public func item(at url: URL) -> FileItem? {
        item(at: url, cancellation: nil)
    }

    public func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        item(at: url, cancellation: Optional(cancellation))
    }

    private func item(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard cancellation?.isCancelled != true, let entry = try? entry(at: url, cancellation: cancellation),
            let key = ServerKey(url),
            cancellation?.isCancelled != true
        else { return nil }
        let path = RemotePath.of(url)
        guard let parent = RemotePath.parent(of: path) else {
            return FileItem(url: key.url(), name: key.host, isDirectory: true, permissions: 0o755)
        }
        var named = entry
        named.name = RemotePath.name(of: path)
        return named.item(in: key.url(path: parent))
    }

    public func parent(of directory: URL) -> URL? {
        guard let key = ServerKey(directory), let parent = RemotePath.parent(of: RemotePath.of(directory)) else {
            return nil
        }
        return key.url(path: parent)
    }

    /// The top of a server, known from the address alone: no climbing through the path.
    public func root(of url: URL) -> URL {
        guard let key = ServerKey(url) else { return url }
        return key.url()
    }

    public func read(_ url: URL) throws -> FileReader {
        let (session, _, path) = try resolve(url)
        return try session.openRead(path, cancellation: nil)
    }

    public func read(_ url: URL, cancellation: CancellationFlag) throws -> FileReader {
        let (session, _, path) = try resolve(url, cancellation: cancellation)
        return try session.openRead(path, cancellation: cancellation)
    }

    // MARK: Changing

    // The calls that change something come in two forms: without a flag, and with the flag of
    // the job that asks, which ends every wait they make for the server (N010, N026).

    public func createDirectory(at url: URL) throws {
        try createDirectory(at: url, cancellation: Optional<CancellationFlag>.none)
    }

    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try createDirectory(at: url, cancellation: Optional(cancellation))
    }

    private func createDirectory(at url: URL, cancellation: CancellationFlag?) throws {
        let (session, key, path) = try resolve(url, cancellation: cancellation)
        guard let parent = RemotePath.parent(of: path) else { return }
        if let existing = try entry(at: url, cancellation: cancellation) {
            if existing.isDirectory { return }
            throw FileSystemError.alreadyExists(displayPath(url))
        }
        let parentURL = key.url(path: parent)
        if parent != "/", try entry(at: parentURL, cancellation: cancellation) == nil {
            try createDirectory(at: parentURL, cancellation: cancellation)
        }
        do {
            try session.makeDirectory(path, cancellation: cancellation)
        } catch {
            cache.forget(parentURL)
            throw error
        }
        cache.insert(RemoteEntry(name: RemotePath.name(of: path), isDirectory: true, modified: Date()), in: parentURL)
    }

    public func write(_ url: URL) throws -> FileWriter {
        try write(url, cancellation: Optional<CancellationFlag>.none)
    }

    public func write(_ url: URL, cancellation: CancellationFlag) throws -> FileWriter {
        try write(url, cancellation: Optional(cancellation))
    }

    private func write(_ url: URL, cancellation: CancellationFlag?) throws -> FileWriter {
        let (session, _, path) = try resolve(url, cancellation: cancellation)
        if try entry(at: url, cancellation: cancellation, beforeOverwriting: true) != nil {
            throw FileSystemError.alreadyExists(displayPath(url))
        }
        let directory = parentURL(url)
        let name = RemotePath.name(of: path)
        let writer: FileWriter
        do {
            writer = try session.openWrite(path, cancellation: cancellation)
        } catch {
            cache.forget(directory)
            throw error
        }
        // The file exists on the server from now on; its size and date follow when it is closed.
        cache.insert(RemoteEntry(name: name, isDirectory: false, modified: Date()), in: directory)
        return CachingWriter(writer, cache: cache, directory: directory, name: name)
    }

    /// Continues an existing file (Resume, Append). The server has it at the new length at once,
    /// so the cached listing follows; what is written later is entered when the file is closed.
    public func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> FileWriter {
        let (session, _, path) = try resolve(url, cancellation: cancellation)
        guard session.canAppend(path) else { throw FileSystemError.notSupported("Continuing a file on this server") }
        let (directory, name) = (parentURL(url), RemotePath.name(of: path))
        let opened: (writer: FileWriter, size: Int64)
        do {
            opened = try session.openAppend(path, at: offset, cancellation: cancellation)
        } catch {
            cache.forget(directory)
            throw error
        }
        cache.update(name, in: directory) { $0.size = opened.size }
        return CachingWriter(opened.writer, cache: cache, directory: directory, name: name, written: opened.size)
    }

    /// Where a server cannot continue a file (an FTP server without `REST`, a transfer in text
    /// mode) the capability is missing, and the caller writes the file again.
    public func capabilities(for url: URL) -> FileSystemCapabilities {
        guard let key = ServerKey(url), key.scheme == scheme, let session = center.existingSession(for: key) else {
            return capabilities
        }
        return session.canAppend(RemotePath.of(url)) ? capabilities : capabilities.subtracting(.append)
    }

    public func remove(_ url: URL) throws {
        try remove(url, cancellation: Optional<CancellationFlag>.none)
    }

    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try remove(url, cancellation: Optional(cancellation))
    }

    private func remove(_ url: URL, cancellation: CancellationFlag?) throws {
        let (session, key, path) = try resolve(url, cancellation: cancellation)
        guard let parent = RemotePath.parent(of: path) else {
            throw FileSystemError.notSupported("Deleting the root of a server")
        }
        let (parentURL, name) = (key.url(path: parent), RemotePath.name(of: path))
        var isDirectory: Bool?
        if case .entry(let known) = cache.lookUp(name, in: parentURL) {
            // A link is removed like a file, whatever it points to.
            isDirectory = known.isDirectory && !known.isSymlink
        }
        do {
            try session.remove(path, isDirectory: isDirectory, cancellation: cancellation)
        } catch {
            cache.forget(parentURL)
            cache.forgetTree(key.url(path: path))
            throw error
        }
        cache.remove(name, from: parentURL)
        cache.forgetTree(key.url(path: path))
    }

    /// Renames. With `replacing` an existing file at the destination is replaced, and at no
    /// moment is it gone without the new file being in its place or the old one being kept
    /// under another name.
    ///
    /// First the plain rename is tried, which replaces in one step on a secure shell server
    /// (`posix-rename`) and on most FTP servers. When the server refuses, nothing is removed
    /// to make room: a refusal has many reasons (no permission, no such source), and removing
    /// the destination for any of them would lose it. Only when the server confirms that the
    /// source exists and that a file is in the way, that file is renamed aside, the source
    /// is renamed into its place, and the one set aside is removed last. If the second
    /// rename fails, the file set aside is renamed back; if even that fails, the error names
    /// where it was kept.
    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try move(source, to: destination, replacing: replacing, cancellation: Optional<CancellationFlag>.none)
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try move(source, to: destination, replacing: replacing, cancellation: Optional(cancellation))
    }

    private func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag?) throws {
        let (session, key, from) = try resolve(source, cancellation: cancellation)
        guard let targetKey = ServerKey(destination), targetKey == key else { throw FileSystemError.crossesVolumes }
        let to = RemotePath.of(destination)
        if from == to { return }
        if !replacing, try entry(at: destination, cancellation: cancellation, beforeOverwriting: true) != nil {
            throw FileSystemError.alreadyExists(displayPath(destination))
        }
        // Whether the rename went through as one step, so the cached listings can follow it.
        var isPlain = true
        do {
            do {
                try session.rename(from, to: to, replacing: replacing, cancellation: cancellation)
            } catch let refusal where replacing && RemoteFileSystem.isRefusal(refusal) {
                isPlain = false
                cache.forget(parentURL(source), parentURL(destination))
                // Asked of the server, not of what is remembered: both answers decide over a file.
                guard try session.entry(at: from, cancellation: cancellation) != nil,
                    let existing = try session.entry(at: to, cancellation: cancellation), !existing.isDirectory
                else { throw refusal }
                try replace(to, with: from, on: session, refusal: refusal, cancellation: cancellation)
            }
        } catch {
            cache.forget(parentURL(source), parentURL(destination))
            cache.forgetTree(source)
            cache.forgetTree(destination)
            throw error
        }
        if isPlain {
            cache.move(
                RemotePath.name(of: from), from: parentURL(source), to: parentURL(destination),
                as: RemotePath.name(of: to))
        } else {
            cache.forget(parentURL(source), parentURL(destination))
        }
        // What lay below a folder that moved, or that was replaced, is somewhere else now.
        cache.forgetTree(source)
        cache.forgetTree(destination)
    }

    /// True for an answer of the server that says no to a request, as opposed to a connection
    /// that broke or a wait that was ended: only the former says anything about the files.
    private static func isRefusal(_ error: Error) -> Bool {
        if error is SFTPError { return true }
        if case NetworkError.refused(let reply) = error { return reply.code != 421 }
        return false
    }

    /// Puts the file at `from` in the place of the file at `to` on a server whose rename does
    /// not replace. The file in the way is never deleted before the new one stands in its place.
    ///
    /// The caller's flag ends only the first step. Once the file in the way stands aside, the
    /// rest is seen through whatever the flag says (it still ends with the session and at the
    /// time limits): a Cancel between the two renames would leave the name without a file.
    private func replace(
        _ to: String, with from: String, on session: RemoteSession, refusal: Error, cancellation: CancellationFlag?
    ) throws {
        let directory = RemotePath.parent(of: to) ?? "/"
        let aside = RemotePath.join(directory, RemoteFileSystem.asideName(for: RemotePath.name(of: to)))
        do {
            try session.rename(to, to: aside, replacing: false, cancellation: cancellation)
        } catch {
            if cancellation?.isCancelled == true { throw NetworkError.cancelled }
            // The file in the way cannot be moved either; everything is as it was.
            throw refusal
        }
        do {
            try session.rename(from, to: to, replacing: false)
        } catch {
            do {
                try session.rename(aside, to: to, replacing: false)
            } catch {
                throw NetworkError.incomplete(
                    "\(RemotePath.name(of: to)) could not be replaced (\(refusal.localizedDescription)), "
                        + "and the file that was there could not be put back: it is kept on the server as \(aside).")
            }
            throw error
        }
        do {
            try session.remove(aside, isDirectory: false)
        } catch {
            // The new file is in place; only the old one is still there under its other name.
            center.environment.log(
                "The replaced file could not be removed and stays on the server as \(aside): \(error.localizedDescription)"
            )
        }
    }

    /// A name next to `name` for the file that is being replaced, one that nothing else has.
    static func asideName(for name: String) -> String {
        let mark = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        // Short enough for servers with a limit of 255 bytes for a name.
        let kept = String(decoding: name.utf8.prefix(180), as: UTF8.self).replacingOccurrences(
            of: "\u{FFFD}", with: "")
        return ".\(kept).replaced-\(mark)"
    }

    /// A server does not copy; the caller reads the file and writes it again.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        throw FileSystemError.crossesVolumes
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try setAttributes(attributes, of: url, cancellation: Optional<CancellationFlag>.none)
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try setAttributes(attributes, of: url, cancellation: Optional(cancellation))
    }

    private func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag?) throws {
        let (session, _, path) = try resolve(url, cancellation: cancellation)
        let directory = parentURL(url)
        do {
            try session.setAttributes(attributes, of: path, cancellation: cancellation)
        } catch {
            cache.forget(directory)
            throw error
        }
        cache.update(RemotePath.name(of: path), in: directory) { entry in
            if let modified = attributes.modified { entry.modified = modified }
            if let permissions = attributes.permissions { entry.permissions = permissions & 0o7777 }
        }
    }

    // MARK: Surroundings

    /// `ftp://host:port/path`, with the names as they are (no percent signs).
    public func displayPath(_ url: URL) -> String {
        guard let key = ServerKey(url) else { return url.absoluteString }
        return key.description + RemotePath.of(url)
    }

    /// Reads what `displayPath` writes, and addresses as the user types them (spec 11 › Address
    /// and URL syntax). A user name and password in the text go to the connection; the
    /// returned URL is without them.
    public func location(from text: String) -> URL? {
        let lowered = text.lowercased()
        let prefixes = scheme == "ftps" ? ["ftps://", "ftpes://", "ftpis://"] : [scheme + "://"]
        guard let prefix = prefixes.first(where: lowered.hasPrefix), let address = ServerAddress(text),
            address.scheme == scheme
        else { return nil }
        // Reading a location only says how to log in, should the server be used. It is not the
        // user's wish to connect (the text may come from a file), so `announce` is told nothing
        // of the kind, and it leaves a session alone that is in the middle of its login.
        if address.user != nil || prefix != scheme + "://", !center.isConnected(address.key) {
            center.announce(
                ConnectionProfile(key: address.key, tls: address.tls, user: address.user, password: address.password))
        }
        return address.url
    }

    /// Everything that comes from a server came from elsewhere: the mark a browser puts on
    /// its downloads (`com.apple.quarantine`), so that the system checks a program, an
    /// installer or a script fetched from a server before it first runs. Whoever copies a file
    /// from here to a disk asks for it and puts it on the copy.
    public func quarantine(of url: URL) -> Data? {
        guard let key = ServerKey(url), key.scheme == scheme else { return nil }
        return RemoteFileSystem.quarantineMark(agent: center.agentName)
    }

    /// `flags;time;agent;event`: downloaded (`0083`, what browsers write), the time in
    /// hexadecimal seconds, the program that fetched it, and no event of the download database.
    static func quarantineMark(agent: String, at date: Date = Date()) -> Data {
        let name = agent.replacingOccurrences(of: ";", with: " ")
        return Data("0083;\(String(Int(max(0, date.timeIntervalSince1970)), radix: 16));\(name);".utf8)
    }

    /// The connected servers, for the volume list.
    public func places() -> [Place] {
        center.connected.filter { $0.key.scheme == scheme }.map { profile in
            Place(
                name: profile.title, url: profile.key.url(path: center.lastPath(on: profile.key) ?? "/"),
                kind: .externalDisk)
        }
    }

    public func volume(of url: URL) -> VolumeInfo? {
        guard let key = ServerKey(url) else { return nil }
        return VolumeInfo(name: center.profile(of: key)?.title ?? key.description, isLocal: false)
    }
}

/// Passes everything on to another writer and keeps the cached listing of its directory
/// right: the entry gets its size and date when the file is finished, and the directory is
/// forgotten when the file is not (a failed or abandoned upload leaves an unknown state).
private final class CachingWriter: FileWriter {
    private let writer: FileWriter
    private let cache: EntryCache
    private let directory: URL
    private let name: String
    private var written: Int64
    private var isDone = false

    init(_ writer: FileWriter, cache: EntryCache, directory: URL, name: String, written: Int64 = 0) {
        self.written = written
        self.writer = writer
        self.cache = cache
        self.directory = directory
        self.name = name
    }

    deinit {
        if !isDone { cache.forget(directory) }
    }

    func write(_ data: Data) throws {
        do {
            try writer.write(data)
            written += Int64(data.count)
        } catch {
            cache.forget(directory)
            throw error
        }
    }

    func interrupt() { writer.interrupt() }

    func close(attributes: FileAttributes) throws {
        isDone = true
        do {
            try writer.close(attributes: attributes)
        } catch {
            cache.forget(directory)
            throw error
        }
        let (size, modified, permissions) = (written, attributes.modified, attributes.permissions)
        cache.update(name, in: directory) { entry in
            entry.size = size
            entry.modified = modified ?? Date()
            if let permissions { entry.permissions = permissions & 0o7777 }
        }
    }
}
