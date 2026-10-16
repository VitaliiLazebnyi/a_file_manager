import AFMKernel
import Foundation

/// The options of the Packer page as the working threads see them. The settings store belongs
/// to the main thread; this copy is refreshed there and read anywhere.
struct ArchiveOptions {
    var compressionLevel = 6
    var opensAsFolders = true
    var entersAnyFile = true
    var extensions: Set<String> = []
    var verifiesAfterPacking = true
    var datesArchiveByNewest = false
}

/// What archives need from their surroundings. One object is shared by everything the plugin
/// owns; its closures are set while the plugin starts, and may be called from any thread.
/// The settings are read and written as properties of the environment (`environment.flushDelay`).
///
/// Unchecked: the settings, `options` and `isStopping` are guarded by `lock` (tests change
/// settings while archives are open); the rest is fixed in `init`.
@dynamicMemberLookup
final class ArchiveEnvironment: @unchecked Sendable {
    let scratch = ScratchFolder()
    /// Set when quitting has waited long enough: ends the writes that are still under way.
    let quitting = CancellationFlag()
    private let lock = NSLock()
    private var settings = Settings()
    private var current = ArchiveOptions()
    private var stopping = false

    subscript<Value>(dynamicMember keyPath: WritableKeyPath<Settings, Value>) -> Value {
        get { lock.withLock { settings[keyPath: keyPath] } }
        set { lock.withLock { settings[keyPath: keyPath] = newValue } }
    }

    typealias Scheduler =
        @Sendable (_ delay: TimeInterval, _ priority: QualityOfService, _ work: @escaping @Sendable () -> Void) -> Void

    /// The same clock as the delayed writes' (see `Settings.schedule`) for the plugin's
    /// housekeeping (closing readers nobody came back for), which is not the delayed writes'
    /// business and not a test clock's either.
    static func later(
        _ delay: TimeInterval,
        _ priority: QualityOfService,
        name: String,
        _ work: @escaping @Sendable () -> Void
    ) {
        clock.asyncAfter(deadline: .now() + delay) {
            let thread = Thread(block: work)
            thread.qualityOfService = priority
            thread.name = name
            thread.start()
        }
    }
    private static let clock = DispatchQueue(label: "afm.archives.clock", qos: .userInitiated)

    struct Settings {
        /// The file systems of the program, for archives that lie on something other than the disk.
        var fileSystems: @Sendable () -> FileSystemRegistry? = { nil }
        /// Asks for the password of an archive; `retry` after a wrong one. Nil gives up.
        var askPassword: @Sendable (_ archiveName: String, _ retry: Bool) -> String? = { _, _ in nil }
        /// Tells the user that changes could not be written into an archive. Must not wait for
        /// the user: it is called on the thread that writes.
        var reportFailure: @Sendable (_ error: any Error, _ archiveName: String) -> Void = { _, _ in }
        /// The directories whose contents changed behind the panels' backs.
        var contentsChanged: @Sendable (_ archive: URL) -> Void = { _ in }

        /// Archives up to this size that cannot be read at any position (compressed TAR, 7z, …)
        /// are unpacked once into a temporary TAR, so that reading single members is fast.
        var materializeLimit: UInt64 = 256 << 20
        /// The temporary copy may not grow beyond this.
        var unpackedLimit: UInt64 = 4 << 30
        /// This much stays free on the volume of the temporary folder, whatever is unpacked or
        /// fetched into it: a copy that would eat into it is not made (or given up half-way).
        var scratchReserve: UInt64 = 2 << 30
        /// The temporary copies of the archives that are open but not in use may take this much
        /// together; beyond it the least recently used are let go.
        var scratchBudget: UInt64 = 8 << 30
        /// An archive may hold this many entries; one that lists more is refused with a clear
        /// message instead of filling the memory. An entry of a ZIP costs about 400 bytes
        /// (measured: 396 with a 45-byte path and the extra fields the `zip` program writes), so
        /// the directory of the largest archive that is opened takes about 800 MB.
        var maxEntries = 2_000_000
        /// Archives may lie inside archives this deep.
        var maxNesting = 6
        /// How long after the last change pending changes are written into a ZIP; nil never
        /// writes by itself.
        var flushDelay: TimeInterval? = 1
        /// How long after a failed write the next attempt is made; doubled with every further
        /// failure, up to `maxRetryDelay`. A change to the archive brings the next attempt at once.
        var retryDelay: TimeInterval = 30
        var maxRetryDelay: TimeInterval = 3_600
        /// The delayed write runs with low priority. When all cores are busy that may not run for
        /// minutes; this long after it was due it runs with the priority of the user's own work.
        var escalationDelay: TimeInterval = 5
        /// Runs `work` after `delay` on a thread of its own with the given priority. The delayed
        /// writes are started this way and not on the system's shared queues: those have a
        /// limited number of threads, and when all of them are busy (or blocked) a write that is
        /// due would wait behind them for as long as that lasts. The clock itself is a queue of
        /// the plugin's own, on which nothing ever runs but the starting of these threads.
        /// (Tests put a clock of their own here.)
        var schedule: Scheduler = { delay, priority, work in
            ArchiveEnvironment.later(delay, priority, name: "Archive write", work)
        }
        /// How long a reader of an archive that can only be read front to back waits behind
        /// the member it delivered for someone to read on; then it is closed.
        var readerParkTime: TimeInterval = 10
        /// Runs the housekeeping (closing the readers nobody came back for) as `schedule` runs
        /// the delayed writes. (Tests put a clock of their own here.)
        var housekeeping: Scheduler = { delay, priority, work in
            ArchiveEnvironment.later(delay, priority, name: "Archive readers", work)
        }
        /// A file that a job has just given its final name inside a ZIP is written into the
        /// archive file before the rename returns, when that means writing no more than this
        /// many bytes besides the file itself (or no more than is waiting anyway). Zero leaves
        /// every write to the delay.
        var immediateWriteLimit: UInt64 = 256 << 10
        /// Off, archives are never cloned and every change writes the whole archive anew, as on
        /// a file system that cannot clone (tests).
        var clonesArchives = true
        /// Whether `needed` bytes can be written into `folder`.
        var hasRoom: @Sendable (_ needed: UInt64, _ folder: URL) -> Bool = { Volume.hasRoom(for: $0, at: $1) }
        /// The volume a path lies on, as a number (tests: an archive "on another disk").
        var volume: @Sendable (_ path: String) -> dev_t? = { Volume.device(of: $0) }
        /// Where new members are saved when they can be written neither into their archive nor
        /// next to it; nil keeps them in the temporary folder.
        var recoveryFolder: URL?
        /// After the user declined to give a password (or gave three wrong ones), members of that
        /// archive fail without a question for this long: a job that reads a thousand encrypted
        /// members asks once, not a thousand times.
        var passwordRefusalMemory: TimeInterval = 0
        /// How long quitting waits for the changes to be written before it gives up, keeps the
        /// new members in the temporary folder and says so.
        var quitTimeout: TimeInterval = 120
        var limits = ZipLimits.standard
        /// Called by a write when the new archive file is complete and before it takes the old
        /// one's place, on the writing thread (tests: what changes while a write is under way).
        var whileWriting: (@Sendable () -> Void)?
    }

    var options: ArchiveOptions {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }

    /// True from the moment the plugin stops: the delayed writes start nothing more, because
    /// the stop writes everything itself and then removes the temporary files.
    var isStopping: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }
        set {
            lock.lock()
            stopping = newValue
            lock.unlock()
        }
    }
}

enum Volume {
    static func hasRoom(for needed: UInt64, at folder: URL) -> Bool {
        var info = statfs()
        guard statfs(folder.path, &info) == 0 else { return true }
        if UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize)).partialValue >= needed {
            return true
        }
        // The system can make more room than it counts as free; it is asked before a write is refused.
        if let more = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage,
            more > 0
        {
            return UInt64(more) >= needed
        }
        return false
    }

    /// The volume a path lies on, as a number; nil when the path cannot be asked.
    static func device(of path: String) -> dev_t? {
        var status = stat()
        return stat(path, &status) == 0 ? status.st_dev : nil
    }

    // MARK: Asking only disks that answer

    private static let mountLock = NSLock()
    /// Guarded by `mountLock`.
    nonisolated(unsafe) private static var mounts: (read: DispatchTime, points: [(path: [UInt8], isLocal: Bool)])?

    /// The mounted volumes as the system has them in memory (`MNT_NOWAIT`): no volume is asked.
    private static func mountPoints() -> [(path: [UInt8], isLocal: Bool)] {
        mountLock.lock()
        defer { mountLock.unlock() }
        if let mounts, DispatchTime.now().uptimeNanoseconds - mounts.read.uptimeNanoseconds < 1_000_000_000 {
            return mounts.points
        }
        var points: [(path: [UInt8], isLocal: Bool)] = []
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        if count > 0 {
            let empty = statfs()
            var buffer = Array(repeating: empty, count: Int(count) + 8)
            let filled = getfsstat(&buffer, Int32(MemoryLayout<statfs>.stride * buffer.count), MNT_NOWAIT)
            for var info in buffer.prefix(max(0, Int(filled))) {
                let path = withUnsafeBytes(of: &info.f_mntonname) { Array($0.prefix { $0 != 0 }) }
                let isLocal = info.f_flags & UInt32(MNT_LOCAL) != 0 && info.f_flags & UInt32(MNT_AUTOMOUNTED) == 0
                points.append((path, isLocal))
            }
        }
        mounts = (.now(), points)
        return points
    }

    /// True when every volume the path runs through is a disk of this machine, by the table
    /// of mounts alone. Asking such a path about itself does not hang on a server that is gone.
    static func isOnLocalVolume(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.first == 0x2F else { return false }
        var found = false
        for point in mountPoints() {
            let isPrefix =
                point.path == [0x2F]
                || (bytes.starts(with: point.path)
                    && (bytes.count == point.path.count || bytes[point.path.count] == 0x2F))
            guard isPrefix else { continue }
            guard point.isLocal else { return false }
            found = true
        }
        return found
    }

    enum PathKind {
        case regularFile, directory, other, missing
        /// On a volume that may not answer (a server): it was not asked.
        case unasked
    }

    /// What lies at an absolute path, found without ever asking a volume that is not a disk
    /// of this machine: the path is walked name by name, links are followed by hand, and the
    /// walk stops with `.unasked` where it would leave the local disks. Fast, and safe on the
    /// main thread.
    static func kind(ofLocalPath path: String) -> PathKind {
        var current = path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        for _ in 0..<16 {
            guard isOnLocalVolume(current) else { return .unasked }
            let names = ArchiveTree.names(of: current)
            var prefix = ""
            var redirected = false
            for (index, name) in names.enumerated() {
                prefix += "/" + name
                var status = stat()
                guard lstat(prefix, &status) == 0 else { return .missing }
                let type = status.st_mode & S_IFMT
                // (A link that cannot be read is taken for what it is: not a folder.)
                if type == S_IFLNK, case let length = readlink(prefix, &buffer, buffer.count), length > 0 {
                    let target = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    let base =
                        target.hasPrefix("/") ? target : (prefix as NSString).deletingLastPathComponent + "/" + target
                    let rest = names[(index + 1)...].joined(separator: "/")
                    current =
                        URL(fileURLWithPath: rest.isEmpty ? base : base + "/" + rest, isDirectory: false).standardized
                        .path
                    redirected = true
                    break
                }
                if index == names.count - 1 {
                    return type == S_IFREG ? .regularFile : type == S_IFDIR ? .directory : .other
                }
                guard type == S_IFDIR else { return .missing }
            }
            if !redirected { return .directory }
        }
        return .missing
    }
}

/// What identifies the state of a file on disk: when any of it changes, the file was rewritten.
struct FileSignature: Equatable {
    let size: Int64
    let seconds: Int
    let nanoseconds: Int
    let inode: UInt64

    init(_ status: stat) {
        size = Int64(status.st_size)
        seconds = status.st_mtimespec.tv_sec
        nanoseconds = status.st_mtimespec.tv_nsec
        inode = UInt64(status.st_ino)
    }

    static func of(_ path: String) -> Self? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Self(status)
    }

    var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }
}

