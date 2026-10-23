public import AFMKernel
public import Foundation

/// Collects every file below some directories into one flat list (spec 03 › Branch view).
///
/// **Threading.** `walk` blocks and is meant for a background thread. It goes through the tree
/// level by level and reads the directories of a level on all cores at once, so a wide tree is
/// read as fast as the file system answers. `receive` is called on the calling thread only,
/// one batch at a time. The walker holds no state of its own and may be used from several
/// threads at once.
public struct BranchWalker: Sendable {
    /// A directory to walk, and what is written in front of the names found in it: empty for
    /// the branch root, `docs/` for its folder `docs`.
    public struct Start: Sendable {
        /// The directory whose items are listed and whose folders are walked in turn.
        public let directory: URL
        /// What is written in front of the name of every item found in the directory.
        public let prefix: String
        /// The disk the walk of this tree began on; set by `walk`.
        internal private(set) var device: dev_t?
        /// The disk this directory is on.
        internal private(set) var ownDevice: dev_t?
        /// The tree starts at `/`, where firmlinks put the user's folders on another disk.
        internal private(set) var crossesDisks = false

        /// A start that `walk` places on its disk itself, before it lists it.
        public init(_ directory: URL, prefix: String = "") {
            self.directory = directory
            self.prefix = prefix
        }

        /// Notes the disk a tree starts on, and whether its walk goes on to other disks.
        internal mutating func begin(on device: dev_t, crossesDisks: Bool) {
            self.device = device
            ownDevice = device
            self.crossesDisks = crossesDisks
        }

        /// The start for a folder found in this one, which lies on `own`: on the same tree,
        /// with the same disk to stay on.
        internal func child(_ url: URL, prefix: String, on own: dev_t) -> Self {
            var child = Self(url, prefix: prefix)
            child.device = device
            child.ownDevice = own
            child.crossesDisks = crossesDisks
            return child
        }
    }

    /// Names one directory however many paths lead to it: its disk and its entry on the disk.
    private struct DirectoryKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// What a walk has gathered so far, level by level.
    private struct Progress {
        /// How many of the directories read are kept in `visited`.
        let keeping: Int
        /// The directories that were read, the first `keeping` of them.
        var visited: [URL] = []
        /// Every directory entered, so that none is entered twice.
        var entered = Set<DirectoryKey>()
        /// The folders of the next level.
        var next: [Start] = []
    }

    /// Folders the walk never enters, besides every mounted volume it finds out for itself (see
    /// `isMountPoint`): other disks and shares are mounted here, and `/System/Volumes/Data`
    /// holds a second view of everything.
    internal static let mountFolders: Set<String> = ["/Volumes", "/System/Volumes", "/Network", "/net", "/home", "/dev"]

    /// How many directories are read side by side before their files are handed over.
    internal static let directoriesPerBatch = 64

    /// The file systems the directories are listed by, each on its own.
    public let fileSystems: FileSystemRegistry
    /// Also lists the items whose names start with a dot.
    public var showHidden: Bool
    /// Also lists the folders themselves, not only what is in them.
    public var listsFolders: Bool
    /// Walks into packages (`.app` and the like) instead of listing them as one item.
    public var entersPackages: Bool
    /// Where the answers about disks come from: the system's, or a test's.
    internal var volumes = VolumeProbe.system

    /// A walker that asks the system about disks.
    public init(
        fileSystems: FileSystemRegistry,
        showHidden: Bool,
        listsFolders: Bool = false,
        entersPackages: Bool = false
    ) {
        self.fileSystems = fileSystems
        self.showHidden = showHidden
        self.listsFolders = listsFolders
        self.entersPackages = entersPackages
    }

