import AFMKernel
import Foundation

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
internal final class OpenArchive: @unchecked Sendable {
    /// The directory of a ZIP file as the archive keeps it.
    internal struct ZipListing {
        /// The members that have a usable name.
        internal var tree = ArchiveTree()
        /// The members without a usable name: not shown, and kept in the archive.
        internal var unlisted: [ZipRecord] = []
        /// Whether the archive lists a name twice.
        internal var hasDuplicates = false
        /// The comment at the end of the archive.
        internal var comment = Data()
        /// Where the directory starts.
        internal var directoryOffset: UInt64 = 0
        /// Where the first member starts.
        internal var prefixEnd: UInt64 = 0
    }

    /// A reader of a stream archive that stands behind a member, kept for the members after it.
    internal struct ParkedReader {
        /// The reader, positioned after the member it delivered.
        internal let reader: TarReader
        /// The number of the member it reads next.
        internal let next: Int
        /// When it was parked; one that waited longer than `readerParkTime` is closed.
        internal let since: DispatchTime
    }

    /// What is known of whether the archive's file system clones files.
    internal enum Cloning {
        /// Clones are made.
        case supported
        /// It was not tried yet, or the try said neither.
        case unknown
        /// The file system makes no clones (or archives are never cloned).
        case unsupported
    }

    /// The archive file as its own file system names it.
    internal let archiveURL: URL
    /// The name of the archive file, as the user is told of it.
    internal let name: String
    /// The mark the system puts on files from the internet, when the archive carries it:
    /// what is unpacked from the archive gets it too.
    internal let quarantine: Data?
    /// What the archive needs from its surroundings; shared with the plugin's other archives.
    internal let environment: ArchiveEnvironment
    /// The archive on the local disk: the file itself (where it really lies, when it was
    /// reached through a symbolic link), or a copy fetched from elsewhere.
    internal let localURL: URL
    /// The copy of an archive that lies on another file system (a server); nil for one on the disk.
    internal let fetchedCopy: TemporaryFile?
    /// Guards the directory and the state of the changes; held for work in memory only.
    internal let lock = NSLock()
    /// Held while the archive file is written or sent; taken before `lock`, never inside it.
    internal let gate = FlushGate()
    /// Guards only `publishedEditable`.
    ///
    /// Nothing is done while it is held.
    internal let stateLock = NSLock()
    /// Whether the directory allows changes, as `capabilities` reads it (under `stateLock`).
    internal var publishedEditable = false
    /// Names this instance's temporary files next to the archive.
    internal let instance = UUID().uuidString

    /// The archive file that was read; replaced by every write (under `lock`, by the gate's holder).
    internal var file: RandomAccessFile
    /// The format, found from the first bytes when the archive was opened.
    internal let format: ArchiveFormat
    /// The directory: every entry by its path.
    internal var tree = ArchiveTree()
    /// A stream archive unpacked into a temporary TAR (or a compressed file into its content).
    internal var unpacked: (file: RandomAccessFile, temporary: TemporaryFile)?
    /// Starts reading the archive as a TAR stream, for formats without random access.
    internal var memberSource: ((StreamInterrupt?) throws -> any ByteStream)?
    /// Readers of such a stream that stand behind a member and can go on from there.
    internal var parked: [ParkedReader] = []
    /// Whether the sweep that closes the readers nobody came back for is due.
    internal var reaperArmed = false
    /// How often a stream archive was read from its beginning for a member.
    internal var starts = 0
    /// The state of the archive file when it was read or last written.
    internal var signature: FileSignature
    /// The size and date of an archive on a server when it was fetched or last sent; nil when
    /// the server could not say.
    internal var remoteStamp: (size: Int64, modified: Date)?
    /// When the server was last asked whether the archive is still the one that was fetched.
    internal var lastRemoteCheck = Date.distantPast
    /// The comment at the end of a ZIP.
    internal var comment = Data()

    // Passwords.
    /// The passwords that opened a member, the latest first.
    internal var passwords: [String] = []
    /// One question at a time, however many threads read encrypted members.
    internal let passwordGate = NSLock()
    /// How many operations of the user (`withPasswordScope`) are under way.
    internal var passwordScopes = 0
    /// Whether the user declined to give a password in the operations under way.
    internal var refusedInScope = false
    /// Until then members fail without a question (`passwordRefusalMemory`).
    internal var refusedUntil = Date.distantPast