/// The lock that lets one write of an archive run at a time. A write may take minutes and
/// runs with low priority when the delay started it; a thread of the user's own work that has
/// to wait for it (a commit, a quit) lends it its priority for as long as it waits, so the
/// wait is not longer than the write itself needs.
///
/// A long write (anything but the small write of a rename, see `OpenArchive.move`) says so
/// when it takes the gate, in the same step: a rename sees it at once and does not wait
/// behind it, neither when it comes while such a write runs nor when one takes the gate
/// while the rename waits for another rename.
///
/// Unchecked: `holder` and `holdsLong` are guarded by `condition`.
internal final class FlushGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var holder: pthread_t?
    private var holdsLong = false

    private static func end(_ lent: pthread_override_t?) {
        if let lent {
            pthread_override_qos_class_end_np(lent)
        }
    }

    /// Waits for the gate; `long` for anything but the small write of a rename. With a
    /// `cancellation`, no longer than until it is set.
    internal func lock(long: Bool, cancellation: CancellationFlag?) throws {
        condition.lock()
        defer { condition.unlock() }
        let lent = lend()
        defer { Self.end(lent) }
        while holder != nil {
            if let cancellation {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                if holder != nil, cancellation.isCancelled {
                    throw ArchiveError.cancelled
                }
            } else {
                condition.wait()
            }
        }
        take(long: long)
    }

    /// Waits no longer than until `deadline`; `long` as for `lock(long:cancellation:)`.
    internal func lock(long: Bool, before deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let lent = lend()
        defer { Self.end(lent) }
        while holder != nil {
            if !condition.wait(until: deadline), holder != nil {
                return false
            }
        }
        take(long: long)
        return true
    }

    /// Waits for the gate while a short write holds it; false, without the gate, as soon as a
    /// long write holds it.
    internal func lockUnlessLong() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let lent = lend()
        defer { Self.end(lent) }
        while holder != nil {
            guard !holdsLong else {
                return false
            }
            condition.wait()
        }
        take(long: false)
        return true
    }

    /// Lets the next waiter take the gate.
    internal func unlock() {
        condition.lock()
        holder = nil
        holdsLong = false
        condition.broadcast()
        condition.unlock()
    }

    /// Takes the free gate. Called with `condition` held.
    private func take(long: Bool) {
        holder = pthread_self()
        holdsLong = long
    }

    /// The thread that holds the gate runs at this thread's priority until the returned mark
    /// is ended. Nil when there is nothing to lend. Called with `condition` held.
    private func lend() -> pthread_override_t? {
        let mine = qos_class_self()
        guard let holder, mine.rawValue > QOS_CLASS_UTILITY.rawValue else {
            return nil
        }
        // The holder cannot end before it has taken `condition` to step back, so it is alive here.
        return pthread_override_qos_class_start_np(holder, mine, 0)
    }

    deinit {
        // Nothing to release.
    }
}

/// What became of changes that could not be written into their archive.
enum RescueOutcome {
    /// Nothing was waiting that exists nowhere else (renames, deletions).
    case nothingToSave
    /// The new members were written into this archive of their own.
    case saved(URL)
    /// They could not be written anywhere; their compressed data stays in this folder, with a
    /// list (`index.txt`) of which file is which member.
    case kept(URL)
}

/// An archive that has been opened: its directory, parsed once and kept in memory, and the
/// means to read its members; for ZIP also the changes waiting to be written.
///
/// **Threading.** Every method may be called from any thread. The directory is guarded by a
/// lock that is held only for look-ups and changes in memory, never while a member's data is
/// read or the archive is written: streams work on the file itself (`pread`) and need no
/// lock. Writing the changes (`flush()`) has a gate of its own, so one write runs at a time;
/// it copies what it needs under the directory's lock, builds the new file without it, and
/// takes it again only to put the new file in place. `capabilities`, which the main thread
/// asks many times a second, takes neither: it reads a value that is published under a lock
/// of its own that nothing is ever done under. Nothing here is to be called on the main
/// thread except `capabilities`.
///
/// **Changing a ZIP.** Changes are made to the directory in memory at once; new members wait,
/// already compressed, in temporary files. `flush()` writes them into the archive:
///
/// - Added, renamed and re-dated members are appended. The archive is cloned (a copy that
///   shares its data with the original, which the file system makes at once and without
///   using space), the clone's directory is cut off, the new members and a new directory are
///   written behind the old members, and the clone takes the archive's place in one step.
///   Only the new data and the directory are written, however large the archive is.
/// - When members were deleted, when the file system cannot clone, or when renames would
///   leave too much unused space behind, a whole new archive is written next to the old one
///   (unchanged members are copied as they are, without recompressing) and takes its place.
///
/// Either way the archive file is at every moment the complete old or the complete new one:
/// the new file is on the disk (`F_BARRIERFSYNC`) before it takes the old one's place.
/// A write that fails changes nothing, here or on disk: the changes keep waiting, the user is
/// told, and the write is tried again. Changes are written shortly after the last one, when a
/// job puts a new file under its final name (see `ArchiveEnvironment.immediateWriteLimit`),
/// before the archive is packed into, unpacked or tested, when the program quits, and when
/// a caller that is about to delete the only other copy of what it wrote asks for a
/// `commit`, which writes at once, on its own thread, and fails if the write does.
///
/// A member that a job is still bringing in lies under the job's temporary name
/// (`.afm-<UUID>.tmp`) until the job renames it. Such a member is never written into the
/// archive file: it joins the file with its real name, or not at all.
///
/// **Being let go.** The store lets an archive go when it is not in use, or when its file was
/// changed by someone else. That happens through `retireIfIdle()`, under the directory's
/// lock: an archive with changes waiting or a member being written is never retired, and a
/// retired one takes no change any more (`ArchiveError.retired`; the file system then asks
/// the store again and gets the archive that took its place). So no change can land in an
/// archive that nobody will write.
///
/// Unchecked: what changes is guarded by `lock` (the passwords too: `passwordGate` only lets
/// one question run at a time), except `publishedEditable` (`stateLock`); `file` and
/// `signature` are replaced only by the holder of the gate, under `lock`. The rest is fixed
/// in `init`, or touched in `init` and `deinit` only.
final class OpenArchive: @unchecked Sendable {
    /// The archive file as its own file system names it.
    let archiveURL: URL
    let name: String
    /// The mark the system puts on files from the internet, when the archive carries it:
    /// what is unpacked from the archive gets it too.
    let quarantine: Data?
    private let environment: ArchiveEnvironment
    /// The archive on the local disk: the file itself (where it really lies, when it was
    /// reached through a symbolic link), or a copy fetched from elsewhere.
    private let localURL: URL
    private let fetchedCopy: TemporaryFile?
    private let lock = NSLock()
    /// Held while the archive file is written or sent; taken before `lock`, never inside it.
    private let gate = FlushGate()
    /// Guards only `publishedEditable`. Nothing is done while it is held.
    private let stateLock = NSLock()
    private var publishedEditable = false
    /// Names this instance's temporary files next to the archive.
    private let instance = UUID().uuidString

    private var file: RandomAccessFile
    let format: ArchiveFormat
    private var tree = ArchiveTree()
    /// A stream archive unpacked into a temporary TAR (or a compressed file into its content).
    private var unpacked: (file: RandomAccessFile, temporary: TemporaryFile)?
    /// Starts reading the archive as a TAR stream, for formats without random access.
    private var memberSource: ((StreamInterrupt?) throws -> any ByteStream)?
    /// Readers of such a stream that stand behind a member and can go on from there.
    private var parked: [(reader: TarReader, next: Int, since: DispatchTime)] = []
    private var reaperArmed = false
    private var starts = 0
    private var signature: FileSignature
    private var remoteStamp: (size: Int64, modified: Date)?
    private var lastRemoteCheck = Date.distantPast
    private var comment = Data()

    // Passwords.
    /// The passwords that opened a member, the latest first.
    private var passwords: [String] = []
    /// One question at a time, however many threads read encrypted members.
    private let passwordGate = NSLock()
    private var passwordScopes = 0
    private var refusedInScope = false
    private var refusedUntil = Date.distantPast

    // The ZIP file as it lies on the disk.
    /// Where its directory starts: the members lie in front of it.
    private var directoryOffset: UInt64 = 0
    /// Where the first member starts; what stands before it (the program of a self-extracting
    /// archive) is kept.
    private var prefixEnd: UInt64 = 0
    /// Entries without a usable name. They are not shown, and they stay in the archive.
    private var unlisted: [ZipRecord] = []
    /// An archive that lists a name twice shows one of the two; it is not changed.
    private var hasDuplicates = false

    // Changes waiting to be written.
    private var changeCount = 0
    private var writtenCount = 0
    /// Counted up when something was removed that lies in the archive file: then the file is
    /// written anew, without it.
    private var removals = 0
    private var writtenRemovals = 0
    /// The compressed bytes of the members that are not in the archive file yet.
    private var pendingBytes: UInt64 = 0
    /// Members that lie here under a job's temporary name, on their way to their real one.
    private var transfers = 0
    /// (An archive fetched from elsewhere.) The local copy is ahead of the original.
    private var uploadPending = false
    private var openWriters = 0
    /// Set when the store let this archive go; see the class comment.
    private var retired = false
    /// Counted up whenever the directory was read anew from the file (`rebase`).
    private var loadCount = 0
    /// What writes at a rename have cost since the delay (or a commit) last wrote, and the
    /// bytes that came in meanwhile: see `move`.
    private var immediateSpent: UInt64 = 0
    private var arrivedBytes: UInt64 = 0
    private var lastChange = DispatchTime.now()
    /// When the armed timer is due; nil when none is armed. A timer that was overtaken by an
    /// earlier one knows it by its number.
    private var timerDeadline: DispatchTime?
    private var timerNumber = 0
    private var notifyPending = false
    /// Whether the file system clones files; nil until it was tried.
    private var canClone: Bool?
    private var cloneProbed = false
    private var lastRewriteDuration: TimeInterval = 0
    private var reportedFailure: String?
    /// How many writes have failed in a row.
    private var failures = 0
    /// Where new members wait: nil until one was written. See `newSpool()`.
    private var spoolFolder: URL?
    private var spoolIsOutside = false
    private var notedBuildFile = false

    /// With a `cancellation`, opening ends with `ArchiveError.cancelled` soon after it is set:
    /// the child processes started for it are stopped and its temporary files are removed.
    init(
        archiveURL: URL,
        localURL: URL,
        fetchedCopy: TemporaryFile?,
        remoteStamp: (size: Int64, modified: Date)?,
        quarantine: Data? = nil,
        cancellation: CancellationFlag? = nil,
        environment: ArchiveEnvironment
    ) throws {
        self.archiveURL = archiveURL
        self.localURL = localURL
        self.fetchedCopy = fetchedCopy
        self.remoteStamp = remoteStamp
        self.environment = environment
        self.quarantine = quarantine ?? (fetchedCopy == nil ? Quarantine.read(localURL.path) : nil)
        name = archiveURL.lastPathComponent
        let file = try RandomAccessFile(localURL)
        self.file = file
        // Of the file that was opened, not of whatever lies at the path a moment later.
        signature = file.signature
        // A first guess at what copying the archive costs, until one was timed.
        lastRewriteDuration = Double(file.size) / 500_000_000
        let head = try file.read(at: 0, count: 512)
        format = ArchiveFormat.detect(head: head, name: name) { codec in
            // A stream that cannot be started or read holds no TAR that could be listed.
            let first = try? { () throws -> Data in
                let stream = try codec.decompressing(file)
                defer { stream.close() }
                return try stream.readFully(TarHeader.blockSize)
            }()
            return TarHeader.looksLikeHeader(first ?? Data())
        }
        let control = StreamInterrupt()
        let following = control.following(cancellation)
        defer { withExtendedLifetime(following) {} }
        try load(control: control)
        try control.check()
        publish()
    }

    deinit {
        for waiting in parked { waiting.reader.close() }
        // The members that waited here go with the directory; then their folder is empty.
        tree = ArchiveTree()
        if spoolIsOutside, let spoolFolder { rmdir(spoolFolder.path) }
    }

    // MARK: Reading the directory

    /// Called while nobody else can see the archive (opening).
    private func load(control: StreamInterrupt? = nil) throws {
        tree = ArchiveTree()
        unpacked = nil
        memberSource = nil
        (unlisted, hasDuplicates) = ([], false)
        (writtenCount, writtenRemovals, pendingBytes, transfers) = (changeCount, removals, 0, 0)
        let file = self.file
        switch format {
        case .zip:
            let read = try Self.readZip(file, environment: environment, control: control)
            (tree, unlisted, hasDuplicates) = (read.tree, read.unlisted, read.hasDuplicates)
            (comment, directoryOffset, prefixEnd) = (read.comment, read.directoryOffset, read.prefixEnd)

        case .tar:
            try indexTar(FileRangeStream(file), toTheEnd: false, control: control) { true }

        case .compressedTar(let codec):
            try loadStream(control: control) { try codec.decompressing(file, control: $0) }

        case .foreign:
            let name = self.name
            switch ForeignArchive.kind(of: file) {
            case .libarchive:
                do {
                    // bsdtar reads what libarchive knows and writes it out again as plain TAR:
                    // one parser for every foreign format, and no tool output to interpret.
                    // It is only ever given a file that `ForeignArchive` knows by its first
                    // bytes: left to itself it takes a text file for a list of files to read
                    // from this disk ("mtree").
                    try loadStream(control: control) {
                        guard file.isStillAtItsPath else { throw ArchiveError.changedOutside(name) }
                        return try ProcessStream(
                            Tool.bsdtar,
                            ["-cf", "-", "--format", "pax", "@" + file.path],
                            control: $0
                        )
                    }
                } catch ArchiveError.toolFailed(let message) where Self.meansNoArchive(message) {
                    throw ArchiveError.notAnArchive(name)
                }

            case .compressedTar:
                // The old `compress` format, which gzip unpacks; what comes out is read here.
                let source: (StreamInterrupt?) throws -> any ByteStream = {
                    guard file.isStillAtItsPath else { throw ArchiveError.changedOutside(name) }
                    return try ProcessStream(Tool.gzip, ["-dc", "--", file.path], control: $0)
                }
                let probe = try source(control)
                let first = (try? probe.readFully(TarHeader.blockSize)) ?? Data()
                probe.close()
                guard TarHeader.looksLikeHeader(first) else { throw ArchiveError.notAnArchive(name) }
                try loadStream(control: control, source)

            case nil:
                throw ArchiveError.notAnArchive(name)
            }

        case .compressedFile(let codec):
            try loadCompressedFile(codec, control: control)
        }
    }

