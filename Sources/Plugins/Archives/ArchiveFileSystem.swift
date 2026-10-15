import AFMKernel
import Foundation

/// The archives that are open, one `OpenArchive` per archive file, so that the directory of an
/// archive is parsed once however many panels, jobs and searches look into it. An archive is
/// read again when its file changed on disk (size, date or identity).
///
/// **Threading.** Safe from any thread; nothing here is for the main thread except
/// `openArchive(at:)`. A short lock guards the table; each archive has a lock of its own (its
/// slot's) that is held while it is being opened, so two threads asking for the same archive
/// open it once, and opening one archive does not hold up the others. An archive that is
/// open and current is handed out without the slot's lock: a question about it does not wait
/// for somebody else's opening. Whoever wants the open archives (to write their changes)
/// reads them from the table alone and waits for no archive that is being opened.
///
/// **Letting archives go.** An archive leaves the table only after `retireIfIdle()` said
/// yes, which it does under the archive's own lock and never while changes wait or a member
/// is being written; a retired archive refuses every change. So every archive that holds
/// something unwritten is in the table, where `commit`, `flushAll` and the stop find it.
///
/// Unchecked: the table is guarded by `lock`, what a slot holds by the slot's own lock (see
/// Threading above).
final class ArchiveStore: @unchecked Sendable {
    let environment: ArchiveEnvironment
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    /// The archives of the slots, for readers that must not wait on a slot.
    private var opened: [String: OpenArchive] = [:]
    private var clock = 0
    /// Archives without pending changes beyond this number are let go, least recently used first.
    private let capacity = 12

    private final class Slot {
        let lock = NSLock()
        var archive: OpenArchive?
        /// Why the file could not be opened, and the state of the file that goes with it:
        /// a broken archive is not parsed again for every question about it.
        var failure: (error: any Error, signature: FileSignature?, time: Date)?
        var lastUsed = 0
    }

    /// How long the reason a file could not be opened is repeated without looking again.
    static let failureMemory: TimeInterval = 30

    init(environment: ArchiveEnvironment) {
        self.environment = environment
    }

    /// The open archive for the file at `url`, opening or re-reading it when needed. With a
    /// `cancellation`, a thread that waits for another's opening of the same archive, or that
    /// opens it, gives up soon after the flag is set (`ArchiveError.cancelled`): the
    /// child processes and temporary files of the opening are gone and nothing is cached.
    func archive(at url: URL, cancellation: CancellationFlag? = nil) throws -> OpenArchive {
        let key = url.locationKey
        // Open and still the file that was read: handed out at once, behind nobody's opening.
        lock.lock()
        clock += 1
        let known = opened[key]
        if known != nil { slots[key]?.lastUsed = clock }
        lock.unlock()
        if let known, known.isCurrent(cancellation: cancellation) { return known }
        return try archiveInTurn(at: url, key: key, cancellation: cancellation)
    }

    /// The archive from its slot, behind whoever opens it now: opened or read again there
    /// when needed.
    private func archiveInTurn(at url: URL, key: String, cancellation: CancellationFlag?) throws -> OpenArchive {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
        lock.lock()
        clock += 1
        let slot = slots[key] ?? Slot()
        slots[key] = slot
        slot.lastUsed = clock
        lock.unlock()

        if let cancellation {
            // Waits in turns, so that the wait for an opening that takes long can end.
            var isLocked: Bool
            repeat {
                isLocked = slot.lock.lock(before: Date(timeIntervalSinceNow: 0.05))
            } while !isLocked && !cancellation.isCancelled
            guard isLocked else { throw ArchiveError.cancelled }
        } else {
            slot.lock.lock()
        }
        // The slot may have been let go between the two locks; an archive opened into it
        // now would be a second one beside the table's. The table is asked again.
        lock.lock()
        let isListed = slots[key] === slot
        lock.unlock()
        guard isListed else {
            slot.lock.unlock()
            return try archiveInTurn(at: url, key: key, cancellation: cancellation)
        }
        defer { slot.lock.unlock() }
        if let archive = slot.archive {
            if archive.isCurrent(cancellation: cancellation) { return archive }
            // Its file was changed by someone else. It is let go for a fresh reading,
            // unless a change has just begun in it: then it stays the archive.
            guard archive.retireIfIdle() else { return archive }
        }
        if let failure = slot.failure {
            let age = Date().timeIntervalSince(failure.time)
            let unchanged =
                url.isFileURL
                ? age < Self.failureMemory && FileSignature.of(url.path) == failure.signature : age < 2
            if unchanged { throw failure.error }
            slot.failure = nil
        }
        setArchive(nil, of: slot, key: key)
        do {
            let archive = try open(url, cancellation: cancellation)
            setArchive(archive, of: slot, key: key)
            evict(keeping: key)
            return archive
        } catch {
            if cancellation?.isCancelled == true {
                // A stopped attempt says nothing about the archive: no failure is kept, and
                // the empty slot goes (whoever waits for it makes a new one).
                lock.lock()
                if slots[key] === slot { slots[key] = nil }
                lock.unlock()
                throw ArchiveError.cancelled
            }
            // Only what the file itself is to blame for is remembered; a full disk or a
            // tool that was killed may be over the next time.
            if Self.isAboutTheFile(error) {
                slot.failure = (error, url.isFileURL ? FileSignature.of(url.path) : nil, Date())
            }
            throw error
        }
    }