    // The ZIP file as it lies on the disk.
    /// Where its directory starts: the members lie in front of it.
    internal var directoryOffset: UInt64 = 0
    /// Where the first member starts; what stands before it (the program of a self-extracting
    /// archive) is kept.
    internal var prefixEnd: UInt64 = 0
    /// Entries without a usable name.
    ///
    /// They are not shown, and they stay in the archive.
    internal var unlisted: [ZipRecord] = []
    /// An archive that lists a name twice shows one of the two; it is not changed.
    internal var hasDuplicates = false

    // Changes waiting to be written.
    /// Counted up with every change of the directory.
    internal var changeCount = 0
    /// The `changeCount` the archive file holds: when the two differ, changes are waiting.
    internal var writtenCount = 0
    /// Counted up when something was removed that lies in the archive file: then the file is
    /// written anew, without it.
    internal var removals = 0
    /// The `removals` the archive file holds.
    internal var writtenRemovals = 0
    /// The compressed bytes of the members that are not in the archive file yet.
    internal var pendingBytes: UInt64 = 0
    /// Members that lie here under a job's temporary name, on their way to their real one.
    internal var transfers = 0
    /// (An archive fetched from elsewhere.)
    ///
    /// The local copy is ahead of the original.
    internal var uploadPending = false
    /// The writers of new members that are open.
    internal var openWriters = 0
    /// Set when the store let this archive go; see the class comment.
    internal var retired = false
    /// Counted up whenever the directory was read anew from the file (`rebase`).
    internal var loadCount = 0
    /// What writes at a rename have cost since the delay (or a commit) last wrote: see `move`.
    internal var immediateSpent: UInt64 = 0
    /// The compressed bytes of the members that came in since then: see `move`.
    internal var arrivedBytes: UInt64 = 0
    /// When the directory last changed; the timer writes once changes have paused.
    internal var lastChange = DispatchTime.now()
    /// When the armed timer is due; nil when none is armed.
    ///
    /// A timer that was overtaken by an earlier one knows it by its number.
    internal var timerDeadline: DispatchTime?
    /// The number of the timer armed last.
    internal var timerNumber = 0
    /// Whether the panels are to hear of the archive's new size and date when the timer fires.
    internal var notifyPending = false
    /// Whether the file system clones files; unknown until it was tried.
    internal var canClone = Cloning.unknown
    /// Whether cloning was tried (`probeCloning`).
    internal var cloneProbed = false
    /// How long the last write that copied the whole archive took (a guess until one did).
    internal var lastRewriteDuration: TimeInterval = 0
    /// The failure the user was told of last; the same one is not told again.
    internal var reportedFailure: String?
    /// How many writes have failed in a row.
    internal var failures = 0
    /// Where new members wait: nil until one was written.
    ///
    /// See `newSpool()`.
    internal var spoolFolder: URL?
    /// Whether `spoolFolder` is a folder of this archive's own next to it, not the temporary folder.
    internal var spoolIsOutside = false
    /// Whether the name of the new archive file a write builds was noted for clearing away.
    internal var notedBuildFile = false

    /// Every entry, in archive order.
    internal var entries: [ArchiveEntry] {
        locked { tree.ordered }
    }

    /// Whether any member is encrypted.
    internal var hasEncryptedMembers: Bool {
        locked { tree.contains(where: \.isEncrypted) }
    }

    /// The date of the archive file itself.
    internal var modified: Date {
        locked { signature.modified }
    }

    /// How often a stream archive was read from its beginning for a member.
    internal var streamStarts: Int {
        locked { starts }
    }

    /// The room this archive takes in the temporary folder: its unpacked copy, and the copy
    /// of an archive that was fetched from elsewhere.
    internal var scratchBytes: UInt64 {
        locked { (unpacked?.file.size ?? 0).plusClamped(fetchedCopy == nil ? 0 : file.size) }
    }

