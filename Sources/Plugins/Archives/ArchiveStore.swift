import AFMKernel
import Foundation

/// The archives that are open, one `OpenArchive` per archive file, so that the directory of an
/// archive is parsed once however many panels, jobs and searches look into it.
///
/// An archive is read again when its file changed on disk (size, date or identity).
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
internal final class ArchiveStore: @unchecked Sendable {
    /// Why a file could not be opened, and the state of the file that goes with it.
    private struct Failure {
        let error: any Error
        let signature: FileSignature?
        let time: Date
    }

    private final class Slot {
        let lock = NSLock()
        var archive: OpenArchive?
        /// Why the file could not be opened: a broken archive is not parsed again for every
        /// question about it.
        var failure: Failure?
        var lastUsed = 0

        deinit {
            // Nothing to release.
        }
    }

    /// How long the reason a file could not be opened is repeated without looking again.
    internal static let failureMemory: TimeInterval = 30

    /// The settings, the temporary folder and the file systems the archives are opened with.
    internal let environment: ArchiveEnvironment
    private let lock = NSLock()
    private var slots: [String: Slot] = [:]
    /// The archives of the slots, for readers that must not wait on a slot.
    private var opened: [String: OpenArchive] = [:]
    private var clock = 0
    /// Archives without pending changes beyond this number are let go, least recently used first.
    private let capacity = 12

    /// The archives that are open, from the table alone.
    private var openArchives: [OpenArchive] {
        lock.lock()
        defer { lock.unlock() }
        return Array(opened.values)
    }

    /// True when changes wait to be written into some archive.
    internal var hasPendingChanges: Bool {
        openArchives.contains(where: \.hasPendingChanges)
    }

