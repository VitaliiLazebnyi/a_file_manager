import AFMKernel
import Foundation

/// What archives need from their surroundings.
///
/// One object is shared by everything the plugin owns; its closures are set while the plugin
/// starts, and may be called from any thread. The settings are read and written as properties of
/// the environment (`environment.flushDelay`).
///
/// Unchecked: the settings, `options` and `isStopping` are guarded by `lock` (tests change
/// settings while archives are open); the rest is fixed in `init`.
@dynamicMemberLookup
internal final class ArchiveEnvironment: @unchecked Sendable {
    /// Runs `work` after `delay`, with the given priority, on some thread of its own.
    internal typealias Scheduler =
        @Sendable (_ delay: TimeInterval, _ priority: QualityOfService, _ work: @escaping @Sendable () -> Void) -> Void

    /// The settings of the archives, with the defaults the program uses; tests change them.
    internal struct Settings {
        /// The file systems of the program, for archives that lie on something other than the disk.
        internal var fileSystems: @Sendable () -> FileSystemRegistry? = { nil }
        /// Asks for the password of an archive; `retry` after a wrong one.
        ///
        /// Nil gives up.
        internal var askPassword: @Sendable (_ archiveName: String, _ retry: Bool) -> String? = { _, _ in nil }
        /// Tells the user that changes could not be written into an archive.
        ///
        /// Must not wait for the user: it is called on the thread that writes.
        internal var reportFailure: @Sendable (_ error: any Error, _ archiveName: String) -> Void = { _, _ in
            // Nobody is told until the plugin starts.
        }
        /// The directories whose contents changed behind the panels' backs.
        internal var contentsChanged: @Sendable (_ archive: URL) -> Void = { _ in
            // Nobody listens until the plugin starts.
        }

        /// Archives up to this size that cannot be read at any position (compressed TAR, 7z, …)
        /// are unpacked once into a temporary TAR, so that reading single members is fast.
        internal var materializeLimit: UInt64 = 256 << 20
        /// The temporary copy may not grow beyond this.
        internal var unpackedLimit: UInt64 = 4 << 30
        /// This much stays free on the volume of the temporary folder, whatever is unpacked or
        /// fetched into it: a copy that would eat into it is not made (or given up half-way).
        internal var scratchReserve: UInt64 = 2 << 30
        /// The temporary copies of the archives that are open but not in use may take this much
        /// together; beyond it the least recently used are let go.
        internal var scratchBudget: UInt64 = 8 << 30
        /// An archive may hold this many entries; one that lists more is refused with a clear
        /// message instead of filling the memory.
        ///
        /// An entry of a ZIP costs about 400 bytes (measured: 396 with a 45-byte path and the extra
        /// fields the `zip` program writes), so the directory of the largest archive that is opened
        /// takes about 800 MB.
        internal var maxEntries = 2_000_000
        /// Archives may lie inside archives this deep.
        internal var maxNesting = 6
        /// How long after the last change pending changes are written into a ZIP; nil never
        /// writes by itself.
        internal var flushDelay: TimeInterval? = 1
        /// How long after a failed write the next attempt is made; doubled with every further
        /// failure, up to `maxRetryDelay`.
        ///
        /// A change to the archive brings the next attempt at once.
        internal var retryDelay: TimeInterval = 30
        /// The longest pause between two attempts to write, however often they failed.
        internal var maxRetryDelay: TimeInterval = 3_600
        /// The delayed write runs with low priority.
        ///
        /// When all cores are busy that may not run for minutes; this long after it was due it runs
        /// with the priority of the user's own work.
        internal var escalationDelay: TimeInterval = 5
        /// Runs `work` after `delay` on a thread of its own with the given priority.
        ///
        /// The delayed writes are started this way and not on the system's shared queues: those
        /// have a limited number of threads, and when all of them are busy (or blocked) a write
        /// that is due would wait behind them for as long as that lasts. The clock itself is a
        /// queue of the plugin's own, on which nothing ever runs but the starting of these threads.
        /// (Tests put a clock of their own here.).
        internal var schedule: Scheduler = { delay, priority, work in
            ArchiveEnvironment.later(delay, priority, name: "Archive write", work)
        }
        /// How long a reader of an archive that can only be read front to back waits behind
        /// the member it delivered for someone to read on; then it is closed.
        internal var readerParkTime: TimeInterval = 10
        /// Runs the housekeeping (closing the readers nobody came back for) as `schedule` runs
        /// the delayed writes.
        ///
        /// (Tests put a clock of their own here.).
        internal var housekeeping: Scheduler = { delay, priority, work in
            ArchiveEnvironment.later(delay, priority, name: "Archive readers", work)
        }
        /// A file that a job has just given its final name inside a ZIP is written into the
        /// archive file before the rename returns, when that means writing no more than this
        /// many bytes besides the file itself (or no more than is waiting anyway).
        ///
        /// Zero leaves every write to the delay.
        internal var immediateWriteLimit: UInt64 = 256 << 10
        /// Off, archives are never cloned and every change writes the whole archive anew, as on
        /// a file system that cannot clone (tests).
        internal var clonesArchives = true
        /// Whether `needed` bytes can be written into `folder`.
        internal var hasRoom: @Sendable (_ needed: UInt64, _ folder: URL) -> Bool = { Volume.hasRoom(for: $0, at: $1) }
        /// The volume a path lies on, as a number (tests: an archive "on another disk").
        internal var volume: @Sendable (_ path: String) -> dev_t? = { Volume.device(of: $0) }
        /// Where new members are saved when they can be written neither into their archive nor
        /// next to it; nil keeps them in the temporary folder.
        internal var recoveryFolder: URL?
        /// After the user declined to give a password (or gave three wrong ones), members of that
        /// archive fail without a question for this long: a job that reads a thousand encrypted
        /// members asks once, not a thousand times.
        internal var passwordRefusalMemory: TimeInterval = 0
        /// How long quitting waits for the changes to be written before it gives up, keeps the
        /// new members in the temporary folder and says so.
        internal var quitTimeout: TimeInterval = 120
        /// The sizes and counts beyond which a ZIP is written with its 64-bit fields.
        internal var limits = ZipLimits.standard
        /// Called by a write when the new archive file is complete and before it takes the old
        /// one's place, on the writing thread (tests: what changes while a write is under way).
        internal var whileWriting: (@Sendable () -> Void)?
    }

    private static let clock = DispatchQueue(label: "afm.archives.clock", qos: .userInitiated)

    /// The temporary folder of the plugin: unpacked copies, fetched archives, new members.
    internal let scratch = ScratchFolder(in: FileManager.default.temporaryDirectory)
    /// Set when quitting has waited long enough: ends the writes that are still under way.
    internal let quitting = CancellationFlag()
    private let lock = NSLock()
    private var settings = Settings()
    private var current = ArchiveOptions()
    private var stopping = false

    /// The options of the Packer page, as last copied from the settings on the main thread.
    internal var options: ArchiveOptions {
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
    internal var isStopping: Bool {
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

    /// The same clock as the delayed writes' (see `Settings.schedule`) for the plugin's
    /// housekeeping (closing readers nobody came back for), which is not the delayed writes'
    /// business and not a test clock's either.
    internal static func later(
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

    /// A setting, read or changed under the lock (`environment.flushDelay`).
    internal subscript<Value>(dynamicMember keyPath: WritableKeyPath<Settings, Value>) -> Value {
        get { lock.withLock { settings[keyPath: keyPath] } }
        set { lock.withLock { settings[keyPath: keyPath] = newValue } }
    }

    deinit {
        // Nothing to release.
    }
}