    private static func isAboutTheFile(_ error: any Error) -> Bool {
        switch error {
        case ArchiveError.notAnArchive, ArchiveError.damaged, ArchiveError.unsupported: return true
        default: return false
        }
    }

    /// Called with the slot's lock held.
    private func setArchive(_ archive: OpenArchive?, of slot: Slot, key: String) {
        slot.archive = archive
        lock.lock()
        var previous: OpenArchive?
        if slots[key] === slot {
            previous = opened.removeValue(forKey: key)
            opened[key] = archive
        }
        lock.unlock()
        // Released here, outside the table's lock.
        _ = previous
    }

    private func open(_ url: URL, cancellation: CancellationFlag?) throws -> OpenArchive {
        guard ArchiveURL.nesting(of: url) < environment.maxNesting else {
            throw ArchiveError.unsupported("An archive more than \(environment.maxNesting) archives deep")
        }
        if url.isFileURL {
            var status = stat()
            guard stat(url.path, &status) == 0 else { throw posixError(errno, url.path) }
            guard status.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.notAnArchive(url.lastPathComponent) }
            // Reached through a symbolic link, the archive is changed where it really lies:
            // a new file put at the link's place would leave the real one as it was.
            return try OpenArchive(
                archiveURL: url,
                localURL: Durable.realFile(url),
                fetchedCopy: nil,
                remoteStamp: nil,
                cancellation: cancellation,
                environment: environment
            )
        }
        // An archive on a server or inside another archive is fetched to the disk first
        // (spec 08 › Nested archives). The copy is removed again when the fetch is given up.
        guard let fileSystems = environment.fileSystems() else { throw FileSystemError.noProvider(url) }
        let flag = cancellation ?? CancellationFlag()
        let provider = try fileSystems.provider(for: url)
        guard let item = provider.item(at: url, cancellation: flag), !item.isDirectory else {
            throw flag.isCancelled ? ArchiveError.cancelled : ArchiveError.notAnArchive(url.lastPathComponent)
        }
        let local = try environment.scratch.newFile(url.pathExtension.isEmpty ? "archive" : url.pathExtension)
        // Not unless the copy fits beside what must stay free; the size is what the other
        // side claims, so the room is watched while the copy grows, too.
        let scratch = environment.scratch.url
        guard environment.hasRoom(environment.scratchReserve.plusClamped(UInt64(max(0, item.size))), scratch) else {
            throw ArchiveError.noScratchRoom(url.lastPathComponent)
        }
        let room = SpaceWatch(folder: scratch, reserve: environment.scratchReserve, hasRoom: environment.hasRoom)
        let copy = TemporaryFile(local)
        let reader = try provider.read(url, cancellation: flag)
        defer { reader.close() }
        // A read that waits on a server is ended by the flag too.
        let tie = flag.interrupting(reader)
        defer { withExtendedLifetime(tie) {} }
        let output = try OutputFile(creating: local)
        while let block = try reader.read(upToCount: 1 << 20) {
            if flag.isCancelled { throw ArchiveError.cancelled }
            guard room.allows(UInt64(block.count)) else {
                output.discard()
                throw ArchiveError.noScratchRoom(url.lastPathComponent)
            }
            try output.write(block)
        }
        try output.close()
        // An archive inside an archive from the internet is from the internet too, and so is
        // one fetched from a server: the copy carries the mark, and so does what is unpacked.
        let quarantine = provider.quarantine(of: url)
        Quarantine.apply(quarantine, to: local)
        return try OpenArchive(
            archiveURL: url,
            localURL: local,
            fetchedCopy: copy,
            remoteStamp: (item.size, item.modified),
            quarantine: quarantine,
            cancellation: cancellation,
            environment: environment
        )
    }

    /// The archive if it is open now; never opens one and never waits for one that is being
    /// opened. Safe on the main thread.
    func openArchive(at url: URL) -> OpenArchive? {
        lock.lock()
        defer { lock.unlock() }
        return opened[url.locationKey]
    }

    /// Lets go of archives that are not in use, least recently used first: those beyond
    /// `capacity`, and those whose temporary copies take more room together than the budget.
    private func evict(keeping key: String) {
        // `lastUsed` belongs to the table's lock, `archive` to the slot's own.
        lock.lock()
        let candidates = slots.filter { $0.key != key }
            .map {
                (key: $0.key, slot: $0.value, lastUsed: $0.value.lastUsed)
            }
            .sorted { $0.lastUsed < $1.lastUsed }
        let archives = Array(opened.values)
        lock.unlock()
        var excess = candidates.count - capacity + 1
        var bytes = archives.reduce(UInt64(0)) { $0.plusClamped($1.scratchBytes) }
        let budget = environment.scratchBudget
        guard excess > 0 || bytes > budget else { return }
        for (candidate, slot, _) in candidates {
            guard excess > 0 || bytes > budget else { break }
            // Never while it is being opened; and an archive goes only by `retireIfIdle`,
            // which refuses while changes wait or a member is being written, and after which
            // no change can begin in it.
            guard slot.lock.try() else { continue }
            var released: OpenArchive?
            let size = slot.archive?.scratchBytes ?? 0
            if excess > 0 || size > 0, slot.archive?.retireIfIdle() != false {
                lock.lock()
                if slots[candidate] === slot {
                    slots[candidate] = nil
                    released = opened.removeValue(forKey: candidate)
                }
                lock.unlock()
                excess -= 1
                bytes -= min(bytes, size)
            }
            slot.lock.unlock()
            _ = released
        }
    }

    /// The archives that are open, from the table alone.
    private var openArchives: [OpenArchive] {
        lock.lock()
        defer { lock.unlock() }
        return Array(opened.values)
    }

    /// True when changes wait to be written into some archive.
    var hasPendingChanges: Bool {
        openArchives.contains(where: \.hasPendingChanges)
    }

    /// Writes the pending changes of every archive; returns what could not be written.
    ///
    /// Writing an archive that lies inside another archive (or on a server whose file system
    /// keeps writes back) gives the outer one changes of its own, so the archives are taken
    /// innermost first and the round is repeated until nothing waits any more, or until a
    /// whole round has written nothing. With a `cancellation` the writes end soon after it
    /// is set. Blocks for as long as the writes take; not for the main thread.
    @discardableResult
    func flushAll(cancellation: CancellationFlag? = nil) -> [(name: String, error: any Error, archive: OpenArchive)] {
        var failed: [ObjectIdentifier: (name: String, error: any Error, archive: OpenArchive)] = [:]
        for _ in 0..<(2 * environment.maxNesting + 4) {
            let pending = openArchives.filter(\.hasPendingChanges)
                .sorted { ArchiveURL.nesting(of: $0.archiveURL) > ArchiveURL.nesting(of: $1.archiveURL) }
            guard !pending.isEmpty else { break }
            var wrote = false
            for archive in pending {
                do {
                    try archive.flush(cancellation: cancellation)
                    failed[ObjectIdentifier(archive)] = nil
                    wrote = true
                } catch {
                    failed[ObjectIdentifier(archive)] = (archive.name, error, archive)
                }
            }
            if !wrote || cancellation?.isCancelled == true { break }
        }
        return failed.values.sorted { $0.name < $1.name }
    }

    /// Writes the pending changes of the archive at `url`, if it is open and has any.
    func flush(_ url: URL, cancellation: CancellationFlag? = nil) throws {
        try openArchive(at: url)?.flush(cancellation: cancellation)
    }

    /// Makes the archive at `url` hold what was written into it, see `OpenArchive.commit`.
    /// An archive that is not in the table holds nothing unwritten (see the class comment).
    func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        try openArchive(at: url)?.commit(cancellation: cancellation, progress: progress)
    }

    /// Brings the file at `url` up to date before somebody else reads, moves or deletes it
    /// (`FileSystemRegistry.flushPendingWrites`): the open archives that are that file, or lie
    /// in the folder it is, or lie inside such an archive, get their pending changes written,
    /// innermost first. A look into the table for every other file: no archive is opened, and
    /// none that has nothing waiting is touched.
    func bringUpToDate(_ url: URL, cancellation: CancellationFlag) throws {
        let concerns = { (archive: OpenArchive) in Self.archive(archive, liesIn: url) }
        func pending() -> [OpenArchive] {
            openArchives.filter { $0.hasPendingChanges && concerns($0) }
                .sorted { ArchiveURL.nesting(of: $0.archiveURL) > ArchiveURL.nesting(of: $1.archiveURL) }
        }
        // Writing an archive gives the one it lies in changes of its own: the rounds go on
        // until nothing waits, but not for ever.
        var (waiting, rounds) = (pending(), 0)
        while !waiting.isEmpty, rounds < 2 * environment.maxNesting + 4 {
            for archive in waiting { try archive.commit(cancellation: cancellation) }
            (waiting, rounds) = (pending(), rounds + 1)
        }
    }

    /// Whether an archive is the file at `url`, lies in that folder, or inside such an archive.
    private static func archive(_ archive: OpenArchive, liesIn url: URL) -> Bool {
        // The file an archive inside archives finally lies in.
        var file = archive.archiveURL
        for _ in 0..<64 {
            guard case .inside(let location)? = ArchiveURL.parse(file) else { break }
            file = location.archive
        }
        file = ArchiveURL.resolved(file)
        return file.isSameLocation(as: url) || PathSafety.isContained(file, in: url)
    }

    /// Lets go of the archives that lie on `volume` (before it is ejected): their files are
    /// closed. Only archives with nothing left to write go (`retireIfIdle`); the eject has
    /// written their changes first (`bringUpToDate`). One in use stays, and the eject is
    /// then refused for it. Blocks on the archives' own locks: not for the main thread.
    func release(on volume: URL) {
        // `opened` belongs to the table's lock, a slot's `archive` to the slot's own.
        lock.lock()
        let candidates = opened.filter { Self.archive($0.value, liesIn: volume) }
            .compactMap { key, _ in
                slots[key].map { (key, $0) }
            }
        lock.unlock()
        for (key, slot) in candidates where slot.lock.try() {
            var released: OpenArchive?
            if slot.archive?.retireIfIdle() != false {
                lock.lock()
                if slots[key] === slot {
                    slots[key] = nil
                    released = opened.removeValue(forKey: key)
                }
                lock.unlock()
            }
            slot.lock.unlock()
            _ = released
        }
    }

    /// For the archives whose changes still wait (their write has failed): saves what can be
    /// saved, see `OpenArchive.rescue()`.
    func rescueAll(quickly: Bool = false, before deadline: Date = .distantFuture) -> [(
        name: String, outcome: RescueOutcome, archive: OpenArchive
    )] {
        openArchives.filter(\.hasPendingChanges).map { ($0.name, $0.rescue(quickly: quickly, before: deadline), $0) }
    }

    /// Lets go of every archive and of the temporary files. From here on the delayed writes
    /// of archives that somebody still holds do nothing: there is nothing left to write from.
    func close() {
        environment.isStopping = true
        lock.lock()
        let (oldSlots, oldArchives) = (slots, opened)
        (slots, opened) = ([:], [:])
        lock.unlock()
        // Released outside the lock: an archive that goes away closes files and child processes.
        _ = (oldSlots, oldArchives)
        environment.scratch.removeAll()
    }
}

