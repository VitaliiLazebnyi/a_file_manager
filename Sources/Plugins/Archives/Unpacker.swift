import AFMKernel
import Foundation

/// A number several threads add to. All state is guarded by `lock`.
final class SharedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ amount: Int64) {
        lock.lock()
        total += amount
        lock.unlock()
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

enum Background {
    /// Runs `work` on another thread and calls `tick` on this one ten times a second until it
    /// is done: the job's thread stays free to report progress while all cores are busy.
    /// The other thread is one of the kernel's own, not one of the system's shared pool:
    /// the work reads an archive and writes files, and where that waits (a share, a server)
    /// it must not keep a thread everybody else's work needs.
    static func run<Result: Sendable>(_ work: @escaping @Sendable () -> Result, tick: () -> Void) -> Result {
        let group = DispatchGroup()
        // Written by the work before it leaves the group, read here only after the wait.
        nonisolated(unsafe) var result: Result?
        group.enter()
        BlockingCalls.run {
            result = work()
            group.leave()
        }
        while group.wait(timeout: .now() + 0.1) == .timedOut { tick() }
        tick()
        // The group has been waited for, so the work has stored its result.
        return result!
    }
}

/// The mark the system puts on files that came from the internet (`com.apple.quarantine`).
/// What is unpacked from a marked archive is marked the same way, as the system's own
/// unpacker does, so that a program from such an archive is still checked when it is first
/// opened.
enum Quarantine {
    private static let name = "com.apple.quarantine"

    static func read(_ path: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var value = Data(count: size)
        let got = value.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return got > 0 ? value.prefix(got) : nil
    }

    /// Marks a file or folder on the local disk; other places cannot carry the mark.
    static func apply(_ value: Data?, to url: URL) {
        guard let value, url.isFileURL else { return }
        _ = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
    }
}

/// A folder on a disk of this machine that an archive is unpacked into, held open.
///
/// Everything below it is reached from its descriptor, one name at a time, and never through
/// a symbolic link (`openat` with `O_NOFOLLOW`): the folder a file is written into is the one
/// that was opened, whatever is done to the names on the way while the unpacking runs. A
/// path that is checked and then used again by name could be led elsewhere in between, by
/// whoever else may write to the target folder (a shared folder, `/tmp`): a folder taken
/// away and a link put in its place sends a path-based write to wherever the link points.
/// Here the write goes on into the folder that was opened, wherever that has been moved to.
///
/// **Threading.** Any number of threads at once; each call opens and closes what it needs.
final class UnpackFolder: Sendable {
    let url: URL
    private let descriptor: Int32

    /// What the user allows new files to be (`umask`): rights an archive stores beyond that
    /// (a file anyone may write to) are not given, as `tar` and `unzip` do not give them.
    static let allowed: mode_t = {
        let mask = umask(0o022)
        umask(mask)
        return ~mask & 0o7777
    }()

    /// The folder itself is taken as it is, links on the way to it included: it is the place
    /// the user chose. Only what lies below it comes from the archive.
    init(_ url: URL) throws {
        self.url = url
        descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(errno, url.path) }
    }

    deinit {
        close(descriptor)
    }

    private func path(_ names: ArraySlice<String>) -> String {
        names.reduce(url.path) { $0 + "/" + $1 }
    }