    /// An empty store that opens its archives with `environment`.
    internal init(environment: ArchiveEnvironment) {
        self.environment = environment
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

    /// Throws the reason the file at `url` could not be opened while that is remembered (the
    /// file has not changed, and not much time has gone by); forgets an older one.
    ///
    /// Called with the slot's lock held.
    private static func repeatFailure(of slot: Slot, for url: URL) throws {
        guard let failure = slot.failure else {
            return
        }
        let age = Date().timeIntervalSince(failure.time)
        let unchanged =
            url.isFileURL
            ? age < Self.failureMemory && FileSignature.of(url.path) == failure.signature : age < 2
        if unchanged { throw failure.error }
        slot.failure = nil
    }

    /// The open archive for the file at `url`, opening or re-reading it when needed.
    ///
    /// With a `cancellation`, a thread that waits for another's opening of the same archive, or
    /// that opens it, gives up soon after the flag is set (`ArchiveError.cancelled`): the child
    /// processes and temporary files of the opening are gone and nothing is cached.
    internal func archive(at url: URL, cancellation: CancellationFlag?) throws -> OpenArchive {
        let key = url.locationKey
        // Open and still the file that was read: handed out at once, behind nobody's opening.
        lock.lock()
        clock += 1
        let known = opened[key]
        if known != nil { slots[key]?.lastUsed = clock }
        lock.unlock()
        if let known, known.isCurrent(cancellation: cancellation) {
            return known
        }
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
        try slot.lock.lock(unlessCancelled: cancellation)
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
        // One whose file was changed by someone else is let go for a fresh reading, unless a
        // change has begun in it since it was looked at: then it stays the archive.
        if let archive = slot.archive, archive.isCurrent(cancellation: cancellation) || !archive.retireIfIdle() {
            return archive
        }
        try Self.repeatFailure(of: slot, for: url)
        setArchive(nil, of: slot, key: key)
        do {
            let archive = try ArchiveOpener(environment: environment).open(url, cancellation: cancellation)
            setArchive(archive, of: slot, key: key)
            evict(keeping: key)
            return archive
        } catch {
            throw failed(slot, key: key, url: url, error: error, cancellation: cancellation)
        }
    }

    /// What an opening that threw `error` throws on: the stop, or the error, which is
    /// remembered when the file itself is to blame.
    ///
    /// Called with the slot's lock held.
    private func failed(
        _ slot: Slot,
        key: String,
        url: URL,
        error: any Error,
        cancellation: CancellationFlag?
    ) -> any Error {
        if cancellation?.isCancelled == true {
            // A stopped attempt says nothing about the archive: no failure is kept, and
            // the empty slot goes (whoever waits for it makes a new one).
            lock.lock()
            if slots[key] === slot { slots[key] = nil }
            lock.unlock()
            return ArchiveError.cancelled
        }
        // Only what the file itself is to blame for is remembered; a full disk or a
        // tool that was killed may be over the next time.
        if ArchiveError.isAboutTheFile(error) {
            slot.failure = Failure(
                error: error,
                signature: url.isFileURL ? FileSignature.of(url.path) : nil,
                time: Date()
            )
        }
        return error
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

    /// The archive if it is open now; never opens one and never waits for one that is being
    /// opened.
    ///
    /// Safe on the main thread.
    internal func openArchive(at url: URL) -> OpenArchive? {
        lock.lock()
        defer { lock.unlock() }
        return opened[url.locationKey]
    }

    /// Lets go of archives that are not in use, least recently used first: those beyond
    /// `capacity`, and those whose temporary copies take more room together than the budget.
    private func evict(keeping key: String) {
        // `lastUsed` belongs to the table's lock, `archive` to the slot's own.
        lock.lock()
        let candidates = slots.filter { $0.key != key }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        let archives = Array(opened.values)
        lock.unlock()
        var excess = candidates.count - capacity + 1
        var bytes = archives.reduce(UInt64(0)) { total, archive in total.plusClamped(archive.scratchBytes) }
        let budget = environment.scratchBudget
        guard excess > 0 || bytes > budget else {
            return
        }
        for (candidate, slot) in candidates {
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

    /// Writes the pending changes of every archive; returns what could not be written.
    ///
    /// Writing an archive that lies inside another archive (or on a server whose file system
    /// keeps writes back) gives the outer one changes of its own, so the archives are taken
    /// innermost first and the round is repeated until nothing waits any more, or until a
    /// whole round has written nothing. With a `cancellation` the writes end soon after it
    /// is set. Blocks for as long as the writes take; not for the main thread.
    @discardableResult
    internal func flushAll(cancellation: CancellationFlag?) -> [WriteFailure] {
        var failed: [ObjectIdentifier: WriteFailure] = [:]
        for _ in 0..<(2 * environment.maxNesting + 4) {
            let pending = openArchives.filter(\.hasPendingChanges)
                .sorted { ArchiveURL.nesting(of: $0.archiveURL) > ArchiveURL.nesting(of: $1.archiveURL) }
            guard !pending.isEmpty else { break }
            var wrote = false
            for archive in pending {
                do {
                    try archive.flush(leavingOutArrivals: false, cancellation: cancellation) { _, _ in true }
                    failed[ObjectIdentifier(archive)] = nil
                    wrote = true
                } catch {
                    failed[ObjectIdentifier(archive)] = WriteFailure(name: archive.name, error: error, archive: archive)
                }
            }
            if !wrote || cancellation?.isCancelled == true { break }
        }
        return failed.values.sorted { $0.name < $1.name }
    }

    /// Writes the pending changes of the archive at `url`, if it is open and has any.
    internal func flush(_ url: URL, cancellation: CancellationFlag?) throws {
        try openArchive(at: url)?
            .flush(leavingOutArrivals: false, cancellation: cancellation) { _, _ in true }
    }

    /// Makes the archive at `url` hold what was written into it, see `OpenArchive.commit`.
    ///
    /// An archive that is not in the table holds nothing unwritten (see the class comment).
    internal func commit(_ url: URL, cancellation: CancellationFlag, progress: (Int64, Int64) -> Bool) throws {
        try openArchive(at: url)?.commit(cancellation: cancellation, progress: progress)
    }

    /// Brings the file at `url` up to date before somebody else reads, moves or deletes it
    /// (`FileSystemRegistry.flushPendingWrites`): the open archives that are that file, or lie
    /// in the folder it is, or lie inside such an archive, get their pending changes written,
    /// innermost first.
    ///
    /// A look into the table for every other file: no archive is opened, and none that has nothing
    /// waiting is touched.
    internal func bringUpToDate(_ url: URL, cancellation: CancellationFlag) throws {
        let concerns = { (archive: OpenArchive) in Self.archive(archive, liesIn: url) }
        func pending() -> [OpenArchive] {
            openArchives.filter { $0.hasPendingChanges && concerns($0) }
                .sorted { ArchiveURL.nesting(of: $0.archiveURL) > ArchiveURL.nesting(of: $1.archiveURL) }
        }
        // Writing an archive gives the one it lies in changes of its own: the rounds go on
        // until nothing waits, but not for ever.
        var (waiting, rounds) = (pending(), 0)
        while !waiting.isEmpty, rounds < 2 * environment.maxNesting + 4 {
            for archive in waiting { try archive.commit(cancellation: cancellation) { _, _ in true } }
            (waiting, rounds) = (pending(), rounds + 1)
        }
    }

    /// Lets go of the archives that lie on `volume` (before it is ejected): their files are
    /// closed.
    ///
    /// Only archives with nothing left to write go (`retireIfIdle`); the eject has written their
    /// changes first (`bringUpToDate`). One in use stays, and the eject is then refused for it.
    /// Blocks on the archives' own locks: not for the main thread.
    internal func release(on volume: URL) {
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
    internal func rescueAll(quickly: Bool, before deadline: Date) -> [Rescue] {
        openArchives.filter(\.hasPendingChanges)
            .map { Rescue(name: $0.name, outcome: $0.rescue(quickly: quickly, before: deadline), archive: $0) }
    }

    /// Lets go of every archive and of the temporary files.
    ///
    /// From here on the delayed writes of archives that somebody still holds do nothing: there is
    /// nothing left to write from.
    internal func close() {
        environment.isStopping = true
        lock.lock()
        let (oldSlots, oldArchives) = (slots, opened)
        (slots, opened) = ([:], [:])
        lock.unlock()
        // Released outside the lock: an archive that goes away closes files and child processes.
        _ = (oldSlots, oldArchives)
        environment.scratch.removeAll()
    }

    deinit {
        // Nothing to release.
    }
}