    /// The directory of a ZIP file as the archive keeps it.
    private struct ZipListing {
        var tree = ArchiveTree()
        var unlisted: [ZipRecord] = []
        var hasDuplicates = false
        var comment = Data()
        var directoryOffset: UInt64 = 0
        var prefixEnd: UInt64 = 0
    }

    /// Reads the directory of a ZIP file. Touches nothing of an archive: whoever calls it
    /// needs no lock for it.
    private static func readZip(_ file: RandomAccessFile, environment: ArchiveEnvironment, control: StreamInterrupt?)
        throws -> ZipListing
    {
        var listing = ZipListing()
        // The records go into the tree as they are read: no second list of them is held.
        var firstMember = UInt64.max
        var index = 0
        let contents = try ZipDirectory.scan(
            file,
            maxEntries: environment.maxEntries,
            check: { try control?.check() },
            expecting: { listing.tree.reserve($0) }
        ) { record in
            defer { index += 1 }
            if index & 0x1FFF == 0x1FFF { try control?.check() }
            if case .archive(let offset, _) = record.source { firstMember = min(firstMember, offset) }
            var raw = record.name
            // Archives from DOS and Windows programs sometimes separate with backslashes.
            if record.versionMadeBy >> 8 != 3, !raw.contains("/") {
                raw = raw.replacingOccurrences(of: "\\", with: "/")
            }
            guard let path = ArchiveTree.normalized(raw) else {
                listing.unlisted.append(record)
                return
            }
            if let existing = listing.tree.entry(path), !existing.isImplicit { listing.hasDuplicates = true }
            listing.tree.insert(Self.entry(path: path, for: record))
            try Self.checkSize(of: listing.tree, environment: environment)
        }
        listing.comment = contents.comment
        listing.directoryOffset = contents.directoryOffset
        listing.prefixEnd = min(contents.directoryOffset, firstMember)
        return listing
    }

    /// An archive whose directory would not fit the memory is refused while it is read.
    private func checkTreeSize() throws {
        try Self.checkSize(of: tree, environment: environment)
    }

    private static func checkSize(of tree: ArchiveTree, environment: ArchiveEnvironment) throws {
        guard tree.count <= environment.maxEntries else {
            throw ArchiveError.unsupported("An archive with more than \(environment.maxEntries) entries")
        }
        guard tree.implicitBytes <= ArchiveTree.maxImplicitBytes else {
            throw ArchiveError.unsupported("An archive with this many folders inside folders")
        }
    }

    /// What bsdtar says about a file it cannot make sense of.
    private static func meansNoArchive(_ message: String) -> Bool {
        message.isEmpty || message.contains("Unrecognized archive format") || message.contains("mtree")
    }

    private static func entry(path: String, for record: ZipRecord) -> ArchiveEntry {
        ArchiveEntry(
            path: path,
            isDirectory: record.isDirectory,
            isSymbolicLink: record.isSymbolicLink,
            isSpecial: record.isSpecial,
            size: Int64(clamping: record.uncompressedSize),
            packedSize: Int64(clamping: record.compressedSize),
            modified: record.modified,
            permissions: record.permissions,
            isEncrypted: record.isEncrypted,
            content: .zip(record)
        )
    }

    /// Reads the headers of a TAR stream. Of every file both its position in the stream and
    /// its number are noted; `seekable`, asked at the end, says which of the two will serve:
    /// positions when the stream is (or has become) a file, numbers otherwise.
    /// With `toTheEnd` the stream is read on behind the last member: a decompressor checks
    /// its data only then, and a child process says only then that it failed.
    private func indexTar(
        _ stream: any ByteStream,
        toTheEnd: Bool = true,
        control: StreamInterrupt? = nil,
        seekable: () -> Bool
    ) throws {
        let reader = TarReader(stream, control: control)
        defer { reader.close() }
        var located: [String: (offset: UInt64, length: UInt64, index: Int)] = [:]
        // Hard links by their own path: a later member under the same path takes the name over.
        var links: [String: String] = [:]
        var index = 0
        while let header = try reader.next() {
            defer { index += 1 }
            guard header.kind != .other, let path = ArchiveTree.normalized(header.path) else { continue }
            let shown = header.realSize ?? header.size
            var entry = ArchiveEntry(
                path: path,
                isDirectory: header.kind == .directory,
                isSymbolicLink: header.kind == .symbolicLink,
                size: Int64(clamping: shown),
                packedSize: Int64(clamping: header.size),
                modified: header.modified,
                permissions: header.permissions
            )
            located[path] = nil
            links[path] = nil
            switch header.kind {
            case .file where header.isSparse:
                entry.content = .unsupported(
                    "Unpacking the sparse file \(path) (a file stored without its empty stretches)"
                )

            case .file:
                located[path] = (reader.position, header.size, index)

            case .symbolicLink:
                entry.content = .text(header.linkTarget)
                entry.size = Int64(header.linkTarget.utf8.count)

            case .hardLink:
                // Another name for a member, which may come before or after: settled below.
                if let target = ArchiveTree.normalized(header.linkTarget) { links[path] = target }

            case .directory, .other:
                break
            }
            tree.insert(entry)
            try checkTreeSize()
        }
        if toTheEnd {
            while try stream.read(upToCount: 1 << 16) != nil { try control?.check() }
        }
        let ranged = seekable()
        for (path, place) in located {
            tree.update(path) {
                $0.content = ranged ? .range(offset: place.offset, length: place.length) : .member(index: place.index)
            }
        }
        // A link may point to a link; a few rounds settle every chain worth following.
        for _ in 0..<4 where !links.isEmpty {
            var left: [String: String] = [:]
            for (path, linked) in links {
                guard let target = tree.entry(linked), !target.isDirectory, links[linked] == nil else {
                    left[path] = linked
                    continue
                }
                tree.update(path) { ($0.content, $0.size, $0.packedSize) = (target.content, target.size, 0) }
            }
            if left.count == links.count { break }
            links = left
        }
    }

    /// Watches the room in the temporary folder for a copy that is about to be made there;
    /// nil when there is not even room to begin.
    private func scratchWatch(for size: UInt64) -> SpaceWatch? {
        let folder = environment.scratch.url
        guard environment.hasRoom(environment.scratchReserve.plusClamped(size), folder) else { return nil }
        return SpaceWatch(folder: folder, reserve: environment.scratchReserve, hasRoom: environment.hasRoom)
    }

    /// An archive that can only be read front to back. It is read once: the members are
    /// listed from the stream while the stream is copied into a temporary TAR, which then
    /// serves every read. A large archive, one that unpacks to more than the copy may hold,
    /// or one for whose copy the temporary folder's volume has no room to spare has no copy;
    /// its members are read from the stream.
    private func loadStream(control: StreamInterrupt?, _ source: @escaping (StreamInterrupt?) throws -> any ByteStream)
        throws
    {
        memberSource = source
        guard file.size <= environment.materializeLimit else {
            try indexTar(try source(control), control: control) { false }
            return
        }
        let url = try environment.scratch.newFile("tar")
        guard let room = scratchWatch(for: file.size) else {
            try indexTar(try source(control), control: control) { false }
            return
        }
        let temporary = TemporaryFile(url)
        let output = try OutputFile(creating: url)
        let copy = TeeStream(try source(control), to: output, limit: environment.unpackedLimit, room: room)
        var data: RandomAccessFile?
        try indexTar(copy, control: control) {
            guard copy.isComplete, (try? output.close()) != nil else { return false }
            data = try? RandomAccessFile(url)
            return data != nil
        }
        if let data { unpacked = (data, temporary) }
    }

    /// A `.gz`, `.bz2` or `.xz` file is shown as a folder holding the one file it compresses
    /// (spec 08 › Nested archives, the GZ example).
    private func loadCompressedFile(_ codec: ArchiveFormat.Codec, control: StreamInterrupt?) throws {
        let suffix = "." + ArchiveFormat.suffix(codec)
        var innerName =
            name.lowercased().hasSuffix(suffix) && name.count > suffix.count
            ? String(name.dropLast(suffix.count)) : name + ".unpacked"
        var modified = signature.modified
        if codec == .gzip, let header = GzipHeader(try file.read(at: 0, count: 1_024)) {
            if let stored = header.name.flatMap(ArchiveTree.normalized).map(ArchiveTree.name(of:)) {
                innerName = stored
            }
            if let time = header.modified { modified = time }
        }
        innerName = ArchiveTree.normalized(innerName).map(ArchiveTree.name(of:)) ?? "unpacked"
        var entry = ArchiveEntry(
            path: innerName,
            isDirectory: false,
            packedSize: Int64(clamping: file.size),
            modified: modified
        )
        entry.content = .whole
        // What the file itself says about its size, without unpacking it.
        var known: (size: UInt64, exact: Bool)?
        switch codec {
        case .xz: known = CompressedSize.ofXZ(file).map { ($0, true) }
        case .gzip: known = CompressedSize.claimedByGzip(file).map { ($0, false) }
        case .bzip2: break
        }
        var counted: UInt64 = 0
        var counter: any ByteStream?
        defer { counter?.close() }
        if file.size <= environment.materializeLimit {
            let url = try environment.scratch.newFile("bin")
            if let room = scratchWatch(for: file.size) {
                let temporary = TemporaryFile(url)
                let output = try OutputFile(creating: url)
                let stream = try codec.decompressing(file, control: control)
                counter = stream
                var fits = true
                while fits, let block = try stream.read(upToCount: 1 << 20) {
                    try control?.check()
                    counted += UInt64(block.count)
                    fits = counted <= environment.unpackedLimit && room.allows(UInt64(block.count))
                    if fits { try output.write(block) }
                }
                if fits {
                    try output.close()
                    let data = try RandomAccessFile(url)
                    unpacked = (data, temporary)
                    entry.size = Int64(clamping: data.size)
                    entry.content = .range(offset: 0, length: data.size)
                    tree.insert(entry)
                    return
                }
                // Given up: the room is free again at once.
                output.discard()
                try? output.close()
            }
        }
        // Too large to keep a copy: every read decompresses. Only a file that does not say
        // its size (BZIP2) is read to its end for it, once, going on where the copy stopped.
        if let known {
            (entry.size, entry.sizeIsExact) = (Int64(clamping: known.size), known.exact)
        } else {
            let stream = try counter ?? codec.decompressing(file, control: control)
            counter = stream
            while let block = try stream.read(upToCount: 1 << 20) {
                try control?.check()
                counted += UInt64(block.count)
            }
            entry.size = Int64(clamping: counted)
        }
        tree.insert(entry)
    }

    // MARK: Looking things up

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The entry at a path; the top folder has none.
    func entry(_ path: String) -> ArchiveEntry? {
        locked { tree.entry(path) }
    }

    /// The entries directly inside a folder; nil when the path is not a folder.
    func children(of path: String) -> [ArchiveEntry]? {
        locked { tree.children(of: path) }
    }

    /// Everything below a folder, in archive order.
    func descendants(of path: String) -> [ArchiveEntry] {
        locked { tree.descendants(of: path) }.sorted { $0.order < $1.order }
    }

    /// Every entry, in archive order.
    var entries: [ArchiveEntry] {
        locked { tree.ordered }
    }

    var hasEncryptedMembers: Bool {
        locked { tree.contains(where: \.isEncrypted) }
    }

    /// The date of the archive file itself.
    var modified: Date {
        locked { signature.modified }
    }

    /// How often a stream archive was read from its beginning for a member.
    var streamStarts: Int {
        locked { starts }
    }

    /// The room this archive takes in the temporary folder: its unpacked copy, and the copy
    /// of an archive that was fetched from elsewhere.
    var scratchBytes: UInt64 {
        locked { (unpacked?.file.size ?? 0).plusClamped(fetchedCopy == nil ? 0 : file.size) }
    }

    private var hasPendingLocked: Bool { changeCount != writtenCount || uploadPending }

    /// Changes waiting, a member being written, or one on its way under a temporary name.
    private var isBusyLocked: Bool { hasPendingLocked || openWriters > 0 || transfers > 0 }