    /// Opens the folder at `names` below this one, making what is missing; the caller closes
    /// the descriptor. Throws when a name on the way is a symbolic link or no folder.
    private func openFolder(_ names: ArraySlice<String>) throws -> Int32 {
        var current = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw posixError(errno, url.path) }
        for (index, name) in zip(names.indices, names) {
            // One name, and not a way up: checked here whatever the caller checked.
            guard PathSafety.isSafeName(name) else {
                close(current)
                throw ArchiveError.unsupported("Unpacking to the name \(name)")
            }
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var next = openat(current, name, flags)
            if next < 0, errno == ENOENT {
                if mkdirat(current, name, 0o755) == 0 || errno == EEXIST { next = openat(current, name, flags) }
            }
            guard next >= 0 else {
                let code = errno
                var status = stat()
                let isLink =
                    fstatat(current, name, &status, AT_SYMLINK_NOFOLLOW) == 0 && status.st_mode & S_IFMT == S_IFLNK
                close(current)
                let place = path(names[...index])
                throw isLink
                    ? ArchiveError.unsupported("Unpacking through the symbolic link \(place)")
                    : posixError(code, place)
            }
            close(current)
            current = next
        }
        return current
    }

    private static func mark(_ descriptor: Int32, _ quarantine: Data?) {
        guard let quarantine else { return }
        _ = quarantine.withUnsafeBytes {
            fsetxattr(descriptor, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0)
        }
    }

    /// Makes the folder at `names` (and those above it) and gives it the archive's mark.
    func makeFolder(_ names: [String], quarantine: Data?) throws {
        let folder = try openFolder(names[...])
        defer { close(folder) }
        Self.mark(folder, quarantine)
    }

    /// Makes the symbolic link at `names`. One that stands there is replaced only with `replacing`.
    func makeLink(_ names: [String], to destination: String, replacing: Bool) throws {
        guard let name = names.last, PathSafety.isSafeName(name) else {
            throw ArchiveError.unsupported("Unpacking to an empty name")
        }
        let folder = try openFolder(names.dropLast())
        defer { close(folder) }
        if replacing { unlinkat(folder, name, 0) }
        guard symlinkat(destination, folder, name) == 0 else { throw posixError(errno, path(names[...])) }
    }

    /// Writes the file at `names`: `fill` writes the contents through the function it is
    /// given. The file arrives under a temporary name in the folder it belongs to and takes
    /// its name when `fill` has returned; when `fill` throws, nothing is left. What stands
    /// under the name is replaced only with `replacing` (a symbolic link there is replaced
    /// like a file, never written through); without, it makes the write fail.
    /// `opened` is called when the folder is open and before the file is made (tests).
    func write(
        _ names: [String], replacing: Bool, permissions: UInt16, modified: Date, quarantine: Data?,
        opened: (() -> Void)? = nil,
        _ fill: ((Data) throws -> Void) throws -> Void
    ) throws {
        guard let name = names.last, PathSafety.isSafeName(name) else {
            throw ArchiveError.unsupported("Unpacking to an empty name")
        }
        let folder = try openFolder(names.dropLast())
        defer { close(folder) }
        opened?()
        let place = path(names[...])
        let temporary = ".afm-\(UUID().uuidString).tmp"
        let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError(errno, place) }
        var isOpen = true
        do {
            try fill { block in
                try block.withUnsafeBytes { bytes in
                    var done = 0
                    while done < bytes.count {
                        let written = Darwin.write(file, bytes.baseAddress! + done, bytes.count - done)
                        if written < 0 {
                            if errno == EINTR { continue }
                            throw posixError(errno, place)
                        }
                        done += written
                    }
                }
            }
            let seconds = modified.timeIntervalSince1970.rounded(.down)
            if seconds.isFinite, abs(seconds) < 1e15 {
                let nanoseconds = ((modified.timeIntervalSince1970 - seconds) * 1e9).rounded(.down)
                // The time of access stays as it is.
                var times = [
                    timespec(tv_sec: 0, tv_nsec: Int((1 << 30) - 2)),
                    timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
                ]
                futimens(file, &times)
            }
            guard fchmod(file, mode_t(permissions) & Self.allowed) == 0 else { throw posixError(errno, place) }
            // The mark is on the file before it appears under its name.
            Self.mark(file, quarantine)
            isOpen = false
            guard close(file) == 0 else { throw posixError(errno, place) }
            let moved =
                replacing
                ? renameat(folder, temporary, folder, name)
                : renameatx_np(folder, temporary, folder, name, UInt32(RENAME_EXCL))
            guard moved == 0 else { throw posixError(errno, place) }
        } catch {
            if isOpen { close(file) }
            unlinkat(folder, temporary, 0)
            throw error
        }
    }
}

/// Test archive (spec 08 › Test): reads every member to its end. ZIP members are checked
/// against their CRC, compressed streams against their own checksums, TAR headers against
/// theirs.
enum ArchiveTester {
    /// Asks for the password once, before several threads would each ask for it; and only
    /// when one of the members that are wanted (`only`; all without it) is encrypted.
    static func unlock(_ archive: OpenArchive, only: Set<String>? = nil) throws {
        guard
            let encrypted = archive.entries.first(where: {
                $0.isEncrypted && !$0.isDirectory && only?.contains($0.path) != false
            })
        else { return }
        try archive.open(encrypted).close()
    }

