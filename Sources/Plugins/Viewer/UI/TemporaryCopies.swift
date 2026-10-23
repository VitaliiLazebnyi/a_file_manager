import AFMKernel
import Foundation

/// Local copies of files that live on another file system, for the system frameworks that can
/// only play or preview a file on disk (spec 10 › Files that are not plain local files: such
/// files are copied to a temporary folder first). `localURL` blocks and is safe to call from
/// any thread.
///
/// Every copy has a folder of its own (two copies in flight never touch each other's file), is
/// known by where the file is together with its size and date (a file that changed is copied
/// again), and is kept for as long as a pane that asked for it shows it (`release`), then for a
/// little while in case it is shown again. `removeAll` (the plugin stopping) and the object going
/// away delete the lot; what a crash left behind is swept at the next launch.
///
/// What changes is guarded by `lock`; `directory` is immutable.
internal final class TemporaryCopies: @unchecked Sendable {
    /// A copy to be made: the file, its provider, and who keeps the copy.
    private struct Request {
        var url: URL
        var provider: any FileSystemProvider
        var fileSystems: FileSystemRegistry
        /// The file's place, size and date: copies of the same version of a file are one.
        var key: String
        /// The size the listing tells; nil when it tells none.
        var size: Int64?
        var owner: ObjectIdentifier
        var cancellation: CancellationFlag
    }

    /// Copies nobody shows that are kept for the next time.
    internal static let idleLimit = 2
    /// ... but together no more than this many bytes.
    internal static let idleByteLimit: Int64 = 512 << 20
    /// What must stay free on the disk after a copy.
    internal static let freeSpaceMargin: Int64 = 256 << 20

    private let lock = NSLock()
    private var root: URL?
    /// The copies and who shows them.
    private var ledger = CopyLedger()
    private let directory: URL
    private let disk: CopyDisk
    /// Taken while the folder of all copies is made: one thread makes it.
    private let rootLock = NSLock()

    /// What is being deleted in the background.
    private let group = DispatchGroup()

    /// Copies kept in the user's temporary folder, on the system's disk.
    internal convenience init() {
        self.init(directory: FileManager.default.temporaryDirectory, disk: .system)
    }

    /// Copies kept in `directory`, on `disk`.
    internal init(directory: URL, disk: CopyDisk) {
        self.directory = directory
        self.disk = disk
        _ = Self.sweepOnce
    }

    /// The file itself when it is on the local disk, else a copy of it read through its
    /// provider, kept for `owner` until it is released.
    ///
    /// Nil when it cannot be read or `cancellation` was set.
    internal func localURL(
        for url: URL,
        fileSystems: FileSystemRegistry,
        owner: ObjectIdentifier,
        cancellation: CancellationFlag
    ) -> URL? {
        try? localCopy(for: url, fileSystems: fileSystems, owner: owner, cancellation: cancellation).get()
    }

    /// `localURL(for:fileSystems:owner:cancellation:)` for a copy nobody in particular keeps: it is idle at once.
    internal func localURL(for url: URL, fileSystems: FileSystemRegistry, cancellation: CancellationFlag) -> URL? {
        localURL(for: url, fileSystems: fileSystems, owner: ObjectIdentifier(Self.self), cancellation: cancellation)
    }

    /// `localCopy(for:fileSystems:owner:cancellation:)` for a copy nobody in particular keeps: it is idle at once.
    internal func localCopy(
        for url: URL,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    ) -> Result<URL, Refusal> {
        localCopy(for: url, fileSystems: fileSystems, owner: ObjectIdentifier(Self.self), cancellation: cancellation)
    }

    /// `localURL`, with the reason when there is none.
    internal func localCopy(
        for url: URL,
        fileSystems: FileSystemRegistry,
        owner: ObjectIdentifier,
        cancellation: CancellationFlag
    ) -> Result<URL, Refusal> {
        if url.isFileURL {
            return .success(url)
        }
        guard let provider = try? fileSystems.provider(for: url) else {
            return .failure(.unreadable)
        }
        let item = provider.item(at: url, cancellation: cancellation)
        let key = "\(url.locationKey)|\(item?.size ?? -1)|\(item?.modified.timeIntervalSince1970 ?? 0)"
        if let known = use(key, by: owner) {
            return .success(known)
        }
        if cancellation.isCancelled {
            return .failure(.cancelled)
        }
        // A file of a server is not put on the disk without asking whether it fits.
        if let size = item?.size, size > disk.sizeLimit {
            return .failure(.tooLarge(size, limit: disk.sizeLimit))
        }
        let request = Request(
            url: url,
            provider: provider,
            fileSystems: fileSystems,
            key: key,
            size: item?.size,
            owner: owner,
            cancellation: cancellation
        )
        return copy(request)
    }

    /// The pane `owner` shows something else: its copies are kept only while the idle ones are
    /// few enough.
    internal func release(owner: ObjectIdentifier) {
        lock.lock()
        ledger.release(owner: owner)
        lock.unlock()
        evict()
    }

    /// Returns once the copies that were let go of have been deleted (for tests).
    internal func waitForCleanup() {
        group.wait()
    }

    /// Deletes every copy and the folder that held them, waiting a moment for it at most (the program is about to
    /// end when the plugin stops).
    internal func removeAll() {
        removeAll(waiting: true, then: nil)
    }