    /// False when the archive file was replaced or changed by someone else since it was read
    /// (and for an archive the store has let go). The disk is asked without the lock; a
    /// server, which costs a round trip, at most once a second, and with a `cancellation`
    /// that wait ends when it is set.
    func isCurrent(cancellation: CancellationFlag? = nil) -> Bool {
        lock.lock()
        if retired {
            lock.unlock()
            return false
        }
        if isBusyLocked {
            lock.unlock()
            return true
        }
        guard fetchedCopy != nil else {
            let known = signature
            lock.unlock()
            let now = FileSignature.of(localURL.path)
            // A write of our own may have come between the look and the question.
            return now == known || now == locked({ signature })
        }
        guard Date().timeIntervalSince(lastRemoteCheck) > 1 else {
            lock.unlock()
            return true
        }
        lastRemoteCheck = Date()
        let stamp = remoteStamp
        lock.unlock()
        guard let provider = try? environment.fileSystems()?.provider(for: archiveURL) else { return false }
        let item =
            cancellation.map { provider.item(at: archiveURL, cancellation: $0) } ?? provider.item(at: archiveURL)
        // A question that was given up says nothing.
        if cancellation?.isCancelled == true { return true }
        guard let item else { return false }
        guard let stamp else {
            // After an upload whose result could not be read back: this is the state to compare with from now on.
            locked { if remoteStamp == nil { remoteStamp = (item.size, item.modified) } }
            return true
        }
        return item.size == stamp.size && item.modified == stamp.modified
    }

    /// Lets the archive go, unless it is in use: see the class comment. True when it is retired.
    func retireIfIdle() -> Bool {
        locked {
            if retired { return true }
            guard !isBusyLocked else { return false }
            retired = true
            return true
        }
    }

    // MARK: Reading members

    /// The contents of a member from its first byte. Members are checked while they are read:
    /// a stream that reaches its end without an error delivered what was packed. A ZIP entry
    /// carries the file its position belongs to, so an entry that was looked up before the
    /// archive was rewritten still reads the right bytes. Through a `slot` the reading ends
    /// early, with an error, when its owner interrupts: where the member lies behind a long
    /// stretch of decompression, opening itself is that long.
    func open(_ entry: ArchiveEntry, slot: InterruptSlot? = nil) throws -> any ByteStream {
        let (file, unpacked, source, format) = locked { (self.file, self.unpacked?.file, memberSource, self.format) }
        switch entry.content {
        case .none:
            return DataStream(Data())

        case .text(let text):
            return DataStream(Data(text.utf8))

        case .unsupported(let what):
            throw ArchiveError.unsupported(what)

        case .zip(let record):
            return try openZip(record, path: entry.path)

        case .range(let offset, let length):
            return FileRangeStream(unpacked ?? file, offset: offset, length: length)

        case .whole:
            guard case .compressedFile(let codec) = format else { throw ArchiveError.notFound(entry.path) }
            let control = StreamInterrupt()
            slot?.use(control)
            return try codec.decompressing(file, control: control)

        case .member(let wanted):
            guard let source else { throw ArchiveError.notFound(entry.path) }
            // A reader that stands in front of the member goes on from there: files copied
            // one after the other cost one pass through the archive, not one each.
            let waiting = locked { () -> (reader: TarReader, next: Int)? in
                guard
                    let index = parked.indices.filter({ parked[$0].next <= wanted })
                        .max(by: {
                            parked[$0].next < parked[$1].next
                        })
                else {
                    starts += 1
                    return nil
                }
                let taken = parked.remove(at: index)
                return (taken.reader, taken.next)
            }
            let reader: TarReader
            if let waiting {
                reader = waiting.reader
            } else {
                let control = StreamInterrupt()
                reader = TarReader(try source(control), control: control)
            }
            slot?.use(reader.control)
            var index = waiting?.next ?? 0
            do {
                while let header = try reader.next() {
                    if index == wanted {
                        try check(header, is: entry)
                        return TarMemberStream(reader, closesReader: false) { [weak self] sound in
                            if sound, let self { park(reader, next: wanted + 1) } else { reader.close() }
                        }
                    }
                    index += 1
                }
            } catch {
                reader.close()
                throw error
            }
            reader.close()
            throw ArchiveError.changedOutside(name)
        }
    }

    /// A member that is found by its number in a stream must be the one that was listed: a
    /// stream that is started again reads the file as it is now, which may be another.
    private func check(_ header: TarHeader, is entry: ArchiveEntry) throws {
        let sameSize = Int64(clamping: header.realSize ?? header.size) == entry.size
        guard sameSize || ArchiveTree.normalized(header.path) == entry.path else {
            throw ArchiveError.changedOutside(name)
        }
    }

    /// Keeps a reader that has delivered a member for the members behind it; it is closed
    /// when nobody came for it after a while. One sweep looks after all that wait, however
    /// many members are read.
    private func park(_ reader: TarReader, next: Int) {
        // One that was interrupted can read no more.
        guard reader.control?.isSet != true else {
            reader.close()
            return
        }
        lock.lock()
        parked.append((reader, next, .now()))
        // One for each of a few threads that read side by side.
        let dropped = parked.count > 4 ? parked.removeFirst() : nil
        let arm = !reaperArmed
        reaperArmed = true
        lock.unlock()
        dropped?.reader.close()
        if arm { armReaper() }
    }

    private func armReaper() {
        // On the plugin's own clock and a thread of its own, like the delayed writes: the
        // shared queues may have no thread free for a long time, and closing a reader may
        // wait for the place the archive lies in.
        let parkTime = environment.readerParkTime
        environment.housekeeping(parkTime + 0.5, .utility) { [weak self] in
            guard let self else { return }
            let limit = UInt64(parkTime * 1_000_000_000)
            lock.lock()
            let now = DispatchTime.now().uptimeNanoseconds
            let stale = parked.filter { now &- $0.since.uptimeNanoseconds >= limit }
            parked.removeAll { now &- $0.since.uptimeNanoseconds >= limit }
            let again = !parked.isEmpty
            reaperArmed = again
            lock.unlock()
            for waiting in stale { waiting.reader.close() }
            if again { armReaper() }
        }
    }

    /// Hands the wanted members to `body` one by one, in archive order. For archives that can
    /// only be read front to back this takes one pass, however many members are wanted;
    /// `body` must then read (or leave) each stream before it returns. With `throughTheEnd`, the
    /// pass reads the archive's stream from the file to its end, also when its members are read
    /// from a copy or none is wanted: only there are the checks of the compressed stream itself
    /// (the checksum at the end of a GZIP file) made, on the file as it is now.
    func readInOnePass(
        _ wanted: [ArchiveEntry],
        cancellation: CancellationFlag? = nil,
        throughTheEnd: Bool,
        _ body: (ArchiveEntry, any ByteStream) throws -> Void
    ) throws {
        // One name per member goes through the pass; further names of the same member (hard
        // links) are read by themselves afterwards.
        var streamed: [Int: ArchiveEntry] = [:]
        for entry in wanted {
            if case .member(let index) = entry.content, streamed[index] == nil { streamed[index] = entry }
        }
        if !streamed.isEmpty || throughTheEnd, let source = locked({ memberSource }) {
            // The pass runs through long stretches of decompression between two members.
            let control = StreamInterrupt()
            let following = control.following(cancellation)
            defer { withExtendedLifetime(following) {} }
            let stream = try source(control)
            let reader = TarReader(stream, control: control)
            defer { reader.close() }
            var index = 0
            var left = streamed.count
            while left > 0 || throughTheEnd, let header = try reader.next() {
                if let entry = streamed[index] {
                    try check(header, is: entry)
                    try body(entry, TarMemberStream(reader, closesReader: false))
                    left -= 1
                }
                index += 1
            }
            // The stream ended before every member came: it is not the archive that was listed.
            if left > 0 { throw ArchiveError.changedOutside(name) }
            // What follows the last member: the end of the TAR, the checksum of the compressed stream.
            while throughTheEnd, try stream.read(upToCount: 1 << 16) != nil { try control.check() }
        }
        for entry in wanted {
            if case .member(let index) = entry.content, streamed[index]?.path == entry.path { continue }
            let stream = try open(entry)
            defer { stream.close() }
            try body(entry, stream)
        }
    }

    /// Whether members can be read independently of each other, on several threads.
    var allowsParallelReads: Bool {
        locked { memberSource == nil || unpacked != nil }
    }

    /// Whether the archive is one compressed stream (a compressed TAR, or another format read
    /// through the system's tool), whose checks are made only by reading it to its end.
    var isOneStream: Bool {
        locked { memberSource != nil }
    }

    private func openZip(_ record: ZipRecord, path: String) throws -> any ByteStream {
        var method = record.method
        var aes: ZipAES.Field?
        if record.method == ZipAES.method {
            guard let field = record.aes else { throw ArchiveError.unsupported("The encryption of \(path)") }
            (aes, method) = (field, field.method)
        }
        guard method == ZipRecord.methodStored || method == ZipRecord.methodDeflate else {
            throw ArchiveError.unsupported("The compression method \(method) of \(path)")
        }
        func raw() throws -> any ByteStream {
            switch record.source {
            case .archive(let headerOffset, let file):
                let dataOffset = try ZipDirectory.localHeader(of: record, at: headerOffset, in: file).dataOffset
                return FileRangeStream(file, offset: dataOffset, length: record.compressedSize)

            case .spool(let temporary):
                return FileRangeStream(try RandomAccessFile(temporary.url), offset: 0, length: record.compressedSize)

            case .none:
                return DataStream(Data())
            }
        }
        var stream: any ByteStream
        var used: String?
        if record.isEncrypted {
            // The byte that proves the password: from the CRC, or from the time when the CRC
            // was not known yet as the member was written.
            let check =
                record.flags & ZipRecord.flagDescriptor != 0 ? UInt8(record.dosTime >> 8) : UInt8(record.crc >> 24)
            let name = self.name
            let opened = try unlocked { [weak self] password -> (any ByteStream) in
                if let aes {
                    return try ZipAESDecryptStream(
                        try raw(),
                        length: record.compressedSize,
                        field: aes,
                        password: password,
                        name: name
                    ) {
                        self?.forget(password)
                    }
                }
                let opened = try ZipDecryptStream(try raw(), password: password, check: check, name: name)
                // The old encryption proves a password with one byte, so one wrong password in
                // 256 gets this far. For a compressed member there is a second look: the start
                // of what it decrypts to must be compressed data. What is not is a wrong
                // password (asked for again, and not kept), not a damaged archive, which is
                // what the user was told once in every 256 wrong answers.
                if method == ZipRecord.methodDeflate, record.compressedSize > 0 {
                    let probe = InflateStream(
                        try ZipDecryptStream(try raw(), password: password, check: check, name: name),
                        wrapping: .raw
                    )
                    defer { probe.close() }
                    do {
                        _ = try probe.read(upToCount: 1 << 12)
                    } catch ArchiveError.damaged {
                        throw ArchiveError.wrongPassword(name)
                    }
                }
                return opened
            }
            (stream, used) = (opened.0, opened.1)
        } else {
            stream = try raw()
        }
        if method == ZipRecord.methodDeflate { stream = InflateStream(stream, wrapping: .raw) }
        stream = SizeGuardStream(stream, limit: record.uncompressedSize, name: path)
        // (AE-2 leaves the checksum out: the member's authentication code stands for it.)
        if aes?.version == 2 { return stream }
        guard let used else { return CRCCheckStream(stream, expected: record.crc, name: path) }
        // One wrong password in 256 passes the check byte; then the data cannot be unpacked,
        // or its checksum is wrong. Such a password is not kept for the next member.
        return CRCCheckStream(stream, expected: record.crc, name: path) { [weak self] in self?.forget(used) }
    }

    // MARK: Passwords

    private func forget(_ password: String) {
        locked { passwords.removeAll { $0 == password } }
    }

    private var isRefusedLocked: Bool {
        (passwordScopes > 0 && refusedInScope) || Date() < refusedUntil
    }

    private func noteRefusal() {
        locked {
            if passwordScopes > 0 { refusedInScope = true }
            if environment.passwordRefusalMemory > 0 {
                refusedUntil = Date(timeIntervalSinceNow: environment.passwordRefusalMemory)
            }
        }
    }

    /// Opens an encrypted member with `make`, which throws `wrongPassword` for a password
    /// that does not fit. The passwords that have opened members of this archive are tried
    /// first. Then the user is asked, by one thread at a time: whoever waited for the
    /// question to be answered tries the answer before asking again. A refusal (no answer, or
    /// three wrong ones) is remembered for the operation under way (`withPasswordScope`) and
    /// for `passwordRefusalMemory`, so that the members that follow fail without a question.
    private func unlocked(_ make: (String) throws -> any ByteStream) throws -> (any ByteStream, String) {
        var tried = Set<String>()
        func tryKnown() throws -> (any ByteStream, String)? {
            for candidate in locked({ passwords }) where tried.insert(candidate).inserted {
                do { return (try make(candidate), candidate) } catch ArchiveError.wrongPassword {}
            }
            return nil
        }
        if let opened = try tryKnown() { return opened }
        // Asked without the directory's lock: the question is put on the main thread.
        passwordGate.lock()
        defer { passwordGate.unlock() }
        if let opened = try tryKnown() { return opened }
        if locked({ isRefusedLocked }) { throw ArchiveError.passwordNeeded(name) }
        for attempt in 0..<3 {
            guard let given = environment.askPassword(name, attempt > 0) else {
                noteRefusal()
                throw ArchiveError.passwordNeeded(name)
            }
            do {
                let stream = try make(given)
                locked {
                    passwords.removeAll { $0 == given }
                    passwords.insert(given, at: 0)
                    if passwords.count > 8 { passwords.removeLast() }
                    (refusedInScope, refusedUntil) = (false, .distantPast)
                }
                return (stream, given)
            } catch ArchiveError.wrongPassword {
                // Asked again, three times at most.
            }
        }
        noteRefusal()
        throw ArchiveError.wrongPassword(name)
    }