    private static func readThrough(
        _ stream: any ByteStream, expecting size: Int64?, cancellation: CancellationFlag, counter: SharedCounter?
    ) throws {
        var read: Int64 = 0
        while let block = try stream.read(upToCount: 1 << 20) {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            read += Int64(block.count)
            counter?.add(Int64(block.count))
        }
        if let size, read != size { throw ArchiveError.damaged("\(read) bytes instead of \(size)") }
    }

    /// The problems found, one line per damaged member; empty when the archive is sound.
    /// Members that can be read independently are tested on all cores. `counter` receives the
    /// bytes read, for a progress display. With `only`, just the members at those paths are
    /// read. Blocks; meant for a job's thread.
    static func test(
        _ archive: OpenArchive, cancellation: CancellationFlag, counter: SharedCounter? = nil, only: Set<String>? = nil
    ) -> [String] {
        // One operation: once the user has declined to give a password, no member asks again.
        archive.withPasswordScope { testInScope(archive, cancellation: cancellation, counter: counter, only: only) }
    }

    private static func testInScope(
        _ archive: OpenArchive, cancellation: CancellationFlag, counter: SharedCounter?, only: Set<String>?
    ) -> [String] {
        do { try unlock(archive, only: only) } catch { return [error.localizedDescription] }
        let members = archive.entries.filter { !$0.isDirectory && only?.contains($0.path) != false }
        @Sendable func check(_ entry: ArchiveEntry, _ stream: any ByteStream) -> String? {
            do {
                try readThrough(
                    stream, expecting: entry.sizeIsExact ? entry.size : nil, cancellation: cancellation,
                    counter: counter)
                return nil
            } catch ArchiveError.cancelled {
                return nil
            } catch {
                return "\(entry.path): \(error.localizedDescription)"
            }
        }
        if archive.allowsParallelReads {
            return Parallel.map(members) { entry -> String? in
                guard !cancellation.isCancelled else { return nil }
                do {
                    // Cancel also ends the opening of a member, and a read that hangs.
                    let slot = InterruptSlot()
                    let registration = cancellation.onCancel { [weak slot] in slot?.interrupt() }
                    defer { withExtendedLifetime(registration) {} }
                    let stream = try archive.open(entry, slot: slot)
                    defer { stream.close() }
                    return check(entry, stream)
                } catch ArchiveError.cancelled {
                    return nil
                } catch {
                    return "\(entry.path): \(error.localizedDescription)"
                }
            }.compactMap { $0 }
        }
        var problems: [String] = []
        do {
            try archive.readInOnePass(members, cancellation: cancellation) { entry, stream in
                if cancellation.isCancelled { throw ArchiveError.cancelled }
                if let problem = check(entry, stream) { problems.append(problem) }
            }
        } catch ArchiveError.cancelled {
        } catch {
            problems.append(error.localizedDescription)
        }
        return problems
    }
}

/// How Unpack is to work (spec 08 › Unpack › Fields and options).
struct UnpackOptions {
    /// Which files to take, by name: `*.txt *.md`.
    var mask = "*.*"
    /// Keeps the paths stored with the files; without, every file goes straight into the target.
    var keepsPaths = true
    /// Each archive goes into a folder of its own, named after the archive.
    var separateFolders = false
    /// Existing files are replaced without asking.
    var overwrites = false
}

struct UnpackResult {
    var unpacked = 0
    var problems: [String] = []
    var cancelled = false
    /// The first thing that arrived, for the cursor.
    var firstTarget: URL?
}

/// Answers to "the file exists" while unpacking.
enum UnpackConflictChoice {
    case overwrite, overwriteAll, skip, skipAll, cancel
}

/// Unpack (spec 08 › Unpack): writes members of archives into a folder of any file system.
///
/// **Threading.** `run` blocks and is meant for a job's thread. Questions are settled first,
/// on that thread; then the members of an archive that can be read at any position are
/// unpacked on all cores at once, while archives that are one compressed stream are unpacked
/// in a single pass.
///
/// Unchecked: what changes (the answers to questions, the result, the counts, the open
/// folders) is touched only by the thread that calls `run`; the members that are written on
/// all cores use only what is fixed in `init` and `bytesDone` (which guards itself).
final class Unpacker: @unchecked Sendable {
    /// What to take out of one archive: all of it, or what was selected in a panel.
    struct Source {
        let archive: OpenArchive
        /// The folder inside the archive that paths are kept relative to.
        var base = ""
        /// Paths of the selected members (folders with everything in them); nil takes all.
        var selection: [String]?
    }

