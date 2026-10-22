public import AFMKernel
import AppKit
public import Foundation

/// The file system of the Mac itself (`file:` URLs).
///
/// The system calls it uses are safe to make from several threads at once; the little it remembers
/// (the list of places, what it learned about volumes and kinds of folders, the locked copies it
/// made) is guarded by locks.
///
/// Unchecked: every table is guarded by the lock named beside it (`packageLock`,
/// `lockedLock`, `placesLock`, `volumeLock`, `spareLock`); `mountObservers` is set in `init`
/// and read in `deinit`; the default file manager may be used from any thread.
public final class LocalFileSystem: FileSystemProvider, @unchecked Sendable {
    /// What a bulk read tells about one entry, before it becomes an item.
    internal struct Entry {
        /// The attributes asked for: name, kind and date of change.
        internal static let (wantName, wantType, wantModified) = (
            attrgroup_t(ATTR_CMN_NAME), attrgroup_t(ATTR_CMN_OBJTYPE), attrgroup_t(ATTR_CMN_MODTIME)
        )
        /// The attributes asked for: rights, flags and size.
        internal static let (wantMode, wantFlags, wantSize) = (
            attrgroup_t(ATTR_CMN_ACCESSMASK), attrgroup_t(ATTR_CMN_FLAGS), attrgroup_t(ATTR_FILE_DATALENGTH)
        )
        /// The error of an entry the system could not read.
        internal static let wantError = attrgroup_t(ATTR_CMN_ERROR)

        /// The entry's name in its folder.
        internal var name = ""
        /// The kind of node (`VREG`, `VDIR`, `VLNK` …).
        internal var type: UInt32 = 0
        /// The date of last change.
        internal var modified = Date(timeIntervalSince1970: 0)
        /// The rights and the kind bits.
        internal var mode: UInt32 = 0
        /// The flags (hidden, locked …).
        internal var flags: UInt32 = 0
        /// The size of the data, for a file.
        internal var size: Int64 = 0
        /// The system could not read the entry's attributes; they are asked for one by one.
        internal var failed = false
        /// The name is not valid UTF-8 (a volume that allows it: NFS, some FUSE).
        ///
        /// It was repaired for display, so a location made of it names no file; the entry is shown
        /// but not opened.
        internal var isNameRepaired = false

        /// A name with a dot first, or the hidden flag.
        internal var isHidden: Bool { name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0 }

        /// One entry of a bulk read, and its length: the length, which attributes follow, then
        /// those attributes in the order of their bits (an error, if any, comes first).
        ///
        /// Fields are packed to four bytes, hence the unaligned loads. What was not asked for, or
        /// not answered, keeps its default.
        @inline(__always)
        internal static func read(at entry: UnsafeRawPointer) -> (entry: Self, length: Int) {
            let length = Int(entry.loadUnaligned(as: UInt32.self))
            var field = entry + MemoryLayout<UInt32>.size
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            var read = Self()
            if returned.commonattr & wantError != 0 {
                read.failed = field.loadUnaligned(as: UInt32.self) != 0
                field += MemoryLayout<UInt32>.size
            }
            if returned.commonattr & wantName != 0 {
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let bytes = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                // A name that is not UTF-8 is shown repaired.
                let name = String(validatingCString: bytes)
                read.name = name ?? String(cString: bytes)
                read.isNameRepaired = name == nil
                field += MemoryLayout<attrreference_t>.size
            }
            if returned.commonattr & wantType != 0 {
                read.type = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }
            if returned.commonattr & wantModified != 0 {
                let time = field.loadUnaligned(as: timespec.self)
                read.modified = Date(
                    timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
                )
                field += MemoryLayout<timespec>.size
            }
            if returned.commonattr & wantMode != 0 {
                read.mode = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }
            if returned.commonattr & wantFlags != 0 {
                read.flags = field.loadUnaligned(as: UInt32.self)
                field += MemoryLayout<UInt32>.size
            }
            if returned.fileattr & wantSize != 0 {
                read.size = field.loadUnaligned(as: Int64.self)
            }
            return (read, length)
        }
    }

    /// Reads through the descriptor with `read(2)`, into a block that is the caller's own: no
    /// object of the system's is made per read, so nothing piles up on a long-lived thread.
    ///
    /// Unchecked: used by one thread at a time, as `FileReader` allows; `interrupt` touches
    /// only `interruption`, which is safe from any thread.
    private final class Reader: FileReader, @unchecked Sendable {
        private var descriptor: Int32
        private let url: URL
        private let probes: LocalProbes
        private let interruption = Interruption()

        init(_ descriptor: Int32, url: URL, probes: LocalProbes) {
            (self.descriptor, self.url, self.probes) = (descriptor, url, probes)
        }

        func read(upToCount count: Int) throws -> Data? {
            guard descriptor >= 0 else { throw LocalFileSystem.posixError(EBADF, url) }
            guard count > 0 else {
                return nil
            }
            var data = Data(count: count)
            var code: Int32 = 0
            let descriptor = self.descriptor
            let got = try data.withUnsafeMutableBytes { buffer in
                try interruption.run { () -> Int in
                    let got = probes.system("read", url.path) { Darwin.read(descriptor, buffer.baseAddress, count) }
                    if got < 0 { code = errno }
                    return got
                }
            }
            guard got >= 0 else { throw LocalFileSystem.posixError(code, url) }
            guard got > 0 else {
                return nil
            }
            if got < count { data.removeSubrange(got...) }
            return data
        }

        func seek(to offset: UInt64) throws {
            guard descriptor >= 0 else { throw LocalFileSystem.posixError(EBADF, url) }
            guard let position = off_t(exactly: offset) else { throw LocalFileSystem.posixError(EINVAL, url) }
            // Setting the position of a regular file (all a reader reads) does not fail.
            lseek(descriptor, position, SEEK_SET)
        }

        func close() {
            guard descriptor >= 0 else {
                return
            }
            Darwin.close(descriptor)
            descriptor = -1
        }

        func interrupt() { interruption.interrupt() }

        deinit { close() }
    }

    /// Writes through the descriptor it was made with, and gives the file its date and its
    /// rights through the same descriptor before closing it: nothing that happens to the name
    /// meanwhile (a link put in its place) can redirect that.
    ///
    /// Unchecked: used by one thread at a time, as `FileWriter` allows; `interrupt` touches
    /// only `interruption`, which is safe from any thread.
    private final class Writer: FileWriter, @unchecked Sendable {
        private var descriptor: Int32
        private let url: URL
        /// What a new file is given when the caller names no rights; nil for a file that was
        /// there before (its rights stay as they are).
        private let defaultPermissions: mode_t?
        private let probes: LocalProbes
        private let interruption = Interruption()

        init(_ descriptor: Int32, url: URL, defaultPermissions: mode_t?, probes: LocalProbes) {
            (self.descriptor, self.url, self.defaultPermissions, self.probes) = (
                descriptor, url, defaultPermissions, probes
            )
        }

        func write(_ data: Data) throws {
            guard descriptor >= 0 else { throw LocalFileSystem.posixError(EBADF, url) }
            let descriptor = self.descriptor
            try data.withUnsafeBytes { buffer in
                var done = 0
                while done < buffer.count {
                    var code: Int32 = 0
                    let wrote = try interruption.run { () -> Int in
                        let wrote = probes.system("write", url.path) {
                            Darwin.write(descriptor, buffer.baseAddress! + done, buffer.count - done)
                        }
                        if wrote < 0 { code = errno }
                        return wrote
                    }
                    guard wrote >= 0 else { throw LocalFileSystem.posixError(code, url) }
                    done += wrote
                }
            }
        }

        func close(attributes: FileAttributes) throws {
            guard descriptor >= 0 else {
                return
            }
            var failure: any Error?
            if let modified = attributes.modified {
                let seconds = modified.timeIntervalSince1970.rounded(.down)
                let nanoseconds = ((modified.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)
                // The time of access stays as it is.
                var times = [
                    timespec(tv_sec: 0, tv_nsec: Int((1 << 30) - 2)),
                    timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
                ]
                if probes.system("futimens", url.path, { futimens(descriptor, &times) }) != 0 {
                    failure = LocalFileSystem.posixError(errno, url)
                }
            }
            if let mode = attributes.permissions.map({ mode_t($0) & 0o7777 }) ?? defaultPermissions {
                if probes.system("fchmod", url.path, { fchmod(descriptor, mode) }) != 0, failure == nil {
                    failure = LocalFileSystem.posixError(errno, url)
                }
            }
            let result = probes.system("close", url.path) { Darwin.close(descriptor) }
            descriptor = -1
            if result != 0, failure == nil { failure = LocalFileSystem.posixError(errno, url) }
            if let failure { throw failure }
        }

        func interrupt() { interruption.interrupt() }

        deinit {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
    }

    /// Hands the progress of a copy to the caller's closure for as long as the caller is
    /// there: a copy that was left behind finds nobody to report to, and stops.
    ///
    /// Unchecked: `report` is guarded by `lock`. The caller's closure is called on another
    /// thread only while the caller waits for the copy, and never once `detach` has returned.
    internal final class CopyReport: @unchecked Sendable {
        private let lock = NSLock()
        private var report: ((Int64) -> Bool)?

        /// Reports to `report` until `detach`.
        internal init(_ report: @escaping (Int64) -> Bool) { self.report = report }

        /// False when the copy is to stop.
        internal func callAsFunction(_ copied: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return report?(copied) ?? false
        }

        /// The caller is leaving; returns once a report under way is over.
        internal func detach() {
            lock.lock()
            report = nil
            lock.unlock()
        }
    }

    /// One question to a volume that is under way, and everybody who waits for its answer.
    ///
    /// Unchecked: `info` and `isOver` are guarded by `condition`, `wasAnsweredFromMemory` by
    /// the file system's `volumeLock`.
    private final class VolumeQuestion: @unchecked Sendable {
        enum Outcome {
            case answered(VolumeInfo?)
            case cancelled
            case late
        }

        let asked = DispatchTime.now().uptimeNanoseconds
        /// Somebody was answered from memory because this took too long.
        ///
        /// Guarded by the file system's `volumeLock`.
        var wasAnsweredFromMemory = false
        private let condition = NSCondition()
        private var info: VolumeInfo?
        private var isOver = false

        func finish(_ info: VolumeInfo?) {
            condition.lock()
            (self.info, isOver) = (info, true)
            condition.broadcast()
            condition.unlock()
        }

        func wait(until deadline: UInt64, _ cancellation: CancellationFlag?) -> Outcome {
            let registration = cancellation?
                .onCancel { [condition] in
                    condition.lock()
                    condition.broadcast()
                    condition.unlock()
                }
            defer { withExtendedLifetime(registration) {} }
            condition.lock()
            defer { condition.unlock() }
            while cancellation?.isCancelled != true, !isOver {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    return .late
                }
                _ = condition.wait(until: Date(timeIntervalSinceNow: TimeInterval(deadline - now) / 1_000_000_000))
            }
            // A caller that has cancelled is not given the answer, even one that came in time.
            return cancellation?.isCancelled == true ? .cancelled : .answered(info)
        }
    }