    /// Sets the password to try first, for callers that already know it; nil forgets them all.
    func usePassword(_ text: String?) {
        locked {
            guard let text else {
                passwords = []
                return
            }
            passwords.removeAll { $0 == text }
            passwords.insert(text, at: 0)
        }
    }

    /// One operation of the user (unpack, test): inside it the user is asked for a password
    /// until one fits or they decline, and then no more.
    func withPasswordScope<T>(_ body: () throws -> T) rethrows -> T {
        locked { passwordScopes += 1 }
        defer {
            locked {
                passwordScopes -= 1
                if passwordScopes == 0 { refusedInScope = false }
            }
        }
        return try body()
    }

    // MARK: Changing a ZIP

    /// Called with the lock held, by everything that changes the archive. Answers from
    /// memory; what the disk has to say comes from `requireWritable()`, before the lock.
    private func requireEditable() throws {
        guard !retired else { throw ArchiveError.retired }
        guard format.isEditable else { throw ArchiveError.readOnly(name) }
        guard !hasDuplicates else {
            throw ArchiveError.unsupported("Changing an archive that lists a name twice (\(name))")
        }
    }

    /// Whether the archive file can be written where it lies, and (asked once) whether its
    /// volume clones files. Called by everything that changes the archive **before** it takes
    /// the lock: the disk, and the file system an archive was fetched from, are never asked
    /// while the directory is locked.
    private func requireWritable() throws {
        var refusal: any Error?
        if fetchedCopy != nil {
            if environment.fileSystems()?.capabilities(for: archiveURL).contains(.write) != true {
                refusal = ArchiveError.readOnly(name)
            }
        } else if access(localURL.path, W_OK) != 0 || access(localURL.deletingLastPathComponent().path, W_OK) != 0 {
            refusal = posixError(EACCES, localURL.path)
        }
        if let refusal {
            // What the archive itself has to say comes first (retired, not a ZIP).
            try locked { try requireEditable() }
            throw refusal
        }
        probeCloning()
    }