    private struct Task {
        let entry: ArchiveEntry
        let target: URL
        let replaces: Bool
        /// The folder this archive is unpacked into: nothing is written outside it.
        let root: URL
        /// The names from `root` down to `target`.
        let names: [String]
    }

    private let fileSystems: FileSystemRegistry
    private let monitor: any JobMonitor
    private let options: UnpackOptions
    private let askConflict: (_ existing: FileItem, _ entry: ArchiveEntry) -> UnpackConflictChoice
    private var overwriteAll: Bool
    private var skipAll = false
    private var result = UnpackResult()
    private let bytesDone = SharedCounter()
    private var itemsDone = 0
    private var total = (items: 0, bytes: Int64(0))
    private var lines: [String] = []
    /// Called on the writing thread when the folder a member goes into is open and before
    /// the member's file is made (tests: what is done to the target folder meanwhile).
    private let whileUnpacking: (@Sendable (ArchiveEntry) -> Void)?

    init(
        fileSystems: FileSystemRegistry, monitor: any JobMonitor, options: UnpackOptions,
        whileUnpacking: (@Sendable (ArchiveEntry) -> Void)? = nil,
        askConflict: @escaping (_ existing: FileItem, _ entry: ArchiveEntry) -> UnpackConflictChoice
    ) {
        self.fileSystems = fileSystems
        self.monitor = monitor
        self.options = options
        self.whileUnpacking = whileUnpacking
        self.askConflict = askConflict
        overwriteAll = options.overwrites
    }

    func run(_ sources: [Source], into target: URL) -> UnpackResult {
        let target = ArchiveURL.resolved(target)
        do {
            var work: [(archive: OpenArchive, tasks: [Task])] = []
            for source in sources {
                let name = source.archive.name
                // `photos.tar.gz` unpacks into `photos`.
                let ownName = ArchiveFormat.splitKnownExtension(name)?.base ?? FileItem.split(name).base
                let folder = options.separateFolders ? target.appending(name: ownName) : target
                work.append((source.archive, try plan(source, into: folder)))
            }
            // The sizes are what the archives claim; their sum must not run over.
            total = work.flatMap(\.tasks).reduce(into: (0, Int64(0))) {
                $0 = ($0.0 + 1, $0.1.addingSaturated(max(0, $1.entry.size)))
            }
            for (archive, tasks) in work {
                try checkCancelled()
                // One operation for the passwords: the user is asked once, and only when
                // something that is to be unpacked is encrypted.
                try archive.withPasswordScope {
                    try ArchiveTester.unlock(archive, only: Set(tasks.map(\.entry.path)))
                    lines = [
                        "Unpacking: \(fileSystems.displayPath(archive.archiveURL))",
                        "To: \(fileSystems.displayPath(target))"
                    ]
                    try unpack(tasks, from: archive)
                }
            }
        } catch ArchiveError.cancelled {
            result.cancelled = true
        } catch {
            result.problems.append(error.localizedDescription)
        }
        report()
        return result
    }

    private func checkCancelled() throws {
        if monitor.cancellation.isCancelled { throw ArchiveError.cancelled }
    }

    private func report() {
        monitor.report(
            JobProgress(
                lines: lines, itemsDone: itemsDone, itemsTotal: total.items, bytesDone: bytesDone.value,
                bytesTotal: total.bytes))
    }