    /// True when changes are waiting to be written; called with the lock held.
    internal var hasPendingLocked: Bool { changeCount != writtenCount || uploadPending }

    /// Changes waiting, a member being written, or one on its way under a temporary name.
    internal var isBusyLocked: Bool { hasPendingLocked || openWriters > 0 || transfers > 0 }

    /// Whether members can be read independently of each other, on several threads.
    internal var allowsParallelReads: Bool {
        locked { memberSource == nil || unpacked != nil }
    }

    /// Whether the archive is one compressed stream (a compressed TAR, or another format read
    /// through the system's tool), whose checks are made only by reading it to its end.
    internal var isOneStream: Bool {
        locked { memberSource != nil }
    }

    /// True while members fail without a question after a refusal; called with the lock held.
    internal var isRefusedLocked: Bool {
        (passwordScopes > 0 && refusedInScope) || Date() < refusedUntil
    }

    /// What can be done inside this archive, from what is known without touching the disk:
    /// members can be added, renamed and removed in a ZIP that lists no name twice, and that
    /// lies where the file system can be written to.
    ///
    /// Writes are kept back (`.deferredWrites`): whoever is about to destroy the only other copy of
    /// what it wrote calls `commit` first. Answers at once, on any thread: it waits for no lock
    /// that is held while a file is read, written or asked about.
    internal var capabilities: FileSystemCapabilities {
        stateLock.lock()
        let editable = publishedEditable
        stateLock.unlock()
        guard editable else {
            return []
        }
        if fetchedCopy != nil, environment.fileSystems()?.capabilities(for: archiveURL).contains(.write) != true {
            return []
        }
        return [.write, .deferredWrites]
    }

    /// True when the next write has to copy the whole archive (or send it to a server).
    internal var writesWholeArchive: Bool {
        removals != writtenRemovals || fetchedCopy != nil || clones() == .unsupported
    }

    /// True when changes are waiting to be written.
    internal var hasPendingChanges: Bool {
        locked { hasPendingLocked }
    }

    /// True while the archive may not be let go: changes are waiting, a member is being
    /// written, or one is on its way under a temporary name.
    internal var isBusy: Bool {
        locked { isBusyLocked }
    }

    /// With a `cancellation`, opening ends with `ArchiveError.cancelled` soon after it is set:
    /// the child processes started for it are stopped and its temporary files are removed.
    internal init(
        archiveURL: URL,
        localURL: URL,
        fetchedCopy: TemporaryFile?,
        remoteStamp: (size: Int64, modified: Date)?,
        quarantine: Data?,
        cancellation: CancellationFlag?,
        environment: ArchiveEnvironment
    ) throws {
        self.archiveURL = archiveURL
        self.localURL = localURL
        self.fetchedCopy = fetchedCopy
        self.remoteStamp = remoteStamp
        self.environment = environment
        self.quarantine = quarantine ?? (fetchedCopy == nil ? Quarantine.read(localURL.path) : nil)
        name = archiveURL.lastPathComponent
        let opened = try RandomAccessFile(localURL, shownAs: nil)
        file = opened
        // Of the file that was opened, not of whatever lies at the path a moment later.
        signature = opened.signature
        // A first guess at what copying the archive costs, until one was timed.
        lastRewriteDuration = Double(opened.size) / 500_000_000
        let head = try opened.read(at: 0, count: 512)
        format = ArchiveFormat.detect(head: head, name: name) { codec in
            // A stream that cannot be started or read holds no TAR that could be listed.
            let first = try? { () throws -> Data in
                let stream = try codec.decompressing(opened, control: nil)
                defer { stream.close() }
                return try stream.readFully(TarHeader.blockSize)
            }()
            return TarHeader.looksLikeHeader(first ?? Data())
        }
        let control = StreamInterrupt()
        let following = control.following(cancellation)
        try withExtendedLifetime(following) {
            try load(control: control)
            try control.check()
        }
        publish()
    }

    deinit {
        for waiting in parked { waiting.reader.close() }
        // The members that waited here go with the directory; then their folder is empty.
        tree = ArchiveTree()
        if spoolIsOutside, let spoolFolder { rmdir(spoolFolder.path) }
    }
}