    /// Tries once whether the archive's file system makes clones. Not under the lock.
    private func probeCloning() {
        guard environment.clonesArchives,
            locked({ () -> Bool in
                defer { cloneProbed = true }
                return !cloneProbed
            })
        else { return }
        let probe = localURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(instance)-probe.afm-zip.tmp",
                isDirectory: false
            )
        unlink(probe.path)
        var result: Bool?
        if clonefile(localURL.path, probe.path, 0) == 0 {
            unlink(probe.path)
            result = true
        } else if errno == ENOTSUP || errno == EXDEV {
            result = false
        }
        // A write that found out meanwhile knows better.
        locked { if canClone == nil { canClone = result } }
    }

    /// Makes what `capabilities` answers from follow the directory. Called when it was read.
    private func publish() {
        let editable = format.isEditable && !hasDuplicates
        stateLock.lock()
        publishedEditable = editable
        stateLock.unlock()
    }

    /// What can be done inside this archive, from what is known without touching the disk:
    /// members can be added, renamed and removed in a ZIP that lists no name twice, and that
    /// lies where the file system can be written to. Writes are kept back (`.deferredWrites`):
    /// whoever is about to destroy the only other copy of what it wrote calls `commit` first.
    /// Answers at once, on any thread: it waits for no lock that is held while a file is
    /// read, written or asked about.
    var capabilities: FileSystemCapabilities {
        stateLock.lock()
        let editable = publishedEditable
        stateLock.unlock()
        guard editable else { return [] }
        if fetchedCopy != nil, environment.fileSystems()?.capabilities(for: archiveURL).contains(.write) != true {
            return []
        }
        return [.write, .deferredWrites]
    }

    /// Notes a change and sees to it that it is written. Called with the lock held.
    private func changed() {
        changeCount += 1
        lastChange = .now()
        if let delay = environment.flushDelay { armTimer(after: idleDelay(delay)) }
    }

    /// One timer at a time, however many changes arrive; one that is due earlier takes the
    /// place of the one that is armed (a change after a failed write does not wait for the
    /// retry). The timer holds on to the archive: an archive with changes waiting is not
    /// released before they are written, whoever else lets go of it. (Once the plugin has
    /// stopped, a timer that still fires does nothing.)
    ///
    /// The timer runs with low priority, which under full load may not run for minutes; a
    /// second one with the user's priority follows `escalationDelay` later and does the work
    /// if the first has not. Called with the lock held.
    private func armTimer(after delay: TimeInterval) {
        let deadline = DispatchTime.now() + delay
        if let armed = timerDeadline, armed <= deadline { return }
        timerDeadline = deadline
        timerNumber += 1
        let number = timerNumber
        environment.schedule(delay, .utility) { self.timerFired(number) }
        environment.schedule(delay + environment.escalationDelay, .userInitiated) { self.timerFired(number) }
    }

    /// True when the next write has to copy the whole archive (or send it to a server).
    private var writesWholeArchive: Bool {
        removals != writtenRemovals || fetchedCopy != nil || clones() == false
    }

    /// How long nothing must have changed before the timer writes. A write that copies the
    /// whole archive waits for a pause many times its own length, so that a slow job (a
    /// server, a question left unanswered) is not interleaved with rewrites of the archive.
    private func idleDelay(_ base: TimeInterval) -> TimeInterval {
        writesWholeArchive ? max(base, min(60, 20 * lastRewriteDuration)) : base
    }

    private func timerFired(_ number: Int) {
        lock.lock()
        // Overtaken by a later timer, or done already by its twin.
        guard number == timerNumber, timerDeadline != nil else {
            lock.unlock()
            return
        }
        timerDeadline = nil
        // The program is quitting: the stop writes what waits.
        guard !environment.isStopping else {
            lock.unlock()
            return
        }
        let notify = notifyPending && !hasPendingLocked
        if notify { notifyPending = false }
        // Nothing waits: the next rename may write again.
        if !hasPendingLocked { (immediateSpent, arrivedBytes) = (0, 0) }
        guard hasPendingLocked, let base = environment.flushDelay else {
            lock.unlock()
            if notify { environment.contentsChanged(archiveURL) }
            return
        }
        // Not while a member is being written (the end of the writer arms the timer again),
        // and not before the changes have paused.
        guard openWriters == 0 else {
            lock.unlock()
            return
        }
        let wait = idleDelay(base)
        let idle = Double(DispatchTime.now().uptimeNanoseconds &- lastChange.uptimeNanoseconds) / 1_000_000_000
        if idle < wait {
            armTimer(after: max(0.01, wait - idle))
            lock.unlock()
            return
        }
        notifyPending = false
        lock.unlock()
        do {
            try flush(cancellation: environment.quitting)
        } catch {
            // The changes are still waiting. The user hears of it once; the write is tried
            // again later, each time after twice as long, and at once when something changes.
            lock.lock()
            let text = error.localizedDescription
            let isNews = reportedFailure != text
            reportedFailure = text
            failures += 1
            if hasPendingLocked, !environment.isStopping {
                let pause = max(environment.retryDelay, wait) * pow(2, Double(min(failures - 1, 20)))
                armTimer(after: min(pause, max(environment.maxRetryDelay, environment.retryDelay)))
            }
            lock.unlock()
            if case ArchiveError.cancelled = error { return }
            if isNews { environment.reportFailure(error, name) }
        }
        environment.contentsChanged(archiveURL)
    }

    /// Whether the archive's file system makes clones, as far as is known (`probeCloning`
    /// tried it before the first change; a write that could not clone corrects it); nil when
    /// the try said neither. Called with the lock held; asks nothing.
    private func clones() -> Bool? {
        environment.clonesArchives ? canClone : false
    }

    /// Keeps a folder that has no entry of its own from vanishing with the last thing in it.
    private func keepFolder(_ path: String) {
        guard !path.isEmpty, let folder = tree.entry(path), folder.isImplicit, !tree.hasChildren(path) else { return }
        tree.insert(
            Self.entry(
                path: path,
                for: .new(name: path, isDirectory: true, modified: Date(), permissions: 0o755)
            )
        )
    }

    /// The name a job gives a file while it brings it in (`.afm-<UUID>.tmp`).
    static func isTransferName(_ name: String) -> Bool {
        name.utf8.count == 45 && name.hasPrefix(".afm-") && name.hasSuffix(".tmp")
    }

    /// True for a member that came through a writer under a job's temporary name and has not
    /// been given its real name yet: it is not written into the archive file.
    private static func isTransfer(_ entry: ArchiveEntry) -> Bool {
        guard case .zip(let record) = entry.content else { return false }
        return !record.isInArchive && record.unwritten.contains(.arriving) && isTransferName(entry.name)
    }

    /// Takes an entry of the directory out of it and notes what that means for the archive file.
    private func take(_ entry: ArchiveEntry) {
        tree.remove(entry.path)
        if case .zip(let record) = entry.content {
            if record.isInArchive {
                removals += 1
            } else {
                pendingBytes -= min(pendingBytes, record.compressedSize)
            }
        }
        if Self.isTransfer(entry) { transfers -= 1 }
    }

    /// Puts an entry into the directory that came through a writer or was taken out before.
    private func put(_ entry: ArchiveEntry, keepingOrder: Bool = false) {
        tree.insert(entry, keepingOrder: keepingOrder)
        if Self.isTransfer(entry) { transfers += 1 }
    }

    /// Creates a folder and the folders above it.
    func makeDirectory(_ path: String) throws {
        try requireWritable()
        try locked {
            try requireEditable()
            var missing: [String] = []
            var current = path
            while !current.isEmpty {
                if let existing = tree.entry(current) {
                    guard existing.isDirectory else { throw ArchiveError.notADirectory(current) }
                    break
                }
                missing.append(current)
                current = ArchiveTree.parent(of: current)
            }
            guard !missing.isEmpty else { return }
            for folder in missing.reversed() {
                tree.insert(
                    Self.entry(
                        path: folder,
                        for: .new(name: folder, isDirectory: true, modified: Date(), permissions: 0o755)
                    )
                )
            }
            changed()
        }
    }

    /// Where the next new member waits until it is written into the archive: in the
    /// temporary folder, or, when the archive lies on another volume than that folder, in a
    /// hidden folder next to the archive. A job that copies a hundred gigabytes into a ZIP on
    /// an external disk then needs the room there, where the archive grows anyway, and not on
    /// the disk the system runs from. Asks the disk, so it is called without the lock.
    private func newSpool() throws -> (url: URL, folder: URL, isOutside: Bool) {
        var place = locked { spoolFolder.map { (folder: $0, isOutside: spoolIsOutside) } }
        if place == nil {
            let scratch = environment.scratch.url
            let home = localURL.deletingLastPathComponent()
            var chosen = (folder: scratch, isOutside: false)
            if fetchedCopy == nil, let own = environment.volume(home.path),
                let other = environment.volume(scratch.deletingLastPathComponent().path), own != other
            {
                let folder = home.appendingPathComponent(".afm-spool-\(getpid())-\(instance)", isDirectory: true)
                if mkdir(folder.path, 0o700) == 0 || errno == EEXIST {
                    environment.scratch.noteExternal(folder)
                    chosen = (folder, true)
                }
            }
            // Two writers that began together decided the same: the folder's name is the archive's.
            place = locked {
                if spoolFolder == nil { (spoolFolder, spoolIsOutside) = (chosen.folder, chosen.isOutside) }
                return spoolFolder.map { (folder: $0, isOutside: spoolIsOutside) }
            }
        }
        guard let place, place.isOutside else {
            return (try environment.scratch.newFile("zipdata"), environment.scratch.url, false)
        }
        return (
            place.folder.appendingPathComponent(UUID().uuidString + ".zipdata", isDirectory: false), place.folder, true
        )
    }

    /// Starts a new member. Its data is compressed into a temporary file while it is written
    /// and joins the archive's directory when the writer is closed. `level` overrides the
    /// compression rate of the settings; with a `password` the member is encrypted (AES-256).
    func write(_ path: String, level: Int? = nil, password: String? = nil) throws -> any FileWriter {
        try requireWritable()
        try locked {
            try requireEditable()
            guard !path.isEmpty else { throw ArchiveError.notFound(path) }
            if tree.entry(path) != nil { throw FileSystemError.alreadyExists(path) }
            let parent = ArchiveTree.parent(of: path)
            guard tree.isDirectory(parent) || tree.entry(parent) == nil else {
                throw ArchiveError.notADirectory(parent)
            }
            // From here on the archive is in use: it is not let go while the file is made.
            openWriters += 1
        }
        // The temporary file is made without the lock.
        do {
            let spool = try newSpool()
            // The room is watched while a large member comes in, wherever it waits.
            let room = SpaceWatch(
                folder: spool.folder,
                reserve: spool.isOutside ? 64 << 20 : environment.scratchReserve,
                hasRoom: environment.hasRoom
            )
            return try ZipMemberWriter(
                archive: self,
                path: path,
                level: level ?? environment.options.compressionLevel,
                password: password?.isEmpty == false ? password : nil,
                spool: spool.url,
                room: room
            )
        } catch {
            try? finishWrite(nil, path: path)
            throw error
        }
    }

    /// The end of a writer: with a record the member joins the directory. That is refused
    /// when the disk has no room to write the member into the archive file later: the writer
    /// fails here, where its job can still tell the user and keep the source.
    fileprivate func finishWrite(_ record: ZipRecord?, path: String) throws {
        guard let record else {
            // Abandoned: nothing joins. What else waits is written once no writer is open.
            locked {
                openWriters -= 1
                if openWriters == 0, hasPendingLocked, let delay = environment.flushDelay {
                    armTimer(after: idleDelay(delay))
                }
            }
            return
        }
        // The disk is asked without the lock.
        let needed: UInt64 = locked {
            let directory = file.size - min(file.size, directoryOffset)
            return (writesWholeArchive ? file.size : 0).plusClamped(pendingBytes).plusClamped(record.compressedSize)
                .plusClamped(directory + 4_096)
        }
        let fits = environment.hasRoom(needed, localURL.deletingLastPathComponent())
        try locked {
            openWriters -= 1
            guard fits else {
                if openWriters == 0, hasPendingLocked, let delay = environment.flushDelay {
                    armTimer(after: idleDelay(delay))
                }
                throw ArchiveError.noRoom(name)
            }
            // Something else took the name meanwhile: the member that was finished last stays.
            if let existing = tree.entry(path), !existing.isImplicit { take(existing) }
            var arriving = record
            arriving.unwritten.insert(.arriving)
            put(Self.entry(path: path, for: arriving))
            pendingBytes = pendingBytes.plusClamped(record.compressedSize)
            arrivedBytes = arrivedBytes.plusClamped(record.compressedSize)
            changed()
        }
    }

    /// Removes a file or an empty folder.
    func remove(_ path: String) throws {
        try requireWritable()
        try locked {
            try requireEditable()
            guard let entry = tree.entry(path) else { throw ArchiveError.notFound(path) }
            if entry.isDirectory, tree.hasChildren(path) {
                throw FileSystemError.notSupported("Removing the non-empty folder \(path)")
            }
            take(entry)
            keepFolder(ArchiveTree.parent(of: path))
            changed()
        }
    }

    /// The renaming itself, with the lock held. Returns what stood at the destination.
    private func rename(_ source: String, to destination: String, replacing: Bool) throws -> ArchiveEntry? {
        guard let entry = tree.entry(source), !destination.isEmpty else { throw ArchiveError.notFound(source) }
        if ArchiveTree.relative(destination, to: source) != nil {
            throw FileSystemError.notSupported("Moving a folder into itself")
        }
        var replaced: ArchiveEntry?
        if let existing = tree.entry(destination) {
            guard replacing else { throw FileSystemError.alreadyExists(destination) }
            // As on the disk: a file takes the place of a file, and a folder that of an empty folder.
            if existing.isDirectory != entry.isDirectory || tree.hasChildren(destination) {
                throw FileSystemError.alreadyExists(destination)
            }
            take(existing)
            replaced = existing
        }
        let moved = [entry] + (entry.isDirectory ? tree.descendants(of: source) : [])
        for item in moved {
            if Self.isTransfer(item) { transfers -= 1 }
            tree.remove(item.path)
        }
        for var item in moved.sorted(by: { $0.order < $1.order }) {
            // Cut and joined by bytes: the paths are not the same string to Swift in every case.
            item.path = ArchiveTree.relative(item.path, to: source).map { destination + "/" + $0 } ?? destination
            if case .zip(var record) = item.content {
                record.setName(item.isDirectory ? item.path + "/" : item.path)
                record.unwritten.remove(.arriving)
                item.content = .zip(record)
            }
            tree.insert(item, keepingOrder: true)
        }
        keepFolder(ArchiveTree.parent(of: source))
        changed()
        return replaced
    }

    /// Renames a file, or a folder with everything in it.
    ///
    /// A file that has just come through a writer gets its final name this way when a job
    /// has copied it in (jobs write under a temporary name and rename). Whoever moves files
    /// deletes the source once the rename has returned, so here the archive file is written
    /// before it returns, when that is cheap (`immediateWriteLimit`): if the write fails,
    /// the rename fails with it, is taken back, and the source stays. A write that would
    /// cost more than the limit is left to the timer, and so is one that would have to wait
    /// for a write that is under way; a file was only admitted then because
    /// the disk had room for that write (`finishWrite`), and a write that fails all the same
    /// loses nothing: it is reported and tried again. Files of other threads that are still
    /// under their temporary names are left out of this write; each follows with its own.
    ///
    /// This is a convenience for callers that do not `commit`; one that does makes it
    /// redundant. So that a job with many small files does not write the directory again
    /// for each of them, what these writes cost between two rests is held to the limit plus
    /// the bytes that arrived meanwhile (the data pays for its own overhead); past that the
    /// timer or the commit writes.
    func move(_ source: String, to destination: String, replacing: Bool) throws {
        var replaced: ArchiveEntry?
        var loaded = 0
        try requireWritable()
        let writesNow: UInt64? = try locked {
            try requireEditable()
            guard let entry = tree.entry(source) else { throw ArchiveError.notFound(source) }
            guard source != destination else { return nil }
            replaced = try rename(source, to: destination, replacing: replacing)
            loaded = loadCount
            guard !entry.isDirectory, case .zip(let record) = entry.content, record.unwritten.contains(.arriving),
                environment.immediateWriteLimit > 0
            else { return nil }
            // The directory is written; so is the member once more, if a write that came
            // between has already put it into the file under its temporary name.
            var cost = file.size - min(file.size, directoryOffset)
            if record.isInArchive { cost = cost.plusClamped(record.compressedSize) }
            if writesWholeArchive { cost = cost.plusClamped(file.size) }
            guard cost <= max(environment.immediateWriteLimit, pendingBytes),
                immediateSpent.plusClamped(cost) <= environment.immediateWriteLimit.plusClamped(arrivedBytes)
            else { return nil }
            return cost
        }
        guard let writesNow else { return }
        // Not behind a write that may take minutes: then the timer (or the commit) writes.
        // Behind another rename's write, which is as small as this one, it waits its turn.
        guard gate.lockUnlessLong() else { return }
        do {
            defer { gate.unlock() }
            try flushLocked(leavingOutArrivals: true, cancellation: nil)
            locked { immediateSpent = immediateSpent.plusClamped(writesNow) }
        } catch {
            locked {
                // After the directory was read anew from a file that someone else changed,
                // the member has been put back by its new name already, and what stood at
                // the destination is what the file holds.
                guard loadCount == loaded else { return }
                _ = try? rename(destination, to: source, replacing: false)
                // Under its temporary name again, it is on its way again.
                if var entry = tree.remove(source) {
                    if case .zip(var record) = entry.content {
                        record.unwritten.insert(.arriving)
                        entry.content = .zip(record)
                    }
                    put(entry, keepingOrder: true)
                }
                if let replaced {
                    put(replaced, keepingOrder: true)
                    // Taking it out was counted; it is back.
                    if case .zip(let record) = replaced.content {
                        if record.isInArchive {
                            removals -= 1
                        } else {
                            pendingBytes = pendingBytes.plusClamped(record.compressedSize)
                        }
                    }
                }
            }
            throw error
        }
        // The archive file has a new size and date; the panels hear of it once the job pauses.
        locked {
            notifyPending = true
            if let delay = environment.flushDelay { armTimer(after: delay) }
        }
    }

    /// A second member with the same contents under another name. The compressed data is
    /// shared until the archive is written, and copied as it is then.
    func duplicate(_ source: String, to destination: String) throws -> Int64 {
        try requireWritable()
        return try locked {
            try requireEditable()
            guard var entry = tree.entry(source), !entry.isDirectory, case .zip(var record) = entry.content else {
                throw ArchiveError.notFound(source)
            }
            if tree.entry(destination) != nil { throw FileSystemError.alreadyExists(destination) }
            record.setName(destination)
            record.unwritten.remove(.arriving)
            entry.path = destination
            entry.content = .zip(record)
            tree.insert(entry)
            if !record.isInArchive { pendingBytes = pendingBytes.plusClamped(record.compressedSize) }
            changed()
            return entry.size
        }
    }

    func setAttributes(_ attributes: FileAttributes, of path: String) throws {
        try requireWritable()
        try locked {
            try requireEditable()
            guard var entry = tree.entry(path) else { throw ArchiveError.notFound(path) }
            var record: ZipRecord
            if case .zip(let existing) = entry.content {
                record = existing
            } else {
                record = .new(name: path, isDirectory: true, modified: entry.modified, permissions: entry.permissions)
            }
            if let modified = attributes.modified { record.setModified(modified) }
            if let permissions = attributes.permissions { record.setPermissions(permissions) }
            entry = Self.entry(path: path, for: record)
            tree.insert(entry)
            changed()
        }
    }

    /// True when changes are waiting to be written.
    var hasPendingChanges: Bool {
        locked { hasPendingLocked }
    }

    /// True while the archive may not be let go: changes are waiting, a member is being
    /// written, or one is on its way under a temporary name.
    var isBusy: Bool {
        locked { isBusyLocked }
    }

    // MARK: Writing the changes

    /// What a write works from: the directory as it was when the write began.
    private struct Snapshot {
        var entries: [ArchiveEntry]
        var unlisted: [ZipRecord]
        var file: RandomAccessFile
        var comment: Data
        var directoryOffset: UInt64
        var prefixEnd: UInt64
        var changeCount: Int
        var removals: Int
        var removesMembers: Bool
        /// The compressed bytes of the members this write puts into the file.
        var pendingBytes: UInt64
        var mayClone: Bool
        /// False when members were left out: then changes are still waiting afterwards.
        var isComplete: Bool
    }

    /// The new archive file, complete under a temporary name.
    private struct Built {
        var url: URL
        /// Where each member's header lies in it, by the member's position in the directory.
        var offsets: [Int: UInt64] = [:]
        var unlistedOffsets: [UInt64] = []
        var directoryOffset: UInt64 = 0
        /// False when the old file was cloned and added to.
        var isRewrite = true
    }

    /// Writes the pending changes into the archive file (see the class comment for how). If
    /// that fails nothing has changed, on disk or here: the changes keep waiting, and the
    /// call can be repeated. Members that were added, or changed again, while the file was
    /// being written wait for the next write, and with `leavingOutArrivals` so do members
    /// that came through a writer and have not been given their final names yet.
    ///
    /// With a `cancellation`, a write that is under way ends soon after it is set, with
    /// `ArchiveError.cancelled`, and so does the wait for another write of this archive to
    /// end; like any failed write it changes nothing. Not for the main thread.
    ///
    /// `progress` is asked between the members that are written and between the blocks that
    /// are sent to a server, with the bytes written so far and those expected; it may take
    /// its time (a job that is paused waits in it), and false ends the write like a cancel.
    func flush(
        leavingOutArrivals: Bool = false,
        cancellation: CancellationFlag? = nil,
        progress: (Int64, Int64) -> Bool = { _, _ in true }
    ) throws {
        try gate.lock(long: true, cancellation: cancellation)
        defer { gate.unlock() }
        try flushLocked(leavingOutArrivals: leavingOutArrivals, cancellation: cancellation, progress: progress)
    }

    /// The write itself, with the gate held.
    private func flushLocked(
        leavingOutArrivals: Bool,
        cancellation: CancellationFlag?,
        progress: (Int64, Int64) -> Bool = { _, _ in true }
    ) throws {
        let start = Date()
        var rewrote = false
        var lostChanges = false
        try Self.check(cancellation)
        var snapshot = takeSnapshot(leavingOutArrivals: leavingOutArrivals)
        if snapshot != nil, FileSignature.of(localURL.path) != locked({ signature }) {
            // Another program replaced the archive. What was only renamed or deleted here
            // cannot be carried over; new members are added to the archive as it is now. (Should
            // it be replaced once more meanwhile, `install` notices, and the write fails.)
            lostChanges = try rebase()
            snapshot = takeSnapshot(leavingOutArrivals: leavingOutArrivals)
        }
        if let snapshot {
            let built = try build(snapshot, cancellation: cancellation, progress: progress)
            environment.whileWriting?()
            try install(built, from: snapshot)
            // The folder's entry is what makes the new file the archive after a loss of power.
            Durable.syncFolder(of: localURL)
            rewrote = built.isRewrite
        }
        if fetchedCopy != nil, locked({ uploadPending }) {
            try upload(cancellation: cancellation, progress: progress)
            rewrote = true
        }
        locked {
            if rewrote { lastRewriteDuration = Date().timeIntervalSince(start) }
            reportedFailure = nil
            failures = 0
            if !leavingOutArrivals { (immediateSpent, arrivedBytes) = (0, 0) }
        }
        if lostChanges { throw ArchiveError.changedOutside(name) }
    }

    private static func check(_ cancellation: CancellationFlag?) throws {
        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }
    }

    /// Makes the archive file on the disk (or on the server it came from) hold everything
    /// that was written through writers that are closed, and the renames, deletions and
    /// changes of attributes made so far; returns when it does. This is the write of the
    /// delay, done now, on the calling thread. A write that fails throws and leaves
    /// everything as it is for the next attempt, like the delayed one. The failure is then
    /// the caller's to report: the delay does not report the same one again.
    ///
    /// `progress`: see `flush`; with it a commit that takes long can be shown, held and ended.
    func commit(cancellation: CancellationFlag? = nil, progress: (Int64, Int64) -> Bool = { _, _ in true }) throws {
        do {
            try flush(cancellation: cancellation, progress: progress)
        } catch {
            if cancellation?.isCancelled != true { locked { reportedFailure = error.localizedDescription } }
            throw error
        }
        // The panels that show the archive's folder hear of its new size and date.
        locked {
            notifyPending = true
            if let delay = environment.flushDelay { armTimer(after: delay) }
        }
    }

    /// Runs `body` while no write of this archive is under way, after what was waiting has
    /// been written: for whoever rewrites the archive file itself (Pack). `body` gets a check
    /// to call right before it puts its new file in the archive's place, which throws when
    /// the file is no longer the one that was there when `body` began.
    func whileHoldingFile<T>(
        cancellation: CancellationFlag?,
        _ body: (_ stillUnchanged: () throws -> Void) throws -> T
    ) throws -> T {
        try gate.lock(long: true, cancellation: cancellation)
        defer { gate.unlock() }
        try flushLocked(leavingOutArrivals: false, cancellation: cancellation)
        let (path, name) = (localURL.path, self.name)
        let before = FileSignature.of(path)
        return try body {
            guard FileSignature.of(path) == before else { throw ArchiveError.changedOutside(name) }
        }
    }

    /// Nil when there is nothing to write.
    private func takeSnapshot(leavingOutArrivals: Bool) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard changeCount != writtenCount else { return nil }
        // (A folder that loses its last member without ever having had an entry gets one
        // then: `keepFolder`. So every folder without an entry has something in it.)
        var entries = tree.ordered
        var (isComplete, hasWork, bytes) = (true, removals != writtenRemovals, UInt64(0))
        entries.removeAll { entry in
            guard case .zip(let record) = entry.content else { return false }
            if record.isInArchive {
                if !record.unwritten.subtracting(.arriving).isEmpty { hasWork = true }
                return false
            }
            // A member under a job's temporary name is never written: it joins the file when
            // it has its real name. It is not a change that waits, either.
            if Self.isTransfer(entry) { return true }
            if leavingOutArrivals, record.unwritten.contains(.arriving) {
                isComplete = false
                return true
            }
            hasWork = true
            bytes = bytes.plusClamped(record.compressedSize)
            return false
        }
        guard hasWork else {
            // Every change was taken back, or written by a write that came between.
            if isComplete { writtenCount = changeCount }
            return nil
        }
        return Snapshot(
            entries: entries,
            unlisted: unlisted,
            file: file,
            comment: comment,
            directoryOffset: directoryOffset,
            prefixEnd: prefixEnd,
            changeCount: changeCount,
            removals: removals,
            removesMembers: removals != writtenRemovals,
            pendingBytes: bytes,
            mayClone: clones() != false,
            isComplete: isComplete
        )
    }

    /// Whether the changes can be appended to a clone of the archive: nothing was deleted,
    /// every member lies where the directory says, whole and in front of the directory (which
    /// is cut off and written anew), and the stretches no member uses any more (left by
    /// renames, which append a member under its new name) stay below a quarter of the file.
    private func canAppend(_ snapshot: Snapshot) -> Bool {
        guard snapshot.mayClone, !snapshot.removesMembers, snapshot.directoryOffset <= snapshot.file.size else {
            return false
        }
        var used: UInt64 = 0
        var members: UInt64 = 0
        func count(_ record: ZipRecord) -> Bool {
            guard case .archive(let offset, let file) = record.source else { return true }
            guard file === snapshot.file else { return true }
            // A member whose data ran into the directory would be cut with it.
            let end = offset.plusClamped(30 + UInt64(record.nameLength)).plusClamped(record.compressedSize)
            guard offset < snapshot.directoryOffset, end <= snapshot.directoryOffset else { return false }
            members += 1
            if !record.unwritten.contains(.name) {
                used = used.plusClamped(30 + UInt64(record.nameLength) + UInt64(record.extraLength))
                    .plusClamped(
                        record.compressedSize
                    )
            }
            return true
        }
        for record in snapshot.unlisted where !count(record) { return false }
        for entry in snapshot.entries {
            if case .zip(let record) = entry.content, !count(record) { return false }
        }
        let area = snapshot.directoryOffset - min(snapshot.directoryOffset, snapshot.prefixEnd)
        // Headers are counted by what the directory knows of them, which is a little less
        // than they take; that much is not held against the archive.
        let unused = area - min(area, used.plusClamped(members * 48))
        return unused <= max(area / 4, 64 << 10)
    }

    private func build(_ snapshot: Snapshot, cancellation: CancellationFlag?, progress: (Int64, Int64) -> Bool) throws
        -> Built
    {
        let expected = Int64(clamping: snapshot.file.size.plusClamped(snapshot.pendingBytes))
        /// Asked before each member: where the write stands. False ends it.
        func ask(_ written: UInt64) throws {
            if !progress(Int64(clamping: written), expected) { throw ArchiveError.cancelled }
        }
        // One name for this archive's new file, whichever write makes it: it is noted once,
        // so that the next start can clear it away if this one dies in the middle.
        let temporary = localURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(instance).afm-zip.tmp",
                isDirectory: false
            )
        if fetchedCopy == nil,
            locked({ () -> Bool in
                defer { notedBuildFile = true }
                return !notedBuildFile
            })
        {
            environment.scratch.noteExternal(temporary)
        }
        unlink(temporary.path)
        var built = Built(url: temporary)
        if canAppend(snapshot) {
            if clonefile(localURL.path, temporary.path, 0) == 0 {
                built.isRewrite = false
            } else if errno == ENOTSUP || errno == EXDEV {
                locked { canClone = false }
            }
        }
        let isRewrite = built.isRewrite
        do {
            let output =
                try isRewrite
                ? OutputFile(creating: temporary) : OutputFile(extending: temporary, from: snapshot.directoryOffset)
            do {
                let writer = ZipWriter(output, limits: environment.limits)
                if isRewrite {
                    // What stands in front of the first member stays in front of it.
                    let prefix = FileRangeStream(snapshot.file, offset: 0, length: snapshot.prefixEnd)
                    while let block = try prefix.read(upToCount: 1 << 20) {
                        try Self.check(cancellation)
                        try writer.append(block)
                    }
                }
                func place(_ record: ZipRecord) throws -> UInt64 {
                    // A member that lies in the cloned file with the name it has stays where it is.
                    if !isRewrite, case .archive(let offset, let file) = record.source, file === snapshot.file,
                        !record.unwritten.contains(.name)
                    {
                        if record.unwritten.contains(.time) {
                            try Self.correctTime(of: record, at: offset, in: file, through: writer)
                        }
                        writer.adopt(record, at: offset)
                        return offset
                    }
                    return try writer.copyMember(record, cancellation: cancellation)
                }
                for record in snapshot.unlisted {
                    try Self.check(cancellation)
                    try ask(output.position)
                    let offset = try place(record)
                    built.unlistedOffsets.append(offset)
                }
                built.offsets.reserveCapacity(snapshot.entries.count)
                for entry in snapshot.entries {
                    guard case .zip(let record) = entry.content else { continue }
                    try Self.check(cancellation)
                    try ask(output.position)
                    let offset = try place(record)
                    built.offsets[entry.order] = offset
                }
                built.directoryOffset = output.position
                try writer.finish(comment: snapshot.comment)
                if isRewrite {
                    // The new file takes over what the old one carried besides its contents
                    // (a clone has it already): the mode, and labels such as the quarantine.
                    var status = stat()
                    if stat(localURL.path, &status) == 0 { output.setMode(status.st_mode) }
                }
                // On the disk before it takes the archive's place.
                try output.close(durably: true)
                if isRewrite {
                    copyfile(localURL.path, temporary.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
                    Quarantine.apply(Quarantine.read(localURL.path), to: temporary)
                }
            } catch {
                try? output.close()
                throw error
            }
        } catch {
            unlink(temporary.path)
            throw error
        }
        return built
    }

    /// Writes a changed time into the header in front of a member's data, in the clone: the
    /// DOS time, and the exact time where the header has that field. Nothing is written
    /// before the header was found to be this member's: a directory that points elsewhere
    /// must not get another member's data overwritten.
    private static func correctTime(
        of record: ZipRecord,
        at offset: UInt64,
        in file: RandomAccessFile,
        through writer: ZipWriter
    ) throws {
        var header = ByteReader(try file.read(at: offset, count: 30))
        guard header.remaining == 30, header.u32() == ZipDirectory.localSignature else {
            throw ArchiveError.damaged("the entry \(record.name) is not where the directory says")
        }
        header.position = 26
        let (nameLength, extraLength) = (UInt64(header.u16()), Int(header.u16()))
        guard nameLength == UInt64(record.nameLength),
            try file.read(at: offset + 30, count: Int(nameLength)) == record.nameBytes
        else {
            throw ArchiveError.damaged("the entry \(record.name) is not where the directory says")
        }
        var stamp = Data()
        stamp.appendLE(record.dosTime)
        stamp.appendLE(record.dosDate)
        try writer.patch(stamp, at: offset + 10)
        // (A changed time always comes with the exact field: `ZipRecord.setModified`.)
        let exact = ZipRecord.field(0x5455, in: record.extra)
        var fields = ByteReader(try file.read(at: offset + 30 + nameLength, count: extraLength))
        while fields.remaining >= 4 {
            let (id, size) = (fields.u16(), Int(fields.u16()))
            guard size <= fields.remaining else { return }
            if id == 0x5455, size >= 5, fields.data[fields.data.startIndex + fields.position] & 1 != 0, let exact,
                exact.count >= 5
            {
                try writer.patch(
                    Data(exact.dropFirst().prefix(4)),
                    at: offset + 30 + nameLength + UInt64(fields.position) + 1
                )
                return
            }
            fields.position += size
        }
    }

    /// Puts the new file in the archive's place and makes the directory in memory speak of
    /// it: one rename, then a walk over the entries that were written.
    ///
    /// The disk is asked and the file renamed **without** the directory's lock; the lock is
    /// taken only for the walk, which is memory alone. That is sound because the gate is held
    /// (no other write of this archive runs, and `signature` and `file` change nowhere else),
    /// and because the archive has changes waiting until the walk is done: `isCurrent`
    /// answers for a busy archive without looking at the disk, so nobody takes the moment
    /// between the rename and the walk for a change made by someone else. Readers that hold
    /// the old file go on reading it; it lives for as long as it is open.
    private func install(_ built: Built, from snapshot: Snapshot) throws {
        let newFile: RandomAccessFile
        do {
            guard FileSignature.of(localURL.path) == locked({ signature }) else {
                throw ArchiveError.changedOutside(name)
            }
            newFile = try RandomAccessFile(built.url, shownAs: localURL.path)
            guard Darwin.rename(built.url.path, localURL.path) == 0 else { throw posixError(errno, localURL.path) }
        } catch {
            unlink(built.url.path)
            throw error
        }
        lock.lock()
        defer { lock.unlock() }
        file = newFile
        // Of the file that was opened: no other can have come between.
        signature = newFile.signature
        directoryOffset = built.directoryOffset
        if unlisted.count == built.unlistedOffsets.count {
            for (index, offset) in built.unlistedOffsets.enumerated() {
                unlisted[index].source = .archive(headerOffset: offset, file: newFile)
            }
        }
        // Entries are found by path; one that was renamed while the file was written, by its position.
        var vanished = 0
        for written in snapshot.entries {
            guard case .zip(let then) = written.content, let offset = built.offsets[written.order] else { continue }
            var path = written.path
            if tree.entry(path)?.order != written.order {
                guard let moved = tree.path(atOrder: written.order) else {
                    // Removed (or replaced) while the file was written: the file holds it
                    // all the same. One that was in the old file was counted when it was
                    // removed; one that this write put there for the first time is counted now.
                    if !then.isInArchive { vanished += 1 }
                    continue
                }
                path = moved
            }
            // (The entry at the written one's position is that member, so it is a ZIP member.)
            tree.update(path) { entry in
                if case .zip(var record) = entry.content {
                    // Changed again meanwhile: the data is in the file, the newer header is not.
                    if record.hasSameHeader(as: then) { record.unwritten.formIntersection(.arriving) }
                    record.source = .archive(headerOffset: offset, file: newFile)
                    entry.content = .zip(record)
                }
            }
        }
        if snapshot.isComplete { writtenCount = snapshot.changeCount }
        if built.isRewrite { writtenRemovals = snapshot.removals }
        if vanished > 0 {
            // The next write takes them out again; it is due like any other change. (Taking
            // one out counted as a change, after the snapshot: that change is still waiting.)
            removals += vanished
            if let delay = environment.flushDelay { armTimer(after: idleDelay(delay)) }
        }
        pendingBytes -= min(pendingBytes, snapshot.pendingBytes)
        if fetchedCopy != nil { uploadPending = true }
    }

    /// Reads the archive again after another program changed it, and adds the members that
    /// exist only here to what it holds now; one whose name is taken there gets a name of
    /// its own. Returns true when changes to members of the old archive had to be given up.
    ///
    /// The file is opened and its directory read without the lock; the lock is taken to put
    /// the new directory in the old one's place, which is memory alone.
    private func rebase() throws -> Bool {
        let reopened: RandomAccessFile
        let listing: ZipListing
        // (Only a ZIP is changed, so only a ZIP is read again.)
        do {
            reopened = try RandomAccessFile(localURL)
            listing = try Self.readZip(reopened, environment: environment, control: nil)
            guard !listing.hasDuplicates else { throw ArchiveError.changedOutside(name) }
        } catch {
            throw ArchiveError.changedOutside(name)
        }
        lock.lock()
        defer { lock.unlock() }
        let fresh = tree.ordered.compactMap { entry -> (entry: ArchiveEntry, record: ZipRecord)? in
            guard case .zip(let record) = entry.content, !record.isInArchive else { return nil }
            return (entry, record)
        }
        let lost =
            removals != writtenRemovals
            || tree.contains { entry in
                if case .zip(let record) = entry.content { return record.isInArchive && !record.unwritten.isEmpty }
                return false
            }
        file = reopened
        signature = reopened.signature
        (tree, unlisted, hasDuplicates) = (listing.tree, listing.unlisted, false)
        (comment, directoryOffset, prefixEnd) = (listing.comment, listing.directoryOffset, listing.prefixEnd)
        (writtenCount, writtenRemovals, pendingBytes, transfers) = (changeCount, removals, 0, 0)
        loadCount += 1
        for (var entry, var record) in fresh {
            if entry.isDirectory {
                if let existing = tree.entry(entry.path), !existing.isImplicit { continue }
            } else if tree.entry(entry.path) != nil {
                let (folder, name) = (ArchiveTree.parent(of: entry.path), FileItem.split(entry.name))
                var number = 2
                repeat {
                    entry.path = ArchiveTree.join(
                        folder,
                        "\(name.base) (\(number))" + (name.ext.isEmpty ? "" : "." + name.ext)
                    )
                    number += 1
                } while tree.entry(entry.path) != nil
                record.setName(entry.path)
                entry.content = .zip(record)
            }
            pendingBytes = pendingBytes.plusClamped(record.compressedSize)
            put(entry)
        }
        if !fresh.isEmpty { changeCount += 1 }
        publish()
        return lost
    }

    /// Puts the changed copy back where the archive came from. The copy stays ahead of the
    /// original until that has worked.
    private func upload(cancellation: CancellationFlag?, progress: (Int64, Int64) -> Bool) throws {
        guard let fileSystems = environment.fileSystems() else { throw ArchiveError.readOnly(name) }
        let provider = try fileSystems.provider(for: archiveURL)
        let temporary = archiveURL.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        let local = locked { file }
        let flag = cancellation ?? CancellationFlag()
        let writer = try provider.write(temporary, cancellation: flag)
        // A write that waits on the server is ended by the request too.
        let tie = flag.interrupting(writer)
        defer { withExtendedLifetime(tie) {} }
        do {
            let source = FileRangeStream(local)
            let size = Int64(clamping: local.size)
            var sent: Int64 = 0
            while let block = try source.read(upToCount: 1 << 20) {
                try Self.check(cancellation)
                if !progress(sent, size) { throw ArchiveError.cancelled }
                try writer.write(block)
                sent += Int64(block.count)
            }
            try writer.close(attributes: FileAttributes())
            try provider.move(temporary, to: archiveURL, replacing: true, cancellation: flag)
        } catch {
            try? writer.close(attributes: FileAttributes())
            try? provider.remove(temporary)
            throw error
        }
        // When the server cannot say what it holds now, the next look at it sets the mark
        // (see `isCurrent`).
        let stamp = provider.item(at: archiveURL, cancellation: flag).map { ($0.size, $0.modified) }
        locked {
            remoteStamp = stamp
            uploadPending = false
        }
    }

    /// The last resort when changes cannot be written and the program is about to quit: the
    /// members that exist only in temporary files are written into an archive of their own,
    /// next to the archive or in the recovery folder. When that fails too (or `quickly`, when
    /// there is no time left to copy them), their compressed data is left on the disk instead
    /// of being cleared away with the temporary folder, with a list that says which file is
    /// which member. Members still under a job's temporary name are not saved: their job did
    /// not finish them, and its source is where it was.
    ///
    /// Waits for a write that is under way no longer than until `deadline`; then the data is kept as it is.
    func rescue(quickly: Bool = false, before deadline: Date = .distantFuture) -> RescueOutcome {
        let holdsGate = gate.lock(long: true, before: deadline)
        defer { if holdsGate { gate.unlock() } }
        let fresh = locked {
            tree.ordered.compactMap { entry -> (path: String, record: ZipRecord)? in
                guard case .zip(let record) = entry.content, !record.isInArchive, !entry.isDirectory,
                    !Self.isTransfer(entry)
                else { return nil }
                return (entry.path, record)
            }
        }
        guard !fresh.isEmpty else { return .nothingToSave }
        let base = ArchiveFormat.splitKnownExtension(name)?.base ?? FileItem.split(name).base
        let folders =
            (fetchedCopy == nil ? [localURL.deletingLastPathComponent()] : [])
            + (environment.recoveryFolder.map { [$0] } ?? [])
        for folder in folders where holdsGate && !quickly {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url = folder.appendingPathComponent("\(base) (unsaved changes).zip", isDirectory: false)
            var number = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(base) (unsaved changes \(number)).zip", isDirectory: false)
                number += 1
            }
            guard let output = try? OutputFile(creating: url) else { continue }
            do {
                let writer = ZipWriter(output, limits: environment.limits)
                for member in fresh { try writer.copyMember(member.record) }
                try writer.finish()
                try output.close(durably: true)
                return .saved(url)
            } catch {
                try? output.close()
                unlink(url.path)
            }
        }
        // Raw compressed data under made-up names is of little use without this list.
        var index =
            "Unsaved members of \(archiveURL.absoluteString)\nfile\tmember\tmethod (0 stored, 8 deflate, 99 AES)\tCRC-32\tsize\n"
        var kept: URL?
        for member in fresh {
            guard case .spool(let temporary) = member.record.source else { continue }
            temporary.keep()
            kept = kept ?? temporary.url.deletingLastPathComponent()
            index +=
                "\(temporary.url.lastPathComponent)\t\(member.path)\t\(member.record.method)\t\(String(format: "%08x", member.record.crc))"
                + "\t\(member.record.uncompressedSize)\n"
        }
        let folder = kept ?? environment.scratch.url
        environment.scratch.keep()
        let list = folder.appendingPathComponent("index-\(instance).txt", isDirectory: false)
        try? Data(index.utf8).write(to: list)
        return .kept(folder)
    }
}