    /// Decides what goes where and settles every name collision, before anything is written.
    private func plan(_ source: Source, into folder: URL) throws -> [Task] {
        let archive = source.archive
        var entries: [ArchiveEntry]
        if let selection = source.selection {
            entries = selection.flatMap { path -> [ArchiveEntry] in
                guard let entry = archive.entry(path) else { return [] }
                return [entry] + (entry.isDirectory ? archive.descendants(of: path) : [])
            }
        } else {
            entries = source.base.isEmpty ? archive.entries : archive.descendants(of: source.base)
        }
        let takesAll = FileMask(options.mask).matches("a.b") && FileMask(options.mask).matches("a")
        let mask = FileMask(options.mask)
        var tasks: [Task] = []
        var taken = Set<String>()
        for entry in entries {
            try checkCancelled()
            // Folders come along by themselves when everything is wanted; with a mask or
            // without paths only files are taken, and their folders are made as needed.
            if entry.isDirectory {
                guard takesAll, options.keepsPaths else { continue }
            } else if !takesAll, !mask.matches(entry.name) {
                continue
            }
            var relative = entry.path
            if !options.keepsPaths {
                relative = entry.name
            } else if let below = ArchiveTree.relative(relative, to: source.base) {
                relative = below
            }
            // The names are cut at the byte `/`, as the disk cuts them. The archive's
            // directory lets no path through that leads outside (`ArchiveTree.normalized`);
            // the place it comes to is checked here once more, whatever the path looked like.
            let names = ArchiveTree.names(of: relative)
            let target = names.reduce(folder) { $0.appending(name: $1) }
            guard !names.isEmpty, names.allSatisfy(PathSafety.isSafeName), Self.lies(target, below: folder) else {
                result.problems.append("\(entry.path): the name leads outside the folder that is unpacked into")
                continue
            }
            guard taken.insert(target.locationKey).inserted else { continue }
            if entry.isDirectory {
                tasks.append(Task(entry: entry, target: target, replaces: false, root: folder, names: names))
                continue
            }
            var replaces = false
            if let existing = fileSystems.item(at: target) {
                if existing.isRealDirectory {
                    result.problems.append("\(relative): a folder with this name exists")
                    continue
                }
                guard try mayOverwrite(existing, with: entry) else { continue }
                replaces = true
            }
            tasks.append(Task(entry: entry, target: target, replaces: replaces, root: folder, names: names))
        }
        return tasks
    }

    /// True when `url` is a place below `folder`, by the bytes of the two paths once `.` and
    /// `..` are taken out of them (the kernel's check for paths from outside).
    static func lies(_ url: URL, below folder: URL) -> Bool {
        PathSafety.isContained(url, in: folder)
    }

    /// Refuses to go through a symbolic link on the way from `root` down to `url` (both on
    /// the local disk): a link in the target folder, left by an earlier unpacking or put
    /// there on purpose, would lead what is unpacked now to wherever it points.
    private static func refuseLinks(from root: URL, to url: URL) throws {
        guard url.isFileURL, root.isFileURL else { return }
        let (names, base) = (url.standardized.pathComponents, root.standardized.pathComponents)
        guard names.count > base.count, Array(names[..<base.count]) == base else { return }
        var current = root.standardized
        for name in names[base.count...] {
            current = current.appending(name: name)
            var status = stat()
            // What does not exist yet is made here, as a folder.
            guard lstat(current.path, &status) == 0 else { return }
            if status.st_mode & S_IFMT == S_IFLNK {
                throw ArchiveError.unsupported("Unpacking through the symbolic link \(current.path)")
            }
        }
    }

    private func mayOverwrite(_ existing: FileItem, with entry: ArchiveEntry) throws -> Bool {
        if overwriteAll { return true }
        if skipAll { return false }
        switch askConflict(existing, entry) {
        case .overwrite: return true

        case .overwriteAll:
            overwriteAll = true
            return true

        case .skip: return false

        case .skipAll:
            skipAll = true
            return false

        case .cancel: throw ArchiveError.cancelled
        }
    }

    /// The folders of this machine's disks that are unpacked into, open; see `UnpackFolder`.
    /// A target elsewhere (a server, another archive, a network volume, where a call may
    /// hang and has to be given up through the file system's own means) has none: there the
    /// members are written by path through its file system, after a look for links on the way.
    private var roots: [String: UnpackFolder] = [:]

    private func openRoot(_ root: URL) throws -> UnpackFolder? {
        if let known = roots[root.locationKey] { return known }
        guard root.isFileURL else { return nil }
        // Made as it is: only what lies below it comes from the archive.
        try fileSystems.provider(for: root).createDirectory(at: root, cancellation: monitor.cancellation)
        guard Volume.isOnLocalVolume(Durable.realFile(root).path) else { return nil }
        let folder = try UnpackFolder(root)
        roots[root.locationKey] = folder
        return folder
    }