/// Archives as folders (spec 08 › Archives as folders): a file system whose "volumes" are
/// archive files. The same class serves two schemes, because a file system states what it can
/// do as a whole: `zip:` for archives that can be changed, `archive:` for those that are only
/// read. See `ArchiveURL` for how the URLs are made. What a particular archive can do is
/// told by `capabilities(for:)`: a ZIP that lists a name twice, or lies where nothing can be
/// written, is read-only like the others.
///
/// **Threading.** Every method may be called from any thread at once; the state is in
/// `ArchiveStore` and `OpenArchive`, which guard themselves. `parent(of:)`, `displayPath(_:)`
/// and `capabilities` work on the URL alone; `capabilities(for:)` also looks at the archives
/// that are open, never opens one, and waits for no lock that is held while a file is read or
/// written: both are safe on the main thread. So is `location(from:)`, which asks the disk
/// about a typed path that contains a name ending like an archive only where the path lies on
/// a disk of this machine, and decides from the text alone where it lies on a server.
/// Everything else may wait for a disk or a server and belongs to a background thread.
final class ArchiveFileSystem: FileSystemProvider {
    let scheme: String
    let capabilities: FileSystemCapabilities
    private let store: ArchiveStore

    /// What lies at a path of this machine, without asking a volume that may not answer
    /// (`Volume.kind(ofLocalPath:)`).
    private let pathKind: @Sendable (String) -> Volume.PathKind