extension ZipWriter {
    /// `copyMember`, ended early (with `ArchiveError.cancelled`) when the flag is set.
    func copyMember(_ record: ZipRecord, cancellation: CancellationFlag?) throws -> UInt64 {
        try copyMember(record) { if cancellation?.isCancelled == true { throw ArchiveError.cancelled } }
    }
}

/// Writes one new member of a ZIP: compresses into a temporary file as the data arrives.
/// The data is cut into pieces of one megabyte, and the pieces that have gathered are
/// compressed on all cores at once (see `ZipPacker` for why that gives one valid stream).
/// With a password the compressed bytes are encrypted (AES-256) as they are written.
/// Used by the one thread that copies the file.
///
/// Unchecked: used by one thread at a time, as `FileWriter` allows; `interrupt` touches only
/// `interruption`, which is safe from any thread.
private final class ZipMemberWriter: FileWriter, @unchecked Sendable {
    private let archive: OpenArchive
    private let path: String
    private let temporary: TemporaryFile
    private let output: OutputFile
    private let level: Int
    private let room: SpaceWatch
    private let encryptor: ZipAES.Encryptor?
    private var buffer = Data()
    private var crc: UInt32 = 0
    private var size: UInt64 = 0
    /// True until the writer has started: one that fails to start is given up by whoever made
    /// it, which hears of the failure and takes its count back.
    private var isClosed = true
    /// Set by `interrupt()`, from any thread.
    private let interruption = StreamInterrupt()
    private let window = ZipPacker.pieceSize * max(2, ProcessInfo.processInfo.activeProcessorCount)