    private func unpack(_ tasks: [Task], from archive: OpenArchive) throws {
        roots = [:]
        defer { roots = [:] }
        // Folders first, in order, so the files find them.
        var made = Set<String>()
        let stop = monitor.cancellation
        /// (The route by path, for a target that is not a disk of this machine: a server,
        /// another archive, a network volume.)
        func makeFolder(_ url: URL, below root: URL) throws {
            guard !made.contains(url.locationKey) else { return }
            try Self.refuseLinks(from: root, to: url)
            let provider = try fileSystems.provider(for: url)
            // The folders between the target and this one that are not known yet, top first.
            var missing: [URL] = []
            var current = url
            while !made.contains(current.locationKey), !current.isSameLocation(as: root), missing.count < 4_096,
                Self.lies(current, below: root), let above = provider.parent(of: current)
            {
                missing.append(current)
                current = above
            }
            if !made.contains(current.locationKey) {
                // The folder that is unpacked into exists, or is made, as it is: only what lies
                // below it comes from the archive.
                try provider.createDirectory(at: current, cancellation: stop)
                made.insert(current.locationKey)
            }
            for folder in missing.reversed() {
                // A folder that is there is used if it is a folder. One that is not is made
                // here and must be this unpacking's own: whatever has appeared under its name
                // since it was looked for (a link left by an earlier archive or put there on
                // purpose, which would lead everything below it elsewhere) is "already
                // exists", not a way through (L043).
                func isFolder(_ item: FileItem) -> Bool { item.isDirectory && !item.isSymlink }
                if let existing = provider.item(at: folder, cancellation: stop) {
                    guard isFolder(existing) else {
                        throw ArchiveError.unsupported(
                            "Unpacking through \(fileSystems.displayPath(folder)), which is not a folder")
                    }
                } else {
                    do {
                        try provider.createDirectory(at: folder, exclusive: true, cancellation: stop)
                    } catch FileSystemError.alreadyExists {
                        // Made by somebody else in the same moment: only a real folder will do.
                        guard let existing = provider.item(at: folder, cancellation: stop), isFolder(existing) else {
                            throw ArchiveError.unsupported(
                                "Unpacking through \(fileSystems.displayPath(folder)), which is not a folder")
                        }
                    }
                }
                made.insert(folder.locationKey)
            }
        }
        let quarantine = archive.quarantine
        var files: [(task: Task, root: UnpackFolder?)] = []
        // What lies below a folder that could not be made is not tried: the folder's line
        // says why none of it arrived.
        var failed: [String] = []
        for task in tasks {
            if !failed.isEmpty, failed.contains(where: { task.target.path.utf8.starts(with: $0.utf8) }) {
                itemsDone += 1
                continue
            }
            do {
                let root = try openRoot(task.root)
                if task.entry.isDirectory {
                    if let root {
                        // A folder from the archive (an application is one) carries the mark too.
                        try root.makeFolder(task.names, quarantine: quarantine)
                    } else {
                        try makeFolder(task.target, below: task.root)
                        Quarantine.apply(quarantine, to: task.target)
                    }
                    itemsDone += 1
                    result.unpacked += 1
                } else {
                    // (Below an open folder the folders above a file are made as it is written.)
                    if root == nil { try makeFolder(task.target.deletingLastPathComponent(), below: task.root) }
                    files.append((task, root))
                }
                if result.firstTarget == nil { result.firstTarget = task.target }
            } catch {
                result.problems.append("\(task.entry.path): \(error.localizedDescription)")
                if task.entry.isDirectory { failed.append(task.target.path + "/") }
            }
        }
        if !failed.isEmpty {
            files.removeAll { file in failed.contains { file.task.target.path.utf8.starts(with: $0.utf8) } }
        }
        let cancellation = monitor.cancellation
        if archive.allowsParallelReads {
            // Symbolic links are made last, one by one, when every file is in its place:
            // while the files are written on all cores at once, no link that the archive
            // itself brings stands in the target yet, and the outcome does not depend on
            // which thread came first.
            let (links, plain) = (
                files.filter(\.task.entry.isSymbolicLink), files.filter { !$0.task.entry.isSymbolicLink }
            )
            let outcomes = Background.run(
                { [self] in
                    let one: @Sendable ((task: Task, root: UnpackFolder?)) -> String? = { file in
                        let (task, root) = file
                        guard !cancellation.isCancelled else { return "" }
                        do {
                            // Cancel also ends the opening of a member, and a read that hangs.
                            let slot = InterruptSlot()
                            let registration = cancellation.onCancel { [weak slot] in slot?.interrupt() }
                            defer { withExtendedLifetime(registration) {} }
                            let stream = try archive.open(task.entry, slot: slot)
                            defer { stream.close() }
                            try self.write(task, into: root, from: stream, quarantine: quarantine)
                            return nil
                        } catch ArchiveError.cancelled {
                            return ""
                        } catch {
                            return "\(task.entry.path): \(error.localizedDescription)"
                        }
                    }
                    return Parallel.map(plain, one) + links.map(one)
                }, tick: report)
            result.unpacked += outcomes.filter { $0 == nil }.count
            itemsDone += outcomes.count
            result.problems += outcomes.compactMap { $0 }.filter { !$0.isEmpty }
        } else {
            let byOrder = Dictionary(files.map { ($0.task.entry.order, $0) }, uniquingKeysWith: { first, _ in first })
            try archive.readInOnePass(files.map(\.task.entry), cancellation: cancellation) { entry, stream in
                try checkCancelled()
                guard let (task, root) = byOrder[entry.order] else { return }
                do {
                    try write(task, into: root, from: stream, quarantine: quarantine)
                    result.unpacked += 1
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    result.problems.append("\(entry.path): \(error.localizedDescription)")
                }
                itemsDone += 1
                report()
            }
        }
        try checkCancelled()
    }