    /// The rights a new file gets when none are given: what `open` would have made with 0666,
    /// less the umask, which is read once (it can only be read by setting it).
    private static let defaultFileMode: mode_t = {
        let mask = umask(0o022)
        umask(mask)
        return 0o644 & ~mask
    }()

    /// The flags that keep a file from being renamed or deleted: "Locked" in the Finder.
    private static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    /// A temporary that was never finished is forgotten after this long.
    private static let lockedCopyLifetime: UInt64 = 6 * 3_600 * 1_000_000_000
    private static let lockedCopyLimit = 4_096

    private static let quarantineName = "com.apple.quarantine"

    /// Posted on the main thread when the list of places was read again and is not what
    /// `places()` last answered.
    ///
    /// The object is the file system.
    public static let placesDidChange = Notification.Name("AFMPlacesDidChange")
    /// How old a measurement may be before the next question has it taken again.
    internal static let spareSpaceAge: UInt64 = 3_000_000_000
    /// A measurement that has taken this long is taken for lost (the disk does not answer).
    internal static let spareSpaceLoss: UInt64 = 30_000_000_000

    public let scheme = "file"
    public let capabilities: FileSystemCapabilities = [.write, .trash, .append]
    private let fm = FileManager.default
    /// Nil everywhere unless a test stands in for the system (`LocalProbes`).
    internal let probes: LocalProbes

    /// Guards `packageExtensions`.
    internal let packageLock = NSLock()
    /// Lowercase extension → whether folders with it are packages, and when that was learned.
    ///
    /// Guarded by `packageLock`.
    internal var packageExtensions: [String: (isPackage: Bool, learned: UInt64)] = [:]
    /// Guards `lockedCopies`.
    internal let lockedLock = NSLock()
    /// Path → file of the locked copies `copy` has made under a temporary name and nobody has
    /// renamed or removed yet, and when.
    ///
    /// These are the only ones this file system takes the lock off for the moment of a rename or
    /// removal: the caller is about to give them their real names. A copy that kept its name is the
    /// user's file like the one it was copied from, and stays as locked as that. Guarded by
    /// `lockedLock`.
    internal var lockedCopies: [String: (device: dev_t, inode: ino_t, made: UInt64)] = [:]

    private var mountObservers: [any NSObjectProtocol] = []
    /// Guards everything below.
    private let placesLock = NSLock()
    private var knownPlaces: [Place]
    /// When the places were last read (0: not yet), and whether they are being read now or
    /// have to be read once more after that.
    private var placesRead: UInt64 = 0
    private var isReadingPlaces = false
    private var placesChangedMeanwhile = false
    /// Which reading is the current one: a reading that has taken too long (a mount that does
    /// not answer) is given up, and whatever it finds later is not used.
    ///
    /// The reading goes on in its thread until the system lets it go; no new one is started while
    /// two are stuck.
    private var placesGeneration = 0
    private var abandonedReads = 0

    /// Readings of the places that were given up and have not come back.
    internal var abandonedReadings: Int { placesLock.withLock { abandonedReads } }

    /// Volumes whose questions have not been answered yet: asked about once, not again and
    /// again, while a share that does not answer holds a thread.
    private let volumesAsking = Locked(Set<String>())

    private let volumeLock = NSLock()
    /// The question to each mount point that has not come back, and the last answer for each.
    private var volumeQuestions: [String: VolumeQuestion] = [:]
    private var lastVolumes: [String: VolumeInfo] = [:]

    internal let spareLock = NSLock()
    /// Mount point → what the system would free on demand there (the free space it reports
    /// for important uses, less the space that is plainly free), when that was measured, and
    /// of which volume (a different one mounted at the same place starts afresh).
    ///
    /// Nil where the system has no such figure. Guarded by `spareLock`.
    internal var spareSpace: [String: (bytes: Int64?, measured: UInt64, isMeasuring: Bool, volume: fsid_t)] = [:]

    public convenience init() {
        self.init(probes: LocalProbes())
    }

    /// Tests stand in for the system with `probes`.
    internal init(probes: LocalProbes) {
        self.probes = probes
        knownPlaces = Self.fixedPlaces(home: probes.home ?? FileManager.default.homeDirectoryForCurrentUser)
        // Disks that come and go change the list of places; it is read again behind the scenes.
        let workspace = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        mountObservers = names.map { name in
            workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refreshPlaces() }
        }
        _ = Self.defaultFileMode
        refreshPlaces()
    }