    init(archive: OpenArchive, path: String, level: Int, password: String?, spool: URL, room: SpaceWatch) throws {
        self.archive = archive
        self.path = path
        self.level = level
        self.room = room
        encryptor = try password.map {
            try ZipAES.Encryptor(password: $0, method: level > 0 ? ZipRecord.methodDeflate : ZipRecord.methodStored)
        }
        output = try OutputFile(creating: spool)
        temporary = TemporaryFile(spool)
        if let encryptor { try output.write(encryptor.header) }
        isClosed = false
    }

    deinit {
        if !isClosed { try? archive.finishWrite(nil, path: path) }
    }

    func interrupt() {
        interruption.set()
    }

    private func put(_ data: Data) throws {
        try output.write(encryptor?.encrypt(data) ?? data)
    }

    func write(_ data: Data) throws {
        try interruption.check()
        guard room.allows(UInt64(data.count)) else { throw ArchiveError.noRoom(archive.name) }
        size += UInt64(data.count)
        guard level > 0 else {
            crc = CRC32.update(crc, data)
            try put(data)
            return
        }
        buffer.append(data)
        if buffer.count >= window { try drain(final: false) }
    }

    /// Compresses the whole pieces that have gathered; at the end also what is left.
    private func drain(final: Bool) throws {
        var pieces: [Data] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= ZipPacker.pieceSize || (final && offset < buffer.endIndex) {
            let end = min(offset + ZipPacker.pieceSize, buffer.endIndex)
            pieces.append(buffer.subdata(in: offset..<end))
            offset = end
        }
        buffer = Data(buffer[offset...])
        // The stream needs a piece that ends it, even an empty one.
        if final, pieces.isEmpty { pieces = [Data()] }
        let (level, last) = (self.level, pieces.count - 1)
        let packed = Parallel.map(Array(pieces.enumerated())) { index, piece in
            Result {
                (data: try Deflater.piece(piece, level: level, final: final && index == last), crc: CRC32.of(piece))
            }
        }
        for (piece, outcome) in zip(pieces, packed) {
            let result = try outcome.get()
            try interruption.check()
            crc = CRC32.combine(crc, result.crc, secondLength: piece.count)
            try put(result.data)
        }
    }

    func close(attributes: FileAttributes) throws {
        guard !isClosed else { return }
        isClosed = true
        do {
            try interruption.check()
            // An encrypted member says how it was compressed before its size is known, so
            // an empty one is a (valid, empty) compressed stream too.
            if level > 0, size > 0 || encryptor != nil { try drain(final: true) }
            if let encryptor { try output.write(encryptor.trailer()) }
            try output.close()
        } catch {
            try? archive.finishWrite(nil, path: path)
            throw error
        }
        var record = ZipRecord.new(
            name: path,
            isDirectory: false,
            modified: attributes.modified ?? Date(),
            permissions: attributes.permissions ?? 0o644
        )
        record.crc = crc
        record.uncompressedSize = size
        record.compressedSize = output.position
        record.method = level > 0 && size > 0 ? ZipRecord.methodDeflate : ZipRecord.methodStored
        record.source = output.position > 0 ? .spool(temporary) : .none
        if let encryptor { record.setAES(encryptor.field) }
        try archive.finishWrite(record, path: path)
    }
}

/// The optional parts of a GZIP header: the original file name and time.
struct GzipHeader {
    var name: String?
    var modified: Date?

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B else { return nil }
        let flags = bytes[3]
        let time = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        if time != 0 { modified = Date(timeIntervalSince1970: TimeInterval(time)) }
        var index = 10
        if flags & 4 != 0, bytes.count >= index + 2 { index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        if flags & 8 != 0, index < bytes.count, let end = bytes[index...].firstIndex(of: 0) {
            name =
                String(bytes: bytes[index..<end], encoding: .utf8)
                ?? String(bytes: bytes[index..<end], encoding: .isoLatin1)
        }
    }
}