    /// Writes one member. It arrives under a temporary name and gets its real name when it is
    /// complete and its checksum was right, so a damaged member never replaces a good file.
    /// Called from several threads at once, each with its own member. `quarantine` is the
    /// archive's mark, which the file gets before it appears under its name. With a `root`
    /// (a target on a disk of this machine) the member is written from that folder's
    /// descriptor down and through no link; without, by path through the target's file system.
    private func write(_ task: Task, into root: UnpackFolder?, from stream: any ByteStream, quarantine: Data?) throws {
        let (entry, target) = (task.entry, task.target)
        if let root {
            if entry.isSymbolicLink {
                let destination = String(decoding: try stream.readFully(1 << 16), as: UTF8.self)
                return try root.makeLink(task.names, to: destination, replacing: task.replaces)
            }
            let (cancellation, bytesDone, hook) = (monitor.cancellation, self.bytesDone, whileUnpacking)
            try root.write(
                task.names, replacing: task.replaces, permissions: entry.permissions, modified: entry.modified,
                quarantine: quarantine, opened: hook.map { hook in { hook(entry) } }
            ) { put in
                while let block = try autoreleasepool(invoking: { try stream.read(upToCount: 1 << 20) }) {
                    if cancellation.isCancelled { throw ArchiveError.cancelled }
                    try put(block)
                    bytesDone.add(Int64(block.count))
                }
            }
            return
        }
        let provider = try fileSystems.provider(for: target)
        if target.isFileURL, !task.replaces {
            // A link that stands where the file is to go (one that points nowhere is not
            // seen as a file that exists) is not written through.
            var status = stat()
            if lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK {
                throw ArchiveError.unsupported("Unpacking over the symbolic link \(target.path)")
            }
        }
        if entry.isSymbolicLink {
            // A link can only be made on the local disk; elsewhere it is left out.
            guard target.isFileURL else { return }
            let destination = String(decoding: try stream.readFully(1 << 16), as: UTF8.self)
            if task.replaces { try provider.remove(target, cancellation: monitor.cancellation) }
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            return
        }
        let temporary = target.deletingLastPathComponent().appending(name: ".afm-\(UUID().uuidString).tmp")
        let writer = try provider.write(temporary, cancellation: monitor.cancellation)
        // A write that waits on a server ends when the job is cancelled.
        let tie = monitor.cancellation.interrupting(writer)
        defer { withExtendedLifetime(tie) {} }
        do {
            while let block = try autoreleasepool(invoking: { try stream.read(upToCount: 1 << 20) }) {
                if monitor.cancellation.isCancelled { throw ArchiveError.cancelled }
                try writer.write(block)
                bytesDone.add(Int64(block.count))
            }
            // (No more rights than the user gives new files; see `UnpackFolder.allowed`.)
            let permissions = target.isFileURL ? entry.permissions & UInt16(UnpackFolder.allowed) : entry.permissions
            try writer.close(attributes: FileAttributes(modified: entry.modified, permissions: permissions))
            Quarantine.apply(quarantine, to: temporary)
            try provider.move(temporary, to: target, replacing: task.replaces, cancellation: monitor.cancellation)
        } catch {
            try? writer.close(attributes: FileAttributes())
            try? provider.remove(temporary)
            throw error
        }
    }
}