    /// True when a disk is mounted at `path` itself.
    ///
    /// A folder on another device than its parent is not enough to say so: on the start-up disk the
    /// user's folders are firmlinked from the data volume, and the system reports the volume's
    /// mount point for them, not their own.
    internal static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return false
        }
        // The system names the mount point by its real path.
        let real = realpath(path, nil)
            .map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            }
        let mountPoint = withUnsafePointer(to: &info.f_mntonname) { name in
            name.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountPoint == real
    }

    /// Walks the trees below `starts`.
    ///
    /// Each item keeps its real location; its name is its path relative to the branch root, which
    /// is unique within the list. Links to folders are listed, not followed, so the walk cannot run
    /// in circles. A folder that cannot be read is left out, except when `mustRead` is set and it
    /// is one of the starts: that error is thrown. `receive` returns false to stop. Once
    /// `cancellation` is set the walk ends at once, also in the directory it is reading, and
    /// returns what it has.
    ///
    /// Returns the directories that were read, for whoever wants to watch them: the first
    /// `keeping` of them (a walk of a million folders does not hold a million locations).
    @discardableResult
    public func walk(
        _ starts: [Start],
        mustRead: Bool = false,
        keeping: Int = Int.max,
        cancellation: CancellationFlag? = nil,
        receive: ([FileItem]) -> Bool
    ) throws -> [URL] {
        func isCancelled() -> Bool { cancellation?.isCancelled == true }
        // Every directory is entered once, however many paths lead to it, and the walk stays on
        // the disk it began on (below `/`, the user's firmlinked folders excepted).
        var progress = Progress(keeping: keeping)
        var level = firstLevel(starts, entered: &progress.entered)
        var isFirstLevel = true
        while !level.isEmpty, !isCancelled() {
            progress.next = []
            for from in stride(from: 0, to: level.count, by: Self.directoriesPerBatch) {
                if isCancelled() {
                    return progress.visited
                }
                let chunk = Array(level[from..<min(from + Self.directoriesPerBatch, level.count)])
                let listings = Parallel.map(chunk) { start in
                    Result { try list(start.directory, cancellation: cancellation) }
                }
                if isCancelled() {
                    return progress.visited
                }
                let batch = try take(listings, of: chunk, into: &progress, mustRead: mustRead && isFirstLevel)
                if !batch.isEmpty, !receive(batch) {
                    return progress.visited
                }
            }
            level = progress.next
            isFirstLevel = false
        }
        return progress.visited
    }

    /// The starts that are walked: each directory once, placed on the disk it lies on.
    private func firstLevel(_ starts: [Start], entered: inout Set<DirectoryKey>) -> [Start] {
        var level: [Start] = []
        for var start in starts {
            if start.directory.isFileURL, let info = volumes.identity(start.directory.path, true) {
                guard entered.insert(DirectoryKey(device: info.device, inode: info.inode)).inserted else {
                    continue
                }
                start.begin(on: info.device, crossesDisks: volumes.crossesDisks(start.directory.path))
            }
            level.append(start)
        }
        return level
    }

    /// The items of one directory, from its own file system; blocks.
    private func list(_ directory: URL, cancellation: CancellationFlag?) throws -> [FileItem] {
        let provider = try fileSystems.provider(for: directory)
        guard let cancellation else {
            return try provider.list(directory, showHidden: showHidden)
        }
        // Piece by piece: a provider can give up half-way through a huge folder.
        var items: [FileItem] = []
        try provider.list(directory, showHidden: showHidden, cancellation: cancellation) { batch in
            items += batch
            return true
        }
        return items
    }

    /// The items to hand over from the listings of `chunk`, under their names in the branch;
    /// the folders to walk go into `progress`.
    ///
    /// A directory that could not be read is left out, unless `mustRead`: then its error is thrown.
    private func take(
        _ listings: [Result<[FileItem], any Error>],
        of chunk: [Start],
        into progress: inout Progress,
        mustRead: Bool
    ) throws -> [FileItem] {
        var batch: [FileItem] = []
        for (start, listing) in zip(chunk, listings) {
            switch listing {
            case .failure(let error):
                if mustRead { throw error }

            case .success(let items):
                if progress.visited.count < progress.keeping { progress.visited.append(start.directory) }
                for item in items {
                    let name = start.prefix + item.name
                    let isWalked = item.isRealDirectory && (entersPackages || !item.isPackage)
                    if isWalked, let child = enter(item.url, name: name, from: start, entered: &progress.entered) {
                        progress.next.append(child)
                    }
                    if !isWalked || listsFolders { batch.append(item.named(name)) }
                }
            }
        }
        return batch
    }

    /// The start for a folder found in `parent`, or nil when it is not to be walked.
    private func enter(_ url: URL, name: String, from parent: Start, entered: inout Set<DirectoryKey>) -> Start? {
        guard url.isFileURL else {
            return Start(url, prefix: name + "/")
        }
        guard let info = volumes.identity(url.path, false), !Self.mountFolders.contains(url.path) else {
            return nil
        }
        if let device = parent.device, info.device != device, !parent.crossesDisks {
            return nil
        }
        // Another device than the folder it lies in: a mounted volume, or a firmlink.
        if let own = parent.ownDevice, info.device != own, volumes.isMountPoint(url.path) {
            return nil
        }
        guard entered.insert(DirectoryKey(device: info.device, inode: info.inode)).inserted else {
            return nil
        }
        return parent.child(url, prefix: name + "/", on: info.device)
    }
}

/// Lets a virtual folder list a file under its path in the folder.
extension FileItem {
    /// The same entry under another name: its place in a virtual folder.
    internal func named(_ name: String) -> FileItem {
        var item = FileItem(url: url, name: name, kind: kind, stat: stat)
        item.computedSize = computedSize
        return item
    }
}