    internal convenience init(scheme: String, store: ArchiveStore) {
        self.init(scheme: scheme, store: store) { Volume.kind(ofLocalPath: $0) }
    }

    /// The same with `pathKind` in place of the look at the disks (tests: a path on a server).
    internal init(scheme: String, store: ArchiveStore, pathKind: @escaping @Sendable (String) -> Volume.PathKind) {
        self.scheme = scheme
        self.store = store
        self.pathKind = pathKind
        capabilities = scheme == ArchiveURL.writableScheme ? [.write, .deferredWrites] : []
    }

    private enum Target {
        case inside(OpenArchive, path: String, location: ArchiveLocation)
        /// A place on the file system the archive lies on.
        case outside(any FileSystemProvider, URL)
    }

    private var fileSystems: FileSystemRegistry? { store.environment.fileSystems() }

    private func outerProvider(for url: URL) throws -> any FileSystemProvider {
        guard let fileSystems else { throw FileSystemError.noProvider(url) }
        return try fileSystems.provider(for: url)
    }

    private func resolve(_ url: URL, cancellation: CancellationFlag? = nil) throws -> Target {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            do {
                return .inside(
                    try store.archive(at: location.archive, cancellation: cancellation),
                    path: location.innerPath,
                    location: location
                )
            } catch ArchiveError.notAnArchive {
                // A folder that is named like an archive (a typed path on a server is read
                // by its text alone): the place is simply further down that folder.
                let provider = try outerProvider(for: location.archive)
                let found =
                    cancellation.map { provider.item(at: location.archive, cancellation: $0) }
                    ?? provider.item(at: location.archive)
                guard found?.isRealDirectory == true else {
                    throw ArchiveError.notAnArchive(location.archive.lastPathComponent)
                }
                let place = ArchiveTree.names(of: location.innerPath)
                    .reduce(location.archive) {
                        $0.appending(name: $1)
                    }
                return .outside(provider, place)
            }

        case .outside(let outer):
            return .outside(try outerProvider(for: outer), outer)

        case nil:
            throw FileSystemError.noProvider(url)
        }
    }

    /// Which of the two schemes an archive file is shown under: the writable one for ZIP
    /// files on a file system that can itself be written to.
    static func scheme(forArchive url: URL, fileSystems: FileSystemRegistry?, isZip: Bool? = nil) -> String {
        let zip = isZip ?? zipExtensions.contains(url.pathExtension.lowercased())
        let writable = fileSystems?.capabilities(for: url).contains(.write) ?? false
        return zip && writable ? ArchiveURL.writableScheme : ArchiveURL.readOnlyScheme
    }

    /// The endings of files that are ZIP archives under another name.
    static let zipExtensions: Set<String> = [
        "zip", "jar", "war", "ear", "apk", "ipa", "epub", "cbz", "xpi", "whl", "docx", "xlsx", "pptx",
        "odt", "ods", "odp"
    ]

    // MARK: Reading

    func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try listing(directory, showHidden: showHidden, cancellation: nil)
    }

    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        try listing(directory, showHidden: showHidden, cancellation: cancellation)
    }

    func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        if case .outside(let provider, let outer) = try resolve(directory) {
            try provider.list(outer, showHidden: showHidden, receive: receive)
            return
        }
        _ = receive(try listing(directory, showHidden: showHidden, cancellation: nil))
    }

    func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool) throws
    {
        if case .outside(let provider, let outer) = try resolve(directory, cancellation: cancellation) {
            try provider.list(outer, showHidden: showHidden, cancellation: cancellation, receive: receive)
            return
        }
        let items = try listing(directory, showHidden: showHidden, cancellation: cancellation)
        if !cancellation.isCancelled { _ = receive(items) }
    }

    private func listing(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag?) throws -> [FileItem] {
        switch try resolve(directory, cancellation: cancellation) {
        case .outside(let provider, let outer):
            guard let cancellation else { return try provider.list(outer, showHidden: showHidden) }
            return try provider.list(outer, showHidden: showHidden, cancellation: cancellation)

        case .inside(let archive, let path, _):
            guard let children = archive.children(of: path) else {
                throw archive.entry(path) == nil ? ArchiveError.notFound(path) : ArchiveError.notADirectory(path)
            }
            let base = directory.standardized
            return children.filter { showHidden || !$0.name.hasPrefix(".") }
                .map {
                    $0.item(at: base.appending(name: $0.name))
                }
        }
    }

    func item(at url: URL) -> FileItem? {
        item(at: url, cancellation: nil)
    }

    func item(at url: URL, cancellation: CancellationFlag) -> FileItem? {
        item(at: url, cancellation: Optional(cancellation))
    }

    private func item(at url: URL, cancellation: CancellationFlag?) -> FileItem? {
        guard cancellation?.isCancelled != true, let target = try? resolve(url, cancellation: cancellation) else {
            return nil
        }
        switch target {
        case .outside(let provider, let outer):
            guard let cancellation else { return provider.item(at: outer) }
            return provider.item(at: outer, cancellation: cancellation)

        case .inside(let archive, let path, _):
            if path.isEmpty {
                return FileItem(
                    url: url,
                    name: archive.name,
                    kind: .directory,
                    stat: .init(modified: archive.modified, permissions: 0o755)
                )
            }
            return archive.entry(path)?.item(at: url)
        }
    }

    func parent(of directory: URL) -> URL? {
        // Only URLs of this scheme have a parent here; the folder that holds the archive
        // belongs to another file system, and there the climb ends.
        guard directory.scheme == scheme, let place = ArchiveURL.parse(directory) else { return nil }
        switch place {
        case .inside(let location):
            if location.isRoot { return location.archive.deletingLastPathComponent() }
            return ArchiveURL.make(
                scheme: scheme,
                archive: location.archive,
                innerPath: ArchiveTree.parent(of: location.innerPath)
            )

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.parent(of: outer)
        }
    }

    /// Where going up with `parent(of:)` ends, found at once: the folder the archive file
    /// lies in (for an archive inside archives, the folder of the outermost that this scheme
    /// shows). A location deep inside an archive is not climbed name by name for it.
    func root(of url: URL) -> URL {
        var current = url
        // (No honest location is nested deeper than archives may be.)
        for _ in 0..<64 {
            guard current.scheme == scheme, let place = ArchiveURL.parse(current) else { break }
            let above: URL?
            switch place {
            case .inside(let location): above = location.archive.deletingLastPathComponent()
            case .outside(let outer): above = (try? outerProvider(for: outer))?.parent(of: outer)
            }
            guard let above else { break }
            current = above
        }
        return current
    }

    func read(_ url: URL) throws -> any FileReader {
        try reading(url, cancellation: nil)
    }

    /// Opening a member that lies behind a long stretch of decompression ends when the flag is
    /// set; so does the opening of the archive. The reader that is returned is ended with its
    /// `interrupt()`.
    func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        try reading(url, cancellation: cancellation)
    }

    private func reading(_ url: URL, cancellation: CancellationFlag?) throws -> any FileReader {
        switch try resolve(url, cancellation: cancellation) {
        case .outside(let provider, let outer):
            guard let cancellation else { return try provider.read(outer) }
            return try provider.read(outer, cancellation: cancellation)

        case .inside(let archive, let path, _):
            guard let entry = archive.entry(path) else { throw ArchiveError.notFound(path) }
            guard !entry.isDirectory else { throw FileSystemError.notSupported("Reading the folder \(path)") }
            return try ArchiveMemberReader(cancellation: cancellation) { try archive.open(entry, slot: $0) }
        }
    }

    // MARK: Changing

    /// Runs a change. The store may let an archive go between handing it out and the change
    /// (its file was replaced, or it was the least recently used): the archive then refuses
    /// the change, and the change is made in the archive the store has now. So a change
    /// never lands in an archive that nobody will write.
    private func changing<T>(attempts: Int = 8, _ body: () throws -> T) throws -> T {
        do { return try body() } catch ArchiveError.retired where attempts > 0 {
            return try changing(attempts: attempts - 1, body)
        }
    }

    // Each change also comes with a `cancellation`: the wait for an archive that is being
    // opened (or fetched from a server) ends when it is set, and a place outside the archive
    // hands the flag on to the file system it belongs to.

    func createDirectory(at url: URL) throws {
        try makeDirectory(at: url, cancellation: nil)
    }

    func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try makeDirectory(at: url, cancellation: cancellation)
    }

    private func makeDirectory(at url: URL, cancellation: CancellationFlag?) throws {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                if let cancellation {
                    try provider.createDirectory(at: outer, cancellation: cancellation)
                } else {
                    try provider.createDirectory(at: outer)
                }

            case .inside(let archive, let path, _):
                try Self.check(cancellation)
                try archive.makeDirectory(path)
            }
        }
    }

    private static func check(_ cancellation: CancellationFlag?) throws {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
    }

    func write(_ url: URL) throws -> any FileWriter {
        try changing {
            switch try resolve(url) {
            case .outside(let provider, let outer): return try provider.write(outer)
            case .inside(let archive, let path, _): return try archive.write(path)
            }
        }
    }

    func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer): return try provider.write(outer, cancellation: cancellation)

            case .inside(let archive, let path, _):
                if cancellation.isCancelled { throw ArchiveError.cancelled }
                return try archive.write(path)
            }
        }
    }

    /// A place outside the archive may allow it; a member of an archive cannot be continued.
    func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        switch try resolve(url, cancellation: cancellation) {
        case .outside(let provider, let outer):
            return try provider.append(to: outer, at: offset, cancellation: cancellation)

        case .inside: throw FileSystemError.notSupported("Continuing a file inside an archive")
        }
    }

    func remove(_ url: URL) throws {
        try removing(url, cancellation: nil)
    }

    func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try removing(url, cancellation: cancellation)
    }

    private func removing(_ url: URL, cancellation: CancellationFlag?) throws {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                if let cancellation {
                    try provider.remove(outer, cancellation: cancellation)
                } else {
                    try provider.remove(outer)
                }

            case .inside(let archive, let path, _):
                try Self.check(cancellation)
                try archive.remove(path)
            }
        }
    }

    /// Whether two places are in the same archive, or both outside one: only then can this
    /// file system move or copy between them itself. Decided from the URLs, before any archive
    /// is opened.
    private func requireSameVolume(_ source: URL, _ destination: URL) throws {
        switch (ArchiveURL.parse(source), ArchiveURL.parse(destination)) {
        case (.inside(let from), .inside(let to)) where from.archive.isSameLocation(as: to.archive): return
        case (.outside, .outside): return
        default: throw FileSystemError.crossesVolumes
        }
    }

    func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try moving(source, to: destination, replacing: replacing, cancellation: nil)
    }

    func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try moving(source, to: destination, replacing: replacing, cancellation: cancellation)
    }

    private func moving(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag?) throws {
        try requireSameVolume(source, destination)
        try changing {
            switch (
                try resolve(source, cancellation: cancellation), try resolve(destination, cancellation: cancellation)
            ) {
            case (.outside(let provider, let from), .outside(let other, let to)) where provider === other:
                if let cancellation {
                    try provider.move(from, to: to, replacing: replacing, cancellation: cancellation)
                } else {
                    try provider.move(from, to: to, replacing: replacing)
                }

            case (.inside(let archive, let from, _), .inside(let other, let to, _)) where archive === other:
                try Self.check(cancellation)
                try archive.move(from, to: to, replacing: replacing)

            case (.inside, .inside):
                // The archive was read anew between the two look-ups.
                throw ArchiveError.retired

            default:
                throw FileSystemError.crossesVolumes
            }
        }
    }

    func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try requireSameVolume(source, destination)
        try changing {
            switch (try resolve(source), try resolve(destination)) {
            case (.outside(let provider, let from), .outside(let other, let to)) where provider === other:
                try provider.copy(from, to: to, progress: progress)

            case (.inside(let archive, let from, _), .inside(let other, let to, _))
            where archive === other && archive.format.isEditable:
                _ = progress(try archive.duplicate(from, to: to))

            default:
                throw FileSystemError.crossesVolumes
            }
        }
    }

    /// The same with the caller's flag, which a place outside the archive is handed on to:
    /// its file system can then end a copy that waits.
    func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool) throws {
        try Self.check(cancellation)
        try requireSameVolume(source, destination)
        try changing {
            switch (
                try resolve(source, cancellation: cancellation), try resolve(destination, cancellation: cancellation)
            ) {
            case (.outside(let provider, let from), .outside(let other, let to)) where provider === other:
                try provider.copy(from, to: to, cancellation: cancellation, progress: progress)

            case (.inside(let archive, let from, _), .inside(let other, let to, _))
            where archive === other && archive.format.isEditable:
                _ = progress(try archive.duplicate(from, to: to))

            default:
                throw FileSystemError.crossesVolumes
            }
        }
    }

    func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try settingAttributes(attributes, of: url, cancellation: nil)
    }

    func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try settingAttributes(attributes, of: url, cancellation: cancellation)
    }

    private func settingAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag?) throws {
        try changing {
            switch try resolve(url, cancellation: cancellation) {
            case .outside(let provider, let outer):
                if let cancellation {
                    try provider.setAttributes(attributes, of: outer, cancellation: cancellation)
                } else {
                    try provider.setAttributes(attributes, of: outer)
                }

            case .inside(let archive, let path, _):
                try Self.check(cancellation)
                try archive.setAttributes(attributes, of: path)
            }
        }
    }

    // MARK: Per location

    func capabilities(for url: URL) -> FileSystemCapabilities {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            guard !capabilities.isEmpty else { return [] }
            // What is known of the archive if it is open; the scheme's word until then.
            return store.openArchive(at: location.archive)?.capabilities ?? capabilities

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.capabilities(for: outer) ?? []

        case nil:
            return []
        }
    }

    /// Writes into the archive file whatever is still kept back for it: the new members, the
    /// renames, removals and changes of attributes. For an archive that lies in another archive
    /// or on a server that keeps writes back, that one is committed too, so that it is the
    /// last to hold the data. Returns when the file on the disk holds it all; throws what the
    /// write throws, and the changes wait for the next attempt.
    func commit(_ url: URL, cancellation: CancellationFlag) throws {
        try committing(url, cancellation: cancellation) { _, _ in true }
    }

    /// The same, asking `progress` between the members that are written (and, for an archive
    /// that came from a server, between the blocks that are sent back): with the bytes
    /// written and expected, and false ends the write, which then has changed nothing. A
    /// job that is paused waits inside `progress`, so Pause takes hold in a commit that is
    /// under way (F046).
    func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        var stopped = false
        do {
            try committing(url, cancellation: cancellation) { done, total in
                if !progress(done, total) { stopped = true }
                return !stopped
            }
        } catch ArchiveError.cancelled where stopped {
            // What the protocol says of a commit that `progress` ended.
            throw CocoaError(.userCancelled)
        }
    }

    private func committing(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            try store.commit(location.archive, cancellation: cancellation, progress: progress)
            if let outer = try? outerProvider(for: location.archive),
                outer.capabilities(for: location.archive).contains(.deferredWrites)
            {
                try outer.commit(location.archive, cancellation: cancellation, progress: progress)
            }

        case .outside(let outer):
            try outerProvider(for: outer).commit(outer, cancellation: cancellation, progress: progress)

        case nil:
            break
        }
    }

    /// The mark of the archive file itself, which everything inside carries (for an archive
    /// inside another archive, the outermost file's).
    func quarantine(of url: URL) -> Data? {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            // Of the archive that is open, without waiting; it is opened only when it is not.
            return (store.openArchive(at: location.archive) ?? (try? store.archive(at: location.archive)))?.quarantine

        case .outside(let outer): return (try? outerProvider(for: outer))?.quarantine(of: outer)
        case nil: return nil
        }
    }

    /// Members of an archive cannot carry a mark; a place outside it may.
    func setQuarantine(_ value: Data, of url: URL) throws {
        if case .outside(let outer)? = ArchiveURL.parse(url) {
            try outerProvider(for: outer).setQuarantine(value, of: outer)
        }
    }

    func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        if case .outside(let outer)? = ArchiveURL.parse(url) {
            try outerProvider(for: outer).setQuarantine(value, of: outer, cancellation: cancellation)
        }
    }

    /// A place that only passes through an archive scheme is the place on the file system
    /// the archive lies on; a place inside an archive is itself. Works on the URL alone.
    func realLocation(of url: URL) -> URL? {
        if case .outside(let outer)? = ArchiveURL.parse(url) { return outer }
        return nil
    }

    /// The members of an archive that can only be read front to back (a compressed TAR, a 7z
    /// too large for a temporary copy) come in the order they lie in it: read that way, one
    /// pass through the archive serves them all (a reader that has delivered a member waits
    /// for the next, see `OpenArchive.open`), where any other order starts the decompression
    /// over for every member that lies before the one read last. Members of archives that
    /// are read at any place, and locations that are no members, keep their places.
    ///
    /// Opens no archive: one that is not open yet is opened by the first read, and its
    /// members are then read in the order given. Not for the main thread all the same (it
    /// takes the archive's lock for the look-ups).
    func readOrder(of urls: [URL]) -> [URL] {
        guard urls.count > 1 else { return urls }
        var archives: [String: OpenArchive?] = [:]
        var places: [String: [(index: Int, order: Int)]] = [:]
        for (index, url) in urls.enumerated() {
            guard case .inside(let location)? = ArchiveURL.parse(url), !location.isRoot else { continue }
            let key = location.archive.locationKey
            if archives[key] == nil {
                let open = store.openArchive(at: location.archive)
                archives[key] = .some(open?.allowsParallelReads == false ? open : nil)
            }
            guard let archive = archives[key].flatMap(\.self), let entry = archive.entry(location.innerPath) else {
                continue
            }
            places[key, default: []].append((index, entry.order))
        }
        guard !places.isEmpty else { return urls }
        var result = urls
        for members in places.values where members.count > 1 {
            // The members of one archive change places among themselves only.
            let sorted = members.sorted { ($0.order, $0.index) < ($1.order, $1.index) }
            for (slot, member) in zip(members.map(\.index), sorted) { result[slot] = urls[member.index] }
        }
        return result
    }

    // MARK: Surroundings

    /// The path of the archive file with the path inside appended, as Total Commander shows
    /// it: `/Users/me/photos.zip/2026`.
    func displayPath(_ url: URL) -> String {
        switch ArchiveURL.parse(url) {
        case .inside(let location):
            let archive = fileSystems?.displayPath(location.archive) ?? location.archive.path
            return location.isRoot ? archive : archive + "/" + location.innerPath

        case .outside(let outer):
            return fileSystems?.displayPath(outer) ?? outer.path

        case nil:
            return url.absoluteString
        }
    }

    /// Reads the full URL form and what `displayPath` writes for archives on the local disk:
    /// a path that runs through a file whose name ends like an archive.
    ///
    /// This is called on the main thread for every path the user types, so it never asks a
    /// volume that may not answer. Where the path lies on a disk of this machine the disk
    /// says whether the name is a file (an archive), a folder or nothing, as fast as it says
    /// anything. Where it lies on a server the text decides: a path that goes on behind such
    /// a name runs through an archive (and if the name turns out to be a folder, the listing
    /// finds that out in the background and shows the folder); a path that ends with the name
    /// is the file itself, as it is for a new archive that Pack is to write.
    func location(from text: String) -> URL? {
        if text.lowercased().hasPrefix(scheme + "://"), let url = URL(string: text), url.scheme == scheme { return url }
        var path = text
        if path == "~" || path.hasPrefix("~/") { path = NSString(string: path).expandingTildeInPath }
        guard path.hasPrefix("/") else { return nil }
        let names = ArchiveTree.names(of: path)
        let known = store.environment.options.extensions.union(Self.zipExtensions)
            .union(
                ArchiveFormat.writable.flatMap(\.extensions)
            )
        var prefix = ""
        for (index, name) in names.enumerated() {
            prefix += "/" + name
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, known.contains(ext) else { continue }
            switch pathKind(prefix) {
            case .regularFile: break
            case .directory, .other: continue
            case .missing: return nil
            case .unasked: if index == names.count - 1 { return nil }
            }
            let archive = URL(fileURLWithPath: prefix, isDirectory: false)
            guard Self.scheme(forArchive: archive, fileSystems: fileSystems) == scheme else { return nil }
            let inner = ArchiveTree.normalized(names[(index + 1)...].joined(separator: "/")) ?? ""
            return ArchiveURL.make(scheme: scheme, archive: archive, innerPath: inner)
        }
        return nil
    }

    func volume(of url: URL) -> VolumeInfo? {
        switch ArchiveURL.parse(url) {
        case .inside(let location): return VolumeInfo(name: location.archive.lastPathComponent)
        case .outside(let outer): return (try? outerProvider(for: outer))?.volume(of: outer)
        case nil: return nil
        }
    }

    func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        switch ArchiveURL.parse(url) {
        case .inside(let location): return VolumeInfo(name: location.archive.lastPathComponent)

        case .outside(let outer):
            return (try? outerProvider(for: outer))?.volume(of: outer, cancellation: cancellation)

        case nil: return nil
        }
    }
}