    /// Deletes every copy and the folder that held them: in the background, but `removeAll` waits
    /// a moment for it (the program is about to end when the plugin stops) and never longer.
    ///
    /// With `waiting` off it does not wait at all; `done` is called, on whatever thread, once the
    /// deletion has been carried out (at once when there was nothing to delete).
    internal func removeAll(waiting: Bool, then done: (@Sendable () -> Void)?) {
        lock.lock()
        let folder = root
        root = nil
        ledger.removeAll()
        lock.unlock()
        guard let folder else {
            done?()
            return
        }
        group.enter()
        ViewerCleanup.async { [group] in
            try? FileManager.default.removeItem(at: folder)
            group.leave()
            done?()
        }
        if waiting { _ = group.wait(timeout: .now() + 2) }
    }

    /// Reads the file of `request` into a folder of its own and registers the copy.
    private func copy(_ request: Request) -> Result<URL, Refusal> {
        let cancellation = request.cancellation
        let started = start(for: request.owner)
        // Changes that a plugin still holds back for this file (an archive written after a delay) are written first.
        do { try request.fileSystems.flushPendingWrites(to: request.url, cancellation: cancellation) } catch {
            return .failure(cancellation.isCancelled ? .cancelled : .unreadable)
        }
        guard let reader = try? request.provider.read(request.url, cancellation: cancellation) else {
            return .failure(cancellation.isCancelled ? .cancelled : .unreadable)
        }
        defer { reader.close() }
        guard let folder = newFolder() else {
            return .failure(.unreadable)
        }
        if let size = request.size, let free = disk.freeSpace(directory), free - size < Self.freeSpaceMargin {
            try? FileManager.default.removeItem(at: folder)
            return .failure(.noRoom)
        }
        // The name is one component (`safeName`) of the folder just made, and the file is new.
        let target = folder.appendingPathComponent(Self.safeName(request.url.lastPathComponent), isDirectory: false)
        let written: Int64
        switch disk.write(reader, to: target, cancellation: cancellation) {
        case .success(let count):
            written = count

        case .failure(let refusal):
            try? FileManager.default.removeItem(at: folder)
            return .failure(refusal)
        }
        // A file that came from a server keeps saying so; the copy is a plain local file, so the mark
        // can go on it (a mark that cannot be put on does not stop the viewing).
        if let mark = request.provider.quarantine(of: request.url),
            let local = try? request.fileSystems.provider(for: target)
        {
            try? local.setQuarantine(mark, of: target)
        }
        return register(request, folder: folder, file: target, size: written, started: started)
    }

    /// Keeps the copy of `request` in `folder` for its owner, unless `removeAll` ran or another thread
    /// made the same copy meanwhile.
    private func register(
        _ request: Request,
        folder: URL,
        file target: URL,
        size written: Int64,
        started: CopyLedger.Start
    ) -> Result<URL, Refusal> {
        lock.lock()
        // `removeAll` ran while the file was copied: the folder it made is gone, and so is this.
        guard !ledger.wasCleared(since: started) else {
            lock.unlock()
            try? FileManager.default.removeItem(at: folder)
            return .failure(.cancelled)
        }
        // Another thread may have copied the same file meanwhile: its copy stays.
        if let file = ledger.use(request.key, by: request.owner) {
            lock.unlock()
            try? FileManager.default.removeItem(at: folder)
            return .success(file)
        }
        let copy = CopyLedger.Copy(folder: folder, file: target, owners: [], lastUsed: 0, size: written)
        ledger.add(copy, key: request.key, owner: request.owner, start: started)
        lock.unlock()
        evict()
        return .success(target)
    }

    private func start(for owner: ObjectIdentifier) -> CopyLedger.Start {
        lock.lock()
        defer { lock.unlock() }
        return ledger.start(for: owner)
    }

    private func use(_ key: String, by owner: ObjectIdentifier) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return ledger.use(key, by: owner)
    }

    /// Deletes the idle copies beyond the limits, the least recently used first.
    ///
    /// The files are deleted on a background queue: this is called on the main thread.
    private func evict() {
        lock.lock()
        let doomed = ledger.evictIdle(keeping: Self.idleLimit, bytes: Self.idleByteLimit)
        lock.unlock()
        guard !doomed.isEmpty else {
            return
        }
        group.enter()
        ViewerCleanup.async { [group, doomed] in
            for folder in doomed { try? FileManager.default.removeItem(at: folder) }
            group.leave()
        }
    }

    /// A new, empty folder of its own for one copy.
    private func newFolder() -> URL? {
        // The disk is asked outside the lock, which the main thread takes as well; the threads
        // that make copies take turns, so one of them makes the folder of all copies.
        rootLock.lock()
        defer { rootLock.unlock() }
        lock.lock()
        let existing = root
        lock.unlock()
        let base: URL
        if let existing {
            base = existing
        } else {
            base = directory.appendingPathComponent(
                "\(Self.prefix)p\(getpid())-\(UUID().uuidString)",
                isDirectory: true
            )
            guard
                (try? FileManager.default.createDirectory(
                    at: base,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )) != nil
            else { return nil }
            lock.lock()
            root = base
            lock.unlock()
        }
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return
            (try? FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )) != nil
            ? folder : nil
    }

    deinit { removeAll() }
}