    /// The Finder's bundle bit of a folder; nil when it cannot be read.
    private static func hasBundleBit(_ path: String) -> Bool? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO)
        // The answer: its length, then the 32 bytes of Finder information. For a folder the
        // flags are the two bytes after the window rectangle, high byte first.
        var reply = [UInt8](repeating: 0, count: 36)
        guard getattrlist(path, &request, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            return nil
        }
        let flags = UInt16(reply[12]) << 8 | UInt16(reply[13])
        return flags & 0x2000 != 0
    }

    /// The name an item has in its folder, byte for byte as it is stored (a volume that ignores
    /// case or the form of accents answers to other spellings too; this is the one it keeps).
    internal static func storedName(of url: URL) -> [UInt8]? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        var reply = [UInt8](
            repeating: 0,
            count: 4 + MemoryLayout<attribute_set_t>.size + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 4 + 8
        )
        guard getattrlist(url.path, &request, &reply, reply.count, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            return nil
        }
        return reply.withUnsafeBytes { raw in
            let at = 4 + MemoryLayout<attribute_set_t>.size
            let reference = raw.loadUnaligned(fromByteOffset: at, as: attrreference_t.self)
            // Kept inside the reply whatever the system says; its last bytes are always zero.
            let start = min(max(at + Int(reference.attr_dataoffset), 0), raw.count - 1)
            let bytes = raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: CChar.self)
            return Array(
                UnsafeBufferPointer(
                    start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self),
                    count: strlen(bytes)
                )
            )
        }
    }

    /// Whether `url` is named like the temporary files the callers of `copy` use for a file
    /// that is not complete yet: a dot, and `.tmp` or the `afm-` of the program's own.
    internal static func isTemporaryName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && (name.hasSuffix(".tmp") || name.contains(".afm-"))
    }

    internal static func posixError(_ code: Int32, _ url: URL) -> any Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code)) + ": " + url.path]
        )
    }

    /// The places that are known without asking a disk.
    private static func fixedPlaces(home: URL) -> [Place] {
        [Place(name: "Home", url: home, kind: .home)]
            + ["Desktop", "Documents", "Downloads"]
            .map {
                Place(name: $0, url: home.appending(name: $0), kind: .folder)
            }
            + [
                Place(
                    name: "Applications",
                    url: URL(fileURLWithPath: "/Applications", isDirectory: true),
                    kind: .folder
                )
            ]
    }

    /// Reads the places from the system.
    ///
    /// Each volume is asked about on its own thread and waited for for a moment only, so that one
    /// that does not answer (a share that went away) shows with what was known of it, or its folder
    /// name, and holds up none of the others.
    internal static func readPlaces(previous: [Place], _ probes: LocalProbes, asking volumesAsking: Locked<Set<String>>)
        -> [Place]
    {
        let fm = FileManager.default
        let home = probes.home ?? fm.homeDirectoryForCurrentUser
        var places = [Place(name: "Home", url: home, kind: .home)]
        places += ["Desktop", "Documents", "Downloads"]
            .map {
                Place(name: $0, url: home.appending(name: $0), kind: .folder)
            }
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: cloud.path) { places.append(Place(name: "iCloud Drive", url: cloud, kind: .folder)) }
        places.append(
            Place(name: "Applications", url: URL(fileURLWithPath: "/Applications", isDirectory: true), kind: .folder)
        )
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsRootFileSystemKey
        ]
        // (The system always answers with a list; none would be no volumes.)
        let volumes = [fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])]
            .compactMap(\.self).joined()
        /// All state is guarded by `lock`.
        final class Slot: @unchecked Sendable {
            let lock = NSLock()
            var place: Place?
        }
        let slots = volumes.map { _ in Slot() }
        let group = DispatchGroup()
        for (volume, slot) in zip(volumes, slots) {
            let key = volume.path
            guard volumesAsking.withValue({ $0.insert(key).inserted }) else { continue }
            group.enter()
            BlockingCalls.run {
                probes.willAsk?(volume.path)
                let values = try? volume.resourceValues(forKeys: Set(keys))
                let place = Place(
                    name: values?.volumeName ?? volume.lastPathComponent,
                    url: volume,
                    kind: Self.volumeKind(
                        path: volume.path,
                        isInternal: values?.volumeIsInternal,
                        isLocal: values?.volumeIsLocal,
                        isRemovable: values?.volumeIsRemovable,
                        isEjectable: values?.volumeIsEjectable
                    ),
                    canBeEjected: Place.VolumeTraits(path: volume.path, values: values).mayBeEjected
                )
                slot.lock.lock()
                slot.place = place
                slot.lock.unlock()
                volumesAsking.withValue { $0.remove(key) }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + probes.volumePatience)
        for (volume, slot) in zip(volumes, slots) {
            slot.lock.lock()
            let answered = slot.place
            slot.lock.unlock()
            guard let answered else {
                // Not answered in time: what was known of it, or its folder name.
                places.append(
                    previous.first { $0.url.path == volume.path }
                        ?? Place(
                            name: volume.lastPathComponent,
                            url: volume,
                            kind: volume.path == "/" ? .internalDisk : .externalDisk
                        )
                )
                continue
            }
            places.append(answered)
        }
        return places
    }

    /// Internal: the start-up disk, and a local disk the system calls internal that cannot be
    /// taken out.
    ///
    /// A volume the system knows nothing about counts as external.
    internal static func volumeKind(
        path: String,
        isInternal: Bool?,
        isLocal: Bool?,
        isRemovable: Bool?,
        isEjectable: Bool?
    )
        -> Place.Kind
    {
        if path == "/" {
            return .internalDisk
        }
        let fixed = isLocal == true && isInternal == true && isRemovable != true && isEjectable != true
        return fixed ? .internalDisk : .externalDisk
    }

    /// What an entry of a bulk read in the folder at `path` counts for: a folder to measure (its
    /// path), or a file of a size.
    ///
    /// Nil for what is neither (a link, a pipe) and for an entry that cannot be asked about.
    internal static func measured(_ entry: Entry, in path: String) -> (folder: String?, size: Int64)? {
        guard !entry.name.isEmpty else {
            return nil
        }
        let child = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
        var (type, size) = (entry.type, entry.size)
        if entry.failed {
            // The entry is asked by itself, as the listing does.
            var st = stat()
            guard lstat(child, &st) == 0 else {
                return nil
            }
            type =
                (st.st_mode & S_IFMT) == S_IFDIR
                ? VDIR.rawValue : ((st.st_mode & S_IFMT) == S_IFREG ? VREG.rawValue : 0)
            size = Int64(st.st_size)
        }
        guard type == VDIR.rawValue || type == VREG.rawValue else {
            return nil
        }
        return type == VDIR.rawValue ? (child, 0) : (nil, size)
    }

    // MARK: System calls

    /// Opens a folder to be read. `O_CLOEXEC`, and an `EINTR` nobody asked for is tried again.
    internal static func openDirectory(_ path: String) -> Int32 {
        var descriptor: Int32
        repeat {
            descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        } while descriptor < 0 && errno == EINTR
        return descriptor
    }

    // MARK: Reading

    public func list(_ directory: URL, showHidden: Bool) throws -> [FileItem] {
        try list(directory, showHidden: showHidden, cancellation: CancellationFlag())
    }

    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag) throws -> [FileItem] {
        var items: [FileItem] = []
        try list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    public func list(_ directory: URL, showHidden: Bool, receive: ([FileItem]) -> Bool) throws {
        try list(directory, showHidden: showHidden, cancellation: CancellationFlag(), receive: receive)
    }

    /// Names and attributes are fetched together, a buffer at a time, so a folder on a network
    /// share costs a few requests instead of one per file, and its entries can be shown while
    /// the rest is still coming from the server.
    ///
    /// The flag is looked at before every buffer: a listing that was cancelled ends quietly with
    /// what it has delivered.
    public func list(_ directory: URL, showHidden: Bool, cancellation: CancellationFlag, receive: ([FileItem]) -> Bool)
        throws
    {
        if try listInBulk(directory, showHidden: showHidden, cancellation: cancellation, receive: receive) {
            return
        }
        // A volume without bulk reads: every entry is examined on its own, on all cores.
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        let pieceSize = 4_000
        for start in stride(from: 0, to: names.count, by: pieceSize) {
            if cancellation.isCancelled {
                return
            }
            let piece = Array(names[start..<min(start + pieceSize, names.count)])
            let items = Parallel.map(piece, serialBelow: 512) { name in self.item(at: directory.appending(name: name)) }
                .compactMap { item in item.flatMap { $0.isHidden && !showHidden ? nil : $0 } }
            if !receive(items) {
                return
            }
        }
    }

    /// Reads a directory with `getattrlistbulk`.
    ///
    /// Returns false when the volume does not offer it.
    private func listInBulk(
        _ directory: URL,
        showHidden: Bool,
        cancellation: CancellationFlag,
        receive: ([FileItem]) -> Bool
    ) throws -> Bool {
        // Opening the folder and every read of it can wait on the volume. The flag ends such
        // a wait where the system lets a signal end it; the listing then ends quietly, like
        // one that saw the flag between two buffers.
        let interruption = Interruption()
        let registration = cancellation.onCancel { interruption.interrupt() }
        defer { withExtendedLifetime(registration) {} }
        probes.willAsk?(directory.path)
        let path = directory.path
        guard let opened = try? interruption.run({ Int(Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)) }) else {
            return true
        }
        let descriptor = Int32(opened)
        guard descriptor >= 0 else { throw Self.posixError(errno, directory) }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | Entry.wantError | Entry.wantName | Entry.wantType
            | Entry.wantModified
            | Entry.wantMode | Entry.wantFlags
        request.fileattr = Entry.wantSize

        let capacity = 128 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var deliveredAny = false
        // On a share every buffer is a trip to the server; none is made for a listing nobody wants.
        while !cancellation.isCancelled {
            probes.willAsk?(directory.path)
            guard
                let read = try? interruption.run({
                    Int(
                        probes.system("getattrlistbulk", path) {
                            getattrlistbulk(descriptor, &request, buffer, capacity, 0)
                        }
                    )
                })
            else { return true }
            let count = Int32(read)
            // The end of the directory.
            if count == 0 { break }
            if count < 0 {
                if !deliveredAny, errno == ENOTSUP || errno == EINVAL {
                    return false
                }
                throw Self.posixError(errno, directory)
            }
            var entries: [Entry] = []
            entries.reserveCapacity(Int(count))
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let (read, length) = Entry.read(at: entry)
                entry += length
                // An entry that failed is judged again when it has been asked for by itself.
                guard !read.name.isEmpty, showHidden || read.failed || !read.isHidden else { continue }
                entries.append(read)
            }
            deliveredAny = true
            if !receive(items(of: entries, in: directory, showHidden: showHidden)) {
                return true
            }
        }
        return true
    }

    /// Turns what was read into items.
    ///
    /// Most of the cost of an entry is making its URL, so a large batch is spread over the cores.
    /// Each piece works from its own copy of the directory's URL: threads that share one hold each
    /// other up counting its references.
    private func items(of entries: [Entry], in directory: URL, showHidden: Bool) -> [FileItem] {
        let pieceSize = 256
        guard entries.count >= pieceSize * 2, directory.baseURL == nil else {
            return entries.compactMap { item(of: $0, in: directory, showHidden: showHidden) }
        }
        let pieces = stride(from: 0, to: entries.count, by: pieceSize).map { $0..<min($0 + pieceSize, entries.count) }
        let path = directory.path
        return
            entries.withUnsafeBufferPointer { entries in
                // Only read, and only while the call lasts.
                nonisolated(unsafe) let entries = entries
                return Parallel.map(pieces) { piece -> [FileItem] in
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    return piece.compactMap { self.item(of: entries[$0], in: directory, showHidden: showHidden) }
                }
            }
            .flatMap { $0 }
    }

    /// The item an entry of a bulk read of `directory` stands for; nil for one to leave out.
    internal func item(of entry: Entry, in directory: URL, showHidden: Bool) -> FileItem? {
        let url = directory.appending(name: entry.name)
        if entry.failed {
            // The bulk read knows no more than the name; the entry may still answer for itself.
            // One that does not (it was removed since) is not there: the lean listing drops it too.
            guard let item = item(at: url) else {
                return nil
            }
            return showHidden || !item.isHidden ? item : nil
        }
        let (isRegular, isSymlink) = (entry.type == VREG.rawValue, entry.type == VLNK.rawValue)
        var isDirectory = entry.type == VDIR.rawValue
        var isSpecial = !isRegular && !isSymlink && !isDirectory
        var targetSize: Int64?
        if isSymlink, let target = LinkResolver.shared.resolve(url.path) {
            // Only links cost an extra question: what do they point to?
            isDirectory = target.isDirectory
            isSpecial = target.isSpecial
            if target.isRegular { targetSize = target.size }
        }
        // A name that is not valid UTF-8 cannot be written as a location: nothing may try to open it.
        if entry.isNameRepaired { isSpecial = true }
        return FileItem(
            url: url,
            name: entry.name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                isPackage: isDirectory && !isSymlink && isPackage(url),
                isHidden: entry.isHidden,
                isSpecial: isSpecial
            ),
            stat: .init(
                size: isRegular ? entry.size : 0,
                modified: entry.modified,
                permissions: UInt16(entry.mode & 0o7777)
            ),
            linkTargetSize: targetSize
        )
    }

    /// A folder that is shown and opened like a file (`.app` and the like).
    ///
    /// Only folders with an extension can be one, so plain folders cost nothing. The system decides
    /// by the extension, or by a mark on the folder itself (its bundle bit). Asking it is slow, so
    /// what it said about an extension is remembered for a while and only the mark, which is quick
    /// to read, is looked up for each folder.
    internal func isPackage(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else {
            return false
        }
        // A folder that is a share's mount point is not asked: the share may not answer.
        guard MountTable.shared.isLocal(url.path) else {
            return false
        }
        let key = pathExtension.lowercased()
        func ask() -> Bool? { try? url.resourceValues(forKeys: [.isPackageKey]).isPackage }
        packageLock.lock()
        let known = packageExtensions[key]
            .flatMap {
                DispatchTime.now().uptimeNanoseconds - $0.learned < 60_000_000_000 ? $0.isPackage : nil
            }
        packageLock.unlock()
        if known == true {
            return true
        }
        if known == false {
            // Not a package by its extension; the mark can still make it one.
            return Self.hasBundleBit(url.path) ?? ask() ?? false
        }
        guard let answer = ask() else {
            return false
        }
        // The answer speaks for the extension unless the folder's own mark gave it.
        if !answer || Self.hasBundleBit(url.path) == false {
            packageLock.lock()
            if packageExtensions.count > 4_096 { packageExtensions.removeAll() }
            packageExtensions[key] = (answer, DispatchTime.now().uptimeNanoseconds)
            packageLock.unlock()
        }
        return answer
    }

    /// The entry as `lstat` sees it: a link has no size of its own, and what it leads to is
    /// said besides (`isDirectory`, `isSpecial`, and for a link to a file `linkTargetSize`).
    /// `device` is the volume the entry is on; for a folder another volume is mounted on,
    /// that volume's, so it differs from the device of the folder above.
    public func item(at url: URL) -> FileItem? {
        var st = stat()
        probes.willAsk?(url.path)
        guard lstat(url.path, &st) == 0 else {
            return nil
        }
        let name = url.lastPathComponent
        let type = st.st_mode & S_IFMT
        let isSymlink = type == S_IFLNK
        var isDirectory = type == S_IFDIR
        var isSpecial = type != S_IFREG && !isSymlink && !isDirectory
        var targetSize: Int64?
        if isSymlink, let target = LinkResolver.shared.resolve(url.path) {
            isDirectory = target.isDirectory
            isSpecial = target.isSpecial
            if target.isRegular { targetSize = target.size }
        }
        let isPackage = isDirectory && !isSymlink && isPackage(url)
        let modified = Date(
            timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return FileItem(
            url: url,
            name: name,
            kind: .init(
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                isPackage: isPackage,
                isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
                isSpecial: isSpecial
            ),
            stat: .init(
                size: type == S_IFREG ? Int64(st.st_size) : 0,
                modified: modified,
                permissions: UInt16(st.st_mode & 0o7777)
            ),
            linkTargetSize: targetSize
        )
    }

    public func parent(of directory: URL) -> URL? {
        directory.path == "/" ? nil : directory.deletingLastPathComponent()
    }

    /// Every local location is below `/`: no need to go up to find that out.
    public func root(of _: URL) -> URL {
        URL(fileURLWithPath: "/", isDirectory: true)
    }

    // MARK: Opening

    /// `open`, where the open itself can wait (a share that does not answer): it ends, by
    /// throwing, once `cancellation` is set.
    ///
    /// Always `O_CLOEXEC`; an `EINTR` nobody asked for is tried again.
    private func openFile(_ url: URL, _ flags: Int32, mode: mode_t = 0, cancellation: CancellationFlag) throws -> Int32
    {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        let interruption = Interruption()
        let registration = cancellation.onCancel { interruption.interrupt() }
        defer { withExtendedLifetime(registration) {} }
        var code: Int32 = 0
        probes.willAsk?(url.path)
        let descriptor = try interruption.run { () -> Int in
            let descriptor = Darwin.open(url.path, flags | O_CLOEXEC, mode)
            if descriptor < 0 { code = errno }
            return Int(descriptor)
        }
        errno = code
        guard descriptor >= 0 else { throw Self.posixError(code, url) }
        return Int32(descriptor)
    }

    /// Anything but a regular file is refused: opening a pipe, a device or a socket can wait for
    /// ever (and reading some never ends).
    ///
    /// Called with the descriptor of a file opened without waiting. Clears `O_NONBLOCK` again for
    /// the files that pass.
    private func requireRegularFile(_ descriptor: Int32, _ url: URL) throws {
        var st = stat()
        var code: Int32 = 0
        if probes.system("fstat", url.path, { fstat(descriptor, &st) }) != 0 {
            code = errno
        } else if (st.st_mode & S_IFMT) == S_IFDIR {
            code = EISDIR
        } else if (st.st_mode & S_IFMT) != S_IFREG {
            // What `open` opens besides files and folders: a socket cannot be opened at all.
            let kind = (st.st_mode & S_IFMT) == S_IFIFO ? "a named pipe" : "a device"
            close(descriptor)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is \(kind) and is not opened."]
            )
        } else {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0, flags & O_NONBLOCK != 0,
                probes.system("fcntl", url.path, { fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }) != 0
            {
                code = errno
            }
        }
        if code != 0 {
            close(descriptor)
            throw Self.posixError(code, url)
        }
    }

    // MARK: Reading a file

    public func read(_ url: URL) throws -> any FileReader {
        try read(url, cancellation: CancellationFlag())
    }

    /// Opened without waiting (`O_NONBLOCK`) and looked at before anything is read: a pipe or
    /// a device is refused with an error, where opening it would hang the caller.
    public func read(_ url: URL, cancellation: CancellationFlag) throws -> any FileReader {
        let descriptor = try openFile(url, O_RDONLY | O_NONBLOCK, cancellation: cancellation)
        try requireRegularFile(descriptor, url)
        return Reader(descriptor, url: url, probes: probes)
    }

    // MARK: Changing

    /// The calls that change something, for a caller with a flag.
    ///
    /// On a disk of this Mac the change is made on the calling thread, and the flag ends a system
    /// call that waits (by a signal) and keeps the next one from being begun. On a share or an
    /// automounted folder, where a call can wait for as long as the server is away, it is made on a
    /// thread of its own so that the caller can leave it behind (`RemoteChanges`).
    private func change<Value: Sendable>(
        at url: URL,
        _ cancellation: CancellationFlag,
        _ body: @escaping @Sendable (LocalCall) throws -> Value
    ) throws -> Value {
        if cancellation.isCancelled { throw CocoaError(.userCancelled) }
        let call = LocalCall(probes)
        let path = url.path
        let registration = cancellation.onCancel { call.interruption.interrupt() }
        defer { withExtendedLifetime(registration) {} }
        let mount = MountTable.shared.mount(containing: path)
        guard probes.isLocal?(path) ?? mount.isLocal else {
            let volume = probes.isLocal == nil ? mount.path : volumeKey(path)
            return try RemoteChanges.shared.run(
                on: volume,
                patience: probes.patienceAfterCancel,
                cancellation: cancellation,
                call,
                body
            )
        }
        return try body(call)
    }

    public func createDirectory(at url: URL) throws {
        try makeDirectory(url, exclusive: false, LocalCall(probes))
    }

    public func createDirectory(at url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.makeDirectory(url, exclusive: false, $0) }
    }

    /// With `exclusive`, the folder is made by one `mkdir` that fails when anything has the
    /// name, a link included (the system does not follow one there): nothing can be put in
    /// its place between a look and the making, because there is no look.
    public func createDirectory(at url: URL, exclusive: Bool) throws {
        try makeDirectory(url, exclusive: exclusive, LocalCall(probes))
    }

    public func createDirectory(at url: URL, exclusive: Bool, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.makeDirectory(url, exclusive: exclusive, $0) }
    }

    /// Makes the folder and whatever is missing above it.
    ///
    /// An existing folder, or a link to one, is success unless `exclusive`; anything else of that
    /// name is an error.
    private func makeDirectory(_ url: URL, exclusive: Bool, _ call: LocalCall) throws {
        let path = url.path
        func make(_ path: String) throws -> Int32 {
            try call.run(path) { mkdir(path, 0o777) } == 0 ? 0 : errno
        }
        var code = try make(path)
        if code == ENOENT {
            // The nearest folder above that exists, then down again. A folder that another
            // thread made meanwhile is as good as one made here. (The path is absolute, and `/`
            // always exists: the walk up ends there at the latest.)
            var missing: [String] = []
            var above = path
            while true {
                above = (above as NSString).deletingLastPathComponent
                let made = try make(above)
                if made == 0 || made == EEXIST || made == EISDIR { break }
                guard made == ENOENT else {
                    throw Self.posixError(made, URL(fileURLWithPath: above, isDirectory: true))
                }
                missing.append(above)
            }
            for folder in missing.reversed() {
                let made = try make(folder)
                guard made == 0 || made == EEXIST else {
                    throw Self.posixError(made, URL(fileURLWithPath: folder, isDirectory: true))
                }
            }
            code = try make(path)
        }
        switch code {
        case 0:
            return

        case EEXIST, EISDIR:
            if exclusive { throw FileSystemError.alreadyExists(path) }
            var st = stat()
            if try call.run(path, { stat(path, &st) }) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                return
            }
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path, NSURLErrorKey: url])

        default:
            throw Self.posixError(code, url)
        }
    }

    public func write(_ url: URL) throws -> any FileWriter {
        try write(url, cancellation: CancellationFlag())
    }

    /// The file is made with the rights of its owner alone and gets the ones it is meant to
    /// have when it is closed: what is written is not readable by others while it arrives (a
    /// 0600 file streamed from an archive or a server), nor if the transfer fails half way.
    public func write(_ url: URL, cancellation: CancellationFlag) throws -> any FileWriter {
        // O_EXCL: the name must be free, and an existing file is never opened for writing.
        let descriptor: Int32
        do {
            descriptor = try openFile(url, O_WRONLY | O_CREAT | O_EXCL, mode: 0o600, cancellation: cancellation)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            throw FileSystemError.alreadyExists(url.path)
        }
        return Writer(descriptor, url: url, defaultPermissions: Self.defaultFileMode, probes: probes)
    }

    /// The file is cut and the position set through the descriptor it was opened with, so
    /// nothing can come between.
    ///
    /// A link at the end of the name is not followed (it is reported), and neither is anything but
    /// a regular file opened: a pipe without a reader would hold the opening for ever.
    public func append(to url: URL, at offset: Int64?, cancellation: CancellationFlag) throws -> any FileWriter {
        let descriptor: Int32
        do {
            descriptor = try openFile(url, O_WRONLY | O_NONBLOCK | O_NOFOLLOW, cancellation: cancellation)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ELOOP) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ELOOP),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is a symbolic link and is not continued."]
            )
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENXIO) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is a named pipe or a device and is not continued."]
            )
        }
        try requireRegularFile(descriptor, url)
        var st = stat()
        var code: Int32 = 0
        if cancellation.isCancelled {
            code = ECANCELED
        } else if probes.system("fstat", url.path, { fstat(descriptor, &st) }) != 0 {
            code = errno
        } else if let offset {
            // A file shorter than what is to be kept is not the file the caller took it for.
            if offset < 0 || offset > Int64(st.st_size) {
                code = EINVAL
            } else if offset < Int64(st.st_size),
                probes.system("ftruncate", url.path, { ftruncate(descriptor, off_t(offset)) }) != 0
            {
                code = errno
            }
        }
        guard code == 0 else {
            close(descriptor)
            if code == ECANCELED { throw CocoaError(.userCancelled) }
            throw Self.posixError(code, url)
        }
        // Writing goes on at the end of what is kept of the file. (Setting the position of a
        // regular file does not fail.)
        lseek(descriptor, off_t(offset ?? Int64(st.st_size)), SEEK_SET)
        return Writer(descriptor, url: url, defaultPermissions: nil, probes: probes)
    }

    /// One file, one link or one empty directory; never a tree.
    public func remove(_ url: URL) throws {
        try removeItem(url, LocalCall(probes))
    }

    public func remove(_ url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.removeItem(url, $0) }
    }

    /// The way from `root` down to the item is walked folder by folder through descriptors,
    /// each opened without following a link, and the item is removed by its name in the
    /// last of them: whatever is done to the names meanwhile, the removal happens in the
    /// folder that was reached, or not at all.
    public func remove(_ url: URL, below root: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.removeItem(url, below: root, $0) }
    }

    private func removeItem(_ url: URL, below root: URL, _ call: LocalCall) throws {
        let (path, top) = (url.standardizedFileURL.path, root.standardizedFileURL.path)
        let prefix = top.hasSuffix("/") ? top : top + "/"
        guard path.utf8.count > prefix.utf8.count, path.utf8.starts(with: prefix.utf8),
            case let names = PathSafety.components(
                ofRelativePath: String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
            ),
            let last = names.last
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not below \(root.path) and is not removed."]
            )
        }
        func changed(_ code: Int32, _ name: String) -> any Error {
            // ELOOP and ENOTDIR are what the system says to a link or a file where a folder was.
            guard code == ELOOP || code == ENOTDIR else {
                return Self.posixError(code, url)
            }
            return NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(name) on the way to \(url.path) is no longer a folder; nothing was removed."
                ]
            )
        }
        var folder = try call.run(top) { Darwin.open(top, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard folder >= 0 else { throw changed(errno, root.lastPathComponent) }
        defer { close(folder) }
        for name in names.dropLast() {
            let next = try call.run(path) { openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw changed(errno, name) }
            close(folder)
            folder = next
        }
        var st = stat()
        guard try call.run(path, { fstatat(folder, last, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw Self.posixError(errno, url)
        }
        let flag = (st.st_mode & S_IFMT) == S_IFDIR ? AT_REMOVEDIR : 0
        if try call.run(path, { unlinkat(folder, last, flag) }) == 0 {
            forgetLockedCopy(url)
            return
        }
        var code = errno
        // A copy of a locked file that was made here is this file system's to take away again.
        if code == EPERM, let flags = unlockOwnCopy(url) {
            if unlinkat(folder, last, flag) == 0 {
                forgetLockedCopy(url)
                return
            }
            code = errno
            lchflags(url.path, flags)
        }
        throw Self.posixError(code, url)
    }

    private func removeItem(_ url: URL, _ call: LocalCall) throws {
        let path = url.path
        var st = stat()
        guard try call.run(path, { lstat(path, &st) }) == 0 else { throw Self.posixError(errno, url) }
        let isFolder = (st.st_mode & S_IFMT) == S_IFDIR
        func delete() throws -> Bool { try call.run(path) { isFolder ? rmdir(path) : unlink(path) } == 0 }
        if try delete() {
            forgetLockedCopy(url)
            return
        }
        var code = errno
        // A copy of a locked file that was made here is this file system's to take away again.
        if code == EPERM, let flags = unlockOwnCopy(url) {
            do {
                if try delete() {
                    forgetLockedCopy(url)
                    return
                }
                code = errno
            } catch {
                // Cancelled in between: the copy is as locked as it was.
                lchflags(path, flags)
                throw error
            }
            lchflags(path, flags)
        }
        throw Self.posixError(code, url)
    }

    /// The Trash is the system's affair (`FileManager.trashItem`), which offers no way to
    /// end it early: there is no variant with a flag.
    public func trash(_ url: URL) throws {
        try fm.trashItem(at: url, resultingItemURL: nil)
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool) throws {
        try moveItem(source, to: destination, replacing: replacing, LocalCall(probes))
    }

    public func move(_ source: URL, to destination: URL, replacing: Bool, cancellation: CancellationFlag) throws {
        try change(at: source, cancellation) { try self.moveItem(source, to: destination, replacing: replacing, $0) }
    }

    private func moveItem(_ source: URL, to destination: URL, replacing: Bool, _ call: LocalCall) throws {
        let (from, to) = (source.path, destination.path)
        // Without `replacing` the system itself refuses an existing destination, in the same
        // step as the rename, so nothing can slip in between a check and the move.
        /// Renames, and returns the system's error number when that fails.
        func rename() throws -> Int32? {
            let result = try call.run(from) {
                replacing
                    ? probes.system("rename", from) { Darwin.rename(from, to) }
                    : probes.system("renamex_np", from) { renamex_np(from, to, UInt32(RENAME_EXCL)) }
            }
            guard result != 0 else {
                return nil
            }
            guard errno == ENOTSUP, !replacing else {
                return errno
            }
            // A volume that cannot rename exclusively: check, then rename.
            var st = stat()
            if try call.run(to, { lstat(to, &st) }) == 0 { throw FileSystemError.alreadyExists(to) }
            return try call.run(from) { Darwin.rename(from, to) } == 0 ? nil : errno
        }
        // Two names of one file (hard links): rename(2) then does nothing and says it succeeded.
        // They are two names only if each is, letter for letter, an entry of its folder; a change
        // of the letters' case or of the accents' form names the same entry twice, and that is a
        // plain rename, after which nothing may be removed.
        var (before, after) = (stat(), stat())
        let areTwoLinks =
            try replacing && from != to && call.run(from, { lstat(from, &before) }) == 0
            && call.run(to, { lstat(to, &after) }) == 0 && before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && Self.storedName(of: source) == Array(source.lastPathComponent.utf8)
            && Self.storedName(of: destination) == Array(destination.lastPathComponent.utf8)
        var code = try rename()
        // A locked file cannot be renamed. The copy of one that was made here (under a
        // temporary name, to be given its real name now) is unlocked for the moment of the
        // rename and ends up locked like the file it was copied from.
        if code == EPERM, let flags = unlockOwnCopy(source) {
            do {
                code = try rename()
            } catch {
                lchflags(from, flags)
                throw error
            }
            lchflags(code == nil ? to : from, flags)
        }
        if code == nil, areTwoLinks {
            // The other name of the file is taken away, so that the move has moved. Not
            // stopped half way by a flag: the rename has been done.
            guard probes.system("unlink", from, { unlink(from) }) == 0 else { throw Self.posixError(errno, source) }
        }
        switch code {
        case nil:
            forgetLockedCopy(source)

        case EXDEV:
            throw FileSystemError.crossesVolumes

        case EEXIST:
            throw FileSystemError.alreadyExists(to)

        case let code?:
            throw Self.posixError(code, source)
        }
    }

    private func rememberLockedCopy(_ url: URL, _ st: stat) {
        guard Self.isTemporaryName(url) else {
            return
        }
        lockedLock.lock()
        defer { lockedLock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        if lockedCopies.count >= Self.lockedCopyLimit {
            // Whatever is stale goes first; only then the oldest. Never the whole table: the
            // others are temporaries of copies that are going on.
            lockedCopies = lockedCopies.filter { now &- $0.value.made < Self.lockedCopyLifetime }
            while lockedCopies.count >= Self.lockedCopyLimit,
                let oldest = lockedCopies.min(by: { $0.value.made < $1.value.made })
            {
                lockedCopies[oldest.key] = nil
            }
        }
        lockedCopies[url.path] = (st.st_dev, st.st_ino, now)
    }

    private func forgetLockedCopy(_ url: URL) {
        lockedLock.lock()
        defer { lockedLock.unlock() }
        if !lockedCopies.isEmpty { lockedCopies[url.path] = nil }
    }

    /// Unlocks the file at `url` if it is a locked copy made by `copy`, and returns the flags
    /// it had, to be set again.
    ///
    /// Nil for every other file: those stay as locked as they are. The file is opened (the link
    /// itself, not its target) and checked and unlocked through that one descriptor, so the name
    /// cannot be given to another file in between.
    private func unlockOwnCopy(_ url: URL) -> UInt32? {
        lockedLock.lock()
        let known = lockedCopies[url.path]
        lockedLock.unlock()
        guard let known else {
            return nil
        }
        if DispatchTime.now().uptimeNanoseconds &- known.made > Self.lockedCopyLifetime {
            forgetLockedCopy(url)
            return nil
        }
        var st = stat()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_SYMLINK | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            guard fstat(descriptor, &st) == 0, st.st_dev == known.device, st.st_ino == known.inode,
                st.st_flags & Self.lockFlags != 0,
                fchflags(descriptor, st.st_flags & ~Self.lockFlags) == 0
            else { return nil }
            return st.st_flags
        }
        // A file that cannot be opened for reading: by name, as before.
        guard lstat(url.path, &st) == 0, st.st_dev == known.device, st.st_ino == known.inode,
            st.st_flags & Self.lockFlags != 0,
            lchflags(url.path, st.st_flags & ~Self.lockFlags) == 0
        else { return nil }
        return st.st_flags
    }

    /// Regular files are cloned where the volume allows it, otherwise copied block by block;
    /// links are copied as links.
    ///
    /// Nothing else is copied here: a folder is a tree, which only the caller can copy with
    /// progress and a way to stop, and a pipe or a device is not something to read the contents of.
    public func copy(_ source: URL, to destination: URL, progress: (Int64) -> Bool) throws {
        try withoutActuallyEscaping(progress) { progress in
            let report = CopyReport(progress)
            defer { report.detach() }
            try copyItem(source, to: destination, LocalCall(probes), report)
        }
    }

    /// With a flag the copy ends not only when `progress` says so: a read or write that
    /// waits is ended by a signal, the flag is looked at between the steps the system
    /// reports (every block of data, every extended attribute), and on a share the copy
    /// runs where the caller can leave it behind (`RemoteChanges`).
    ///
    /// `progress` is then called on that other thread, while the caller waits, and never after this
    /// has returned. What a stopped copy has written is removed, by this call or, if it was left
    /// behind, by its thread when the system lets it go.
    public func copy(_ source: URL, to destination: URL, cancellation: CancellationFlag, progress: (Int64) -> Bool)
        throws
    {
        try withoutActuallyEscaping(progress) { progress in
            let report = CopyReport(progress)
            defer { report.detach() }
            try change(at: destination, cancellation) { try self.copyItem(source, to: destination, $0, report) }
        }
    }

    private func copyItem(_ source: URL, to destination: URL, _ call: LocalCall, _ report: CopyReport) throws {
        // The destination must be free; an existing file is never touched, not even on failure.
        var st = stat()
        if try call.run(destination.path, { lstat(destination.path, &st) }) == 0 {
            throw FileSystemError.alreadyExists(destination.path)
        }
        guard try call.run(source.path, { lstat(source.path, &st) }) == 0 else {
            throw Self.posixError(errno, source)
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG, S_IFLNK:
            break

        case S_IFDIR:
            throw Self.posixError(EISDIR, source)

        default:
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [
                    NSLocalizedDescriptionKey: "\(source.path) is not an ordinary file or a link and is not copied."
                ]
            )
        }
        // The system calls back through a C function, which cannot capture; what it needs
        // travels as the context pointer.
        final class Progress {
            let report: CopyReport
            let interruption: Interruption
            let stops: (@Sendable (Int32, Int32) -> Bool)?
            var stopped = false
            init(_ report: CopyReport, _ interruption: Interruption, stops: (@Sendable (Int32, Int32) -> Bool)?) {
                (self.report, self.interruption, self.stops) = (report, interruption, stops)
            }
        }
        let context = Progress(report, call.interruption, stops: probes.copyStops)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            // (The context is always set, below.)
            let progress = Unmanaged<Progress>.fromOpaque(context.unsafelyUnwrapped).takeUnretainedValue()
            // A write that failed ends the copy, with its error. Going on would have the system try
            // the same write again, and on a full or vanished disk it would do so for ever.
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_ERR {
                return COPYFILE_QUIT
            }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                if !progress.report(Int64(copied)) { progress.stopped = true }
            }
            // Every step the system reports (the start and end of the data, each extended
            // attribute) is a place to stop for a caller that has set its flag.
            if progress.interruption.isInterrupted || progress.stops?(what, stage) == true { progress.stopped = true }
            return progress.stopped ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(
            state,
            UInt32(COPYFILE_STATE_STATUS_CB),
            unsafeBitCast(callback, to: UnsafeRawPointer.self)
        )
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        // Data, attributes, permissions and extended attributes; clone instead of copying
        // when possible; and only ever to a name that is free at the moment the copy is
        // made (a file another program put there after the check above stays as it is).
        // Neither end is followed if a link is put there since the check above; holes of a
        // sparse file stay holes (a disk image copied to another volume is not written out in full).
        let (clone, exclusive, noFollow, sparse) = (
            copyfile_flags_t(1 << 24), copyfile_flags_t(1 << 17), copyfile_flags_t(3 << 18),
            copyfile_flags_t(1 << 27)
        )
        let flags =
            copyfile_flags_t(COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA) | clone | exclusive
            | noFollow | sparse
        // Made once: a copy that a stray signal ended has its file already, and fails here.
        guard try call.runOnce(source.path, { copyfile(source.path, destination.path, state, flags) }) == 0 else {
            let code = errno
            if code == EEXIST { throw FileSystemError.alreadyExists(destination.path) }
            // Only what this copy created is taken away again: the file it had open.
            var descriptor: Int32 = -1
            var (created, found) = (stat(), stat())
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_DST_FD), &descriptor) == 0, descriptor >= 0,
                fstat(descriptor, &created) == 0,
                lstat(destination.path, &found) == 0, found.st_dev == created.st_dev, found.st_ino == created.st_ino
            {
                if probes.system("unlink", destination.path, { unlink(destination.path) }) != 0, errno == EPERM,
                    lchflags(destination.path, found.st_flags & ~Self.lockFlags) == 0
                {
                    unlink(destination.path)
                }
            }
            throw context.stopped || call.interruption.isInterrupted
                ? CocoaError(.userCancelled) : Self.posixError(code, source)
        }
        var copied = stat()
        guard probes.system("lstat", destination.path, { lstat(destination.path, &copied) }) == 0 else {
            return
        }
        // A clone keeps the creation date by itself; a block copy to another volume does not.
        // (A locked copy cannot be changed any more, and is unlocked for the moment.)
        if copied.st_birthtimespec.tv_sec != st.st_birthtimespec.tv_sec {
            let isLocked = copied.st_flags & Self.lockFlags != 0
            if isLocked { lchflags(destination.path, copied.st_flags & ~Self.lockFlags) }
            setCreationDate(st.st_birthtimespec, of: destination.path)
            if isLocked { lchflags(destination.path, copied.st_flags) }
        }
        // The lock of the source came along. The copy is remembered, so that it can still
        // be renamed or removed by whoever asked for it.
        if copied.st_flags & Self.lockFlags != 0 { rememberLockedCopy(destination, copied) }
    }

    /// Giving the owner the right to write also unlocks an item that is locked in the Finder:
    /// the lock is the Mac's read-only attribute, and the system refuses every other change
    /// while it is set.
    ///
    /// The item itself is changed, never what a link points to; and if a change fails after the
    /// lock was taken off, the lock is put back.
    public func setAttributes(_ attributes: FileAttributes, of url: URL) throws {
        try changeAttributes(attributes, of: url, LocalCall(probes))
    }

    public func setAttributes(_ attributes: FileAttributes, of url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.changeAttributes(attributes, of: url, $0) }
    }

    private func changeAttributes(_ attributes: FileAttributes, of url: URL, _ call: LocalCall) throws {
        let path = url.path
        var unlocked: UInt32?
        do {
            if let permissions = attributes.permissions, permissions & 0o200 != 0 {
                var st = stat()
                if try call.run(path, { lstat(path, &st) }) == 0, st.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                    guard
                        try call.run(
                            path,
                            {
                                probes.system("lchflags", path) { lchflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE)) }
                            }
                        ) == 0
                    else {
                        throw Self.posixError(errno, url)
                    }
                    unlocked = st.st_flags
                }
            }
            if let modified = attributes.modified {
                let seconds = modified.timeIntervalSince1970.rounded(.down)
                let nanoseconds = ((modified.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)
                // The time of access stays as it is.
                var times = [
                    timespec(tv_sec: 0, tv_nsec: Int((1 << 30) - 2)),
                    timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
                ]
                if try call.run(path, { utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) }) != 0 {
                    throw Self.posixError(errno, url)
                }
            }
            if let permissions = attributes.permissions {
                // A link has no rights of its own on some volumes: that is not an error.
                if try call.run(path, { lchmod(path, mode_t(permissions) & 0o7777) }) != 0, errno != ENOTSUP,
                    errno != EOPNOTSUPP
                {
                    throw Self.posixError(errno, url)
                }
            }
        } catch {
            // Whatever stopped the change (an error, the caller's flag): a lock that was
            // taken off for it is put back.
            let code = errno
            if let unlocked { lchflags(path, unlocked) }
            errno = code
            throw error
        }
    }

    /// Extended attributes and access control lists are copied by the system, as it copies
    /// them with a file; the date of creation and the flags are set after them, the flags
    /// last, because a lock among them forbids everything else.
    public func copyMetadata(from source: URL, to destination: URL) throws {
        try carryMetadata(from: source, to: destination, LocalCall(probes))
    }

    public func copyMetadata(from source: URL, to destination: URL, cancellation: CancellationFlag) throws {
        try change(at: destination, cancellation) { try self.carryMetadata(from: source, to: destination, $0) }
    }

    /// The flag ends the waiting of the first questions and of the copying of the extended
    /// attributes; what follows (the date of creation, the flags) is two short calls that
    /// are made in any case, so that a destination is not left with half of them.
    private func carryMetadata(from source: URL, to destination: URL, _ call: LocalCall) throws {
        guard source.isFileURL, destination.isFileURL else {
            throw FileSystemError.notSupported("Copying metadata from \(source.scheme ?? "another file system")")
        }
        var (from, to) = (stat(), stat())
        guard try call.run(source.path, { lstat(source.path, &from) }) == 0 else {
            throw Self.posixError(errno, source)
        }
        guard try call.run(destination.path, { lstat(destination.path, &to) }) == 0 else {
            throw Self.posixError(errno, destination)
        }
        // Opening a pipe or a device to copy from or to it could wait for ever.
        for (st, url) in [(from, source), (to, destination)] {
            switch st.st_mode & S_IFMT {
            case S_IFREG, S_IFDIR, S_IFLNK:
                break

            default:
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(EINVAL),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(url.path) is not an ordinary file, a folder or a link: nothing is copied to or from it."
                    ]
                )
            }
        }
        var failure: any Error?
        // Attributes that are there already are written again, so the call may be made twice.
        if try call.run(
            destination.path,
            {
                probes.system("copyfile", destination.path) {
                    copyfile(
                        source.path,
                        destination.path,
                        nil,
                        copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW)
                    )
                }
            }
        ) != 0 {
            failure = Self.posixError(errno, destination)
        }
        if from.st_birthtimespec.tv_sec != to.st_birthtimespec.tv_sec
            || from.st_birthtimespec.tv_nsec != to.st_birthtimespec.tv_nsec
        {
            if !setCreationDate(from.st_birthtimespec, of: destination.path), failure == nil {
                failure = Self.posixError(errno, destination)
            }
        }
        // The flags a user may set; the system's own stay as they are on both sides.
        let carried = UInt32(UF_HIDDEN | UF_NODUMP | UF_OPAQUE) | Self.lockFlags
        let wanted = (to.st_flags & ~carried) | (from.st_flags & carried)
        if wanted != to.st_flags {
            if probes.system("lchflags", destination.path, { lchflags(destination.path, wanted) }) != 0 {
                if failure == nil { failure = Self.posixError(errno, destination) }
            } else if wanted & Self.lockFlags != 0 {
                // Locked like its source. A file still under a temporary name is still this file
                // system's to rename or remove; a folder, or a file that has its name, is the user's.
                rememberLockedCopy(destination, to)
            }
        }
        if let failure { throw failure }
    }

    /// The mark of the item itself: what was downloaded says so wherever it is copied to.
    public func quarantine(of url: URL) -> Data? {
        let path = url.path
        let size = getxattr(path, Self.quarantineName, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else {
            return nil
        }
        var value = Data(count: size)
        let got = value.withUnsafeMutableBytes { buffer in
            probes.system("getxattr", path) {
                getxattr(path, Self.quarantineName, buffer.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
        }
        return got > 0 ? value.prefix(got) : nil
    }

    public func setQuarantine(_ value: Data, of url: URL) throws {
        try mark(value, of: url, LocalCall(probes))
    }

    public func setQuarantine(_ value: Data, of url: URL, cancellation: CancellationFlag) throws {
        try change(at: url, cancellation) { try self.mark(value, of: url, $0) }
    }

    private func mark(_ value: Data, of url: URL, _ call: LocalCall) throws {
        let path = url.path
        let result = try value.withUnsafeBytes { bytes in
            try call.run(path) {
                setxattr(path, Self.quarantineName, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
        }
        if result != 0 { throw Self.posixError(errno, url) }
    }

    /// The date an item was created: the one thing a copy between two volumes loses when
    /// only date of change and permissions travel.
    ///
    /// Set on the item itself, never on what a link points to.
    @discardableResult
    private func setCreationDate(_ date: timespec, of path: String) -> Bool {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var created = date
        return probes.system("setattrlist", path) {
            setattrlist(path, &request, &created, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        } == 0
    }

    // MARK: Surroundings

    public func displayPath(_ url: URL) -> String {
        url.path
    }

    /// Home and its usual folders, iCloud Drive and Applications, then every mounted volume the
    /// Finder would show.
    ///
    /// The start-up disk and other built-in disks are internal; whatever is plugged in, a disk
    /// image or a network share is listed as external (the volume list knows no finer kinds).
    ///
    /// **Answers at once, and never waits**: with the last list that was read, or the places
    /// that need no reading until the first one has landed. The list is read in the
    /// background: when this file system is made, whenever a volume comes, goes or is renamed,
    /// and when the list in hand has grown old. Reading it asks the disks, which a caller on
    /// the main thread must not wait for. When the list that was read differs from the one
    /// before, `placesDidChange` is posted on the main thread: whoever shows the places asks
    /// again.
    public func places() -> [Place] {
        placesLock.lock()
        let places = knownPlaces
        let isOld = DispatchTime.now().uptimeNanoseconds &- placesRead > 10_000_000_000
        placesLock.unlock()
        if isOld { refreshPlaces() }
        return places
    }

    /// Reads the places again in the background, unless a reading is under way (it is then
    /// read once more after it) or two readings are stuck.
    internal func refreshPlaces() {
        placesLock.lock()
        guard !isReadingPlaces else {
            placesChangedMeanwhile = true
            placesLock.unlock()
            return
        }
        guard abandonedReads < 2 else {
            // Two readings are stuck already; the list in hand stays.
            placesRead = DispatchTime.now().uptimeNanoseconds
            placesLock.unlock()
            return
        }
        isReadingPlaces = true
        placesGeneration += 1
        let (generation, previous) = (placesGeneration, knownPlaces)
        placesLock.unlock()
        // Reading the places asks the disks, and one that does not answer keeps its thread:
        // a thread of the kernel's own, not one of a dispatch queue's few.
        let (stand, asking) = (probes, volumesAsking)
        BlockingCalls.run { [weak self] in
            let places = Self.readPlaces(previous: previous, stand, asking: asking)
            self?.finishReadingPlaces(places, generation: generation)
        }
        LocalClock.queue.asyncAfter(deadline: .now() + probes.placesPatience) { [weak self] in
            self?.abandonReadingPlaces(generation: generation)
        }
    }

    private func finishReadingPlaces(_ places: [Place], generation: Int) {
        placesLock.lock()
        guard generation == placesGeneration else {
            // Given up on meanwhile and over now: the disks answer again, so the list is read anew.
            abandonedReads -= 1
            placesLock.unlock()
            refreshPlaces()
            return
        }
        let signature = { (places: [Place]) in places.map { "\($0.name)\u{0}\($0.url.path)\u{0}\($0.kind)" } }
        let isNew = signature(places) != signature(knownPlaces)
        (knownPlaces, placesRead) = (places, DispatchTime.now().uptimeNanoseconds)
        let again = placesChangedMeanwhile
        (placesChangedMeanwhile, isReadingPlaces) = (false, false)
        placesLock.unlock()
        if isNew {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                NotificationCenter.default.post(name: Self.placesDidChange, object: self)
            }
        }
        if again { refreshPlaces() }
    }

    private func abandonReadingPlaces(generation: Int) {
        placesLock.lock()
        guard isReadingPlaces, generation == placesGeneration else {
            placesLock.unlock()
            return
        }
        placesGeneration += 1
        abandonedReads += 1
        isReadingPlaces = false
        // Not asked for again at the very next call: the list in hand is as young as this.
        placesRead = DispatchTime.now().uptimeNanoseconds
        let again = placesChangedMeanwhile
        placesChangedMeanwhile = false
        placesLock.unlock()
        if again { refreshPlaces() }
    }

    /// The volume a location is on.
    ///
    /// A location that does not exist yet (the target of a copy that will create it) is answered
    /// for the nearest folder above it that does.
    ///
    /// Asking the disk can take for ever when it is a share that went away, and this is asked
    /// often (every listing, every job): the question is put on a thread of the kernel's own
    /// (`BlockingCalls`) and waited for for a moment. A volume is asked one question at a
    /// time: whoever asks while one is under way waits for the same answer, and once the
    /// volume has not answered in time, everybody is answered at once from what was last
    /// known, until the question comes back. `FileSystemRegistry.volumeInfoDidChange` then
    /// tells those who were given the old figures to ask again.
    public func volume(of url: URL) -> VolumeInfo? {
        volume(of: url, waitingUnless: nil)
    }

    /// The same, given up at once (with nil) when `cancellation` is set: the caller neither
    /// waits out the moment a volume is given, nor for a thread to ask on.
    ///
    /// The question itself is one the system cannot be made to take back; it stays with its thread,
    /// and while it is unanswered nobody asks that volume again (see above).
    public func volume(of url: URL, cancellation: CancellationFlag) -> VolumeInfo? {
        volume(of: url, waitingUnless: cancellation)
    }

    private func volume(of url: URL, waitingUnless cancellation: CancellationFlag?) -> VolumeInfo? {
        if cancellation?.isCancelled == true {
            return nil
        }
        let path = url.standardizedFileURL.path
        let isProbed = probes.isLocal != nil || probes.willAsk != nil
        let mount = isProbed ? volumeKey(path) : MountTable.shared.mount(containing: path).path
        func fromMemory() -> VolumeInfo {
            lastVolumes[mount]
                ?? VolumeInfo(
                    name: URL(fileURLWithPath: mount).lastPathComponent,
                    isLocal: probes.isLocal?(mount) ?? MountTable.shared.isLocal(mount)
                )
        }
        let patience = UInt64(probes.volumePatience * 1_000_000_000)
        volumeLock.lock()
        let question: VolumeQuestion
        var isNew = false
        if let asked = volumeQuestions[mount] {
            question = asked
            if DispatchTime.now().uptimeNanoseconds &- asked.asked > patience {
                // The volume has not answered in time: what was last known, at once.
                asked.wasAnsweredFromMemory = true
                defer { volumeLock.unlock() }
                return fromMemory()
            }
        } else {
            question = VolumeQuestion()
            volumeQuestions[mount] = question
            isNew = true
        }
        volumeLock.unlock()
        if isNew {
            // A thread of the kernel's own: if the volume never answers, it is that thread
            // which stays, and not one of the few a dispatch queue has. One per volume:
            // whoever asks meanwhile waits for the same answer.
            BlockingCalls.run { [self] in
                let info = queryVolume(of: url)
                volumeLock.lock()
                if let info { lastVolumes[mount] = info }
                volumeQuestions[mount] = nil
                let wasMissed = question.wasAnsweredFromMemory
                volumeLock.unlock()
                question.finish(info)
                // Somebody was given the old figures meanwhile: they are told to ask again.
                if wasMissed {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: FileSystemRegistry.volumeInfoDidChange,
                            object: self,
                            userInfo: [
                                FileSystemRegistry.volumeRootKey: URL(fileURLWithPath: mount, isDirectory: true)
                            ]
                        )
                    }
                }
            }
        }
        switch question.wait(until: question.asked &+ patience, cancellation) {
        case .answered(let info):
            return info

        case .cancelled:
            return nil

        case .late:
            volumeLock.lock()
            defer { volumeLock.unlock() }
            // Still the question that is unanswered? Then whoever asks next is not kept waiting either.
            if volumeQuestions[mount] === question { question.wasAnsweredFromMemory = true }
            return fromMemory()
        }
    }

    /// The volume a path is on when a test stands in for the system: the test's own volume
    /// (the nearest folder above that it says is not local), else the real mount.
    private func volumeKey(_ path: String) -> String {
        var current = path
        var remote: String?
        while current != "/", !current.isEmpty {
            if probes.isLocal?(current) == false { remote = current } else if remote != nil { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return remote ?? MountTable.shared.mount(containing: path).path
    }

    /// Asks the system, which may wait for as long as the volume likes (on a thread of its
    /// own: see `volume(of:)`).
    ///
    /// Nil when the volume does not answer the questions, which happens when it has gone meanwhile.
    private func queryVolume(of url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsLocalKey
        ]
        var existing = url.standardizedFileURL
        probes.willAsk?(existing.path)
        while existing.path != "/", !fm.fileExists(atPath: existing.path) {
            existing = existing.deletingLastPathComponent()
        }
        // A URL remembers what it was asked before; a fresh one gives today's free space.
        existing.removeAllCachedResourceValues()
        var info = statfs()
        guard let values = try? existing.resourceValues(forKeys: keys), let name = values.volumeName,
            probes.system("statfs", existing.path, { statfs(existing.path, &info) }) == 0
        else { return nil }
        let available =
            probes.freeSpace.map { $0(existing.path).available } ?? values.volumeAvailableCapacity.map(Int64.init)
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        // Network shares report only the plain figure for free space.
        let free =
            freeForImportantUsage(on: existing, mountPoint: mountPoint, fsid: info.f_fsid, available: available)
            ?? available ?? Int64(info.f_bavail) * Int64(info.f_bsize)
        // (Every volume that answers states its size and whether it is local.)
        return VolumeInfo(
            name: name,
            freeBytes: free,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            isLocal: values.volumeIsLocal != false
        )
    }

    /// The free space as the Finder states it, which counts what the system can clear away.
    ///
    /// That figure takes the system some fifteen milliseconds, every time, so only the first
    /// question about a volume waits for it. Every later one is answered at once: the plainly free
    /// space, which is quick to get and follows every change, plus the difference as it was last
    /// measured. When that measurement is more than a few seconds old it is taken again behind the
    /// scenes, and if the difference has changed, `FileSystemRegistry.volumeInfoDidChange` says so
    /// on the main thread: whoever shows the figure asks again and now gets the right one. So an
    /// answer is never waited for, and never stays wrong for longer than one measurement takes.
    private func freeForImportantUsage(on url: URL, mountPoint: String, fsid: fsid_t, available: Int64?) -> Int64? {
        func measure(_ url: URL) -> Int64? {
            let important =
                if let freeSpace = probes.freeSpace {
                    freeSpace(url.path).important
                } else {
                    (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                        .volumeAvailableCapacityForImportantUsage
                }
            // A share says 0: it does not know.
            return important.flatMap { $0 > 0 ? $0 : nil }
        }
        guard let available else {
            return measure(url)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        spareLock.lock()
        // What was measured of another volume that once was mounted here is of no use.
        if let known = spareSpace[mountPoint], known.volume.val.0 != fsid.val.0 || known.volume.val.1 != fsid.val.1 {
            spareSpace[mountPoint] = nil
        }
        guard let known = spareSpace[mountPoint] else {
            spareLock.unlock()
            let important = measure(url)
            spareLock.lock()
            spareSpace[mountPoint] = (
                important.map { $0 - available }, DispatchTime.now().uptimeNanoseconds, false, fsid
            )
            spareLock.unlock()
            return important
        }
        let isDue =
            (now &- known.measured > Self.spareSpaceAge && !known.isMeasuring)
            || (known.isMeasuring && now &- known.measured > Self.spareSpaceLoss)
        if isDue {
            spareSpace[mountPoint]?.isMeasuring = true
            spareSpace[mountPoint]?.measured = now
        }
        spareLock.unlock()
        if isDue {
            BlockingCalls.run { [weak self] in self?.measureSpareSpace(on: mountPoint, volume: fsid) }
        }
        return known.bytes.flatMap { available + $0 > 0 ? available + $0 : nil }
    }

    /// Takes the measurement again and announces a difference that is no longer the one the
    /// answers were worked out from.
    ///
    /// Blocks; runs on a background queue.
    private func measureSpareSpace(on mountPoint: String, volume fsid: fsid_t) {
        var volume = URL(fileURLWithPath: mountPoint, isDirectory: true)
        volume.removeAllCachedResourceValues()
        var figures: (available: Int64?, important: Int64?)?
        if let freeSpace = probes.freeSpace {
            figures = freeSpace(mountPoint)
        } else if let values = try? volume.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) {
            figures = (values.volumeAvailableCapacity.map(Int64.init), values.volumeAvailableCapacityForImportantUsage)
        }
        spareLock.lock()
        let before = spareSpace[mountPoint]?.bytes
        var after: Int64?
        if let figures, let available = figures.available {
            after = figures.important.flatMap { $0 > 0 ? $0 : nil }.map { $0 - available }
            spareSpace[mountPoint] = (after, DispatchTime.now().uptimeNanoseconds, false, fsid)
        } else {
            // Nothing to be learned now (the volume has gone): the next question measures again.
            spareSpace[mountPoint] = nil
        }
        spareLock.unlock()
        guard after != before else {
            return
        }
        DispatchQueue.main.async { [volume] in
            NotificationCenter.default.post(
                name: FileSystemRegistry.volumeInfoDidChange,
                object: self,
                userInfo: [FileSystemRegistry.volumeRootKey: volume]
            )
        }
    }

    /// The stream of changes runs on queues of its own; `onChange` is called on the main
    /// thread, and only for the directories that were asked for.
    ///
    /// Returns at once: the folders are resolved and the stream is made in the background (a share
    /// that does not answer must not hold up the caller).
    public func watch(_ directories: [URL], onChange: @escaping @MainActor @Sendable ([URL]) -> Void) -> (
        any WatchToken
    )? {
        // The watcher delivers on the main queue.
        let watcher = DirectoryWatcher { changed in MainActor.assumeIsolated { onChange(changed) } }
        watcher.watch(directories)
        return watcher
    }

    // MARK: Sizes

    /// Adds up a tree without making an item of every entry: names, kinds and sizes are all
    /// that is read, and the folders of each level are measured on all cores.
    public func totalSize(of directory: URL, cancellation: CancellationFlag) -> Int64 {
        totalSize(ofPath: directory.path, cancellation)
            ?? totalSizeByListing(of: directory, cancellation: cancellation)
    }

    /// The folder's entries, a buffer at a time: files are added up, folders are returned.
    /// `nil` result when the volume has no bulk reads.
    private func measureLevel(_ path: String, _ cancellation: CancellationFlag) -> (files: Int64, folders: [String])? {
        var files: Int64 = 0
        var folders: [String] = []
        probes.willAsk?(path)
        let descriptor = Self.openDirectory(path)
        // As when listing: a folder that cannot be read counts as nothing.
        guard descriptor >= 0 else {
            return (0, [])
        }
        defer { close(descriptor) }
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | Entry.wantError | Entry.wantName | Entry.wantType
        request.fileattr = Entry.wantSize
        let capacity = 64 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        var isFirst = true
        // Looked at before every buffer: a million-entry folder is not read to the end after Cancel.
        while !cancellation.isCancelled {
            let count = readBulk(descriptor, path, &request, buffer, capacity)
            if count == 0 { break }
            if count < 0 {
                return isFirst && (errno == ENOTSUP || errno == EINVAL) ? nil : (0, [])
            }
            isFirst = false
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let (read, length) = Entry.read(at: entry)
                entry += length
                guard let measured = Self.measured(read, in: path) else { continue }
                if let folder = measured.folder {
                    folders.append(folder)
                } else {
                    files = files.addingSaturated(measured.size)
                }
            }
        }
        return (files, folders)
    }

    /// Nil when the volume has no bulk reads; the tree is then measured by listing it.
    private func totalSize(ofPath path: String, _ cancellation: CancellationFlag) -> Int64? {
        guard !cancellation.isCancelled else {
            return 0
        }
        // A folder that is only on a server (iCloud Drive) is not fetched to be measured.
        guard let level = Self.withoutMaterializing({ measureLevel(path, cancellation) }) else {
            return nil
        }
        guard !cancellation.isCancelled else {
            return 0
        }
        return
            Parallel.map(level.folders) { folder in
                self.totalSize(ofPath: folder, cancellation)
                    ?? self.totalSizeByListing(
                        of: URL(fileURLWithPath: folder, isDirectory: true),
                        cancellation: cancellation
                    )
            }
            .reduce(level.files) { $0.addingSaturated($1) }
    }

    /// `getattrlistbulk` of the folder at `path`, tried again after an `EINTR` nobody asked for.
    internal func readBulk(
        _ descriptor: Int32,
        _ path: String,
        _ request: UnsafeMutablePointer<attrlist>,
        _ buffer: UnsafeMutableRawPointer,
        _ capacity: Int
    ) -> Int32 {
        var count: Int32
        repeat {
            count = probes.system("getattrlistbulk", path) { getattrlistbulk(descriptor, request, buffer, capacity, 0) }
        } while count < 0 && errno == EINTR
        return count
    }

    deinit {
        mountObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
