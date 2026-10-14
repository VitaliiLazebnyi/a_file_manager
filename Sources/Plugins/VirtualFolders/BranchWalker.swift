public import AFMKernel
public import Foundation

/// Collects every file below some directories into one flat list (spec 03 › Branch view).
///
/// **Threading.** `walk` blocks and is meant for a background thread. It goes through the tree
/// level by level and reads the directories of a level on all cores at once, so a wide tree is
/// read as fast as the file system answers. `receive` is called on the calling thread only,
/// one batch at a time. The walker holds no state of its own and may be used from several
/// threads at once.
public struct BranchWalker {
    /// A directory to walk, and what is written in front of the names found in it: empty for
    /// the branch root, `docs/` for its folder `docs`.
    public struct Start {
        public let directory: URL
        public let prefix: String
        /// The disk the walk of this tree began on; set by `walk`.
        fileprivate var device: dev_t?
        /// The disk this directory is on.
        fileprivate var ownDevice: dev_t?
        /// The tree starts at `/`, where firmlinks put the user's folders on another disk.
        fileprivate var crossesDisks = false

        public init(_ directory: URL, prefix: String = "") {
            self.directory = directory
            self.prefix = prefix
        }
    }

    /// Folders the walk never enters, besides every mounted volume it finds out for itself (see
    /// `isMountPoint`): other disks and shares are mounted here, and `/System/Volumes/Data`
    /// holds a second view of everything.
    static let mountFolders: Set<String> = ["/Volumes", "/System/Volumes", "/Network", "/net", "/home", "/dev"]

    /// True when a disk is mounted at `path` itself. A folder on another device than its parent
    /// is not enough to say so: on the start-up disk the user's folders are firmlinked from the
    /// data volume, and the system reports the volume's mount point for them, not their own.
    static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        // The system names the mount point by its real path.
        let real =
            realpath(path, nil).map { pointer -> String in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? path
        return withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        } == real
    }

    private struct DirectoryKey: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// How many directories are read side by side before their files are handed over.
    static let directoriesPerBatch = 64

    public let fileSystems: FileSystemRegistry
    public var showHidden: Bool
    /// Also lists the folders themselves, not only what is in them.
    public var listsFolders: Bool
    /// Walks into packages (`.app` and the like) instead of listing them as one item.
    public var entersPackages: Bool

    public init(
        fileSystems: FileSystemRegistry, showHidden: Bool, listsFolders: Bool = false, entersPackages: Bool = false
    ) {
        self.fileSystems = fileSystems
        self.showHidden = showHidden
        self.listsFolders = listsFolders
        self.entersPackages = entersPackages
    }

    /// The start for a folder found in `parent`, or nil when it is not to be walked.
    private func enter(_ url: URL, name: String, from parent: Start, entered: inout Set<DirectoryKey>) -> Start? {
        var child = Start(url, prefix: name + "/")
        guard url.isFileURL else { return child }
        var info = stat()
        guard lstat(url.path, &info) == 0, !Self.mountFolders.contains(url.path) else { return nil }
        if let device = parent.device, info.st_dev != device, !parent.crossesDisks { return nil }
        // Another device than the folder it lies in: a mounted volume, or a firmlink.
        if let own = parent.ownDevice, info.st_dev != own, Self.isMountPoint(url.path) { return nil }
        guard entered.insert(DirectoryKey(device: info.st_dev, inode: info.st_ino)).inserted else { return nil }
        child.device = parent.device
        child.ownDevice = info.st_dev
        child.crossesDisks = parent.crossesDisks
        return child
    }

    /// Walks the trees below `starts`. Each item keeps its real location; its name is its path
    /// relative to the branch root, which is unique within the list. Links to folders are
    /// listed, not followed, so the walk cannot run in circles. A folder that cannot be read
    /// is left out, except when `mustRead` is set and it is one of the starts: that error is
    /// thrown. `receive` returns false to stop. Once `cancellation` is set the walk ends at
    /// once, also in the directory it is reading, and returns what it has.
    ///
    /// Returns the directories that were read, for whoever wants to watch them: the first
    /// `keeping` of them (a walk of a million folders does not hold a million locations).
    @discardableResult
    public func walk(
        _ starts: [Start], mustRead: Bool = false, keeping: Int = Int.max, cancellation: CancellationFlag? = nil,
        receive: ([FileItem]) -> Bool
    ) throws -> [URL] {
        func isCancelled() -> Bool { cancellation?.isCancelled == true }
        var visited: [URL] = []
        // Every directory is entered once, however many paths lead to it, and the walk stays on
        // the disk it began on (below `/`, the user's firmlinked folders excepted).
        var entered = Set<DirectoryKey>()
        var level: [Start] = []
        for var start in starts {
            if start.directory.isFileURL {
                var info = stat()
                if stat(start.directory.path, &info) == 0 {
                    guard entered.insert(DirectoryKey(device: info.st_dev, inode: info.st_ino)).inserted else {
                        continue
                    }
                    start.device = info.st_dev
                    start.ownDevice = info.st_dev
                    start.crossesDisks = start.directory.path == "/"
                }
            }
            level.append(start)
        }
        var isFirstLevel = true
        while !level.isEmpty, !isCancelled() {
            var next: [Start] = []
            for from in stride(from: 0, to: level.count, by: Self.directoriesPerBatch) {
                if isCancelled() { return visited }
                let chunk = Array(level[from..<min(from + Self.directoriesPerBatch, level.count)])
                let listings = Parallel.map(chunk) { start in
                    Result {
                        let provider = try fileSystems.provider(for: start.directory)
                        guard let cancellation else {
                            return try provider.list(start.directory, showHidden: showHidden)
                        }
                        // Piece by piece: a provider can give up half-way through a huge folder.
                        var items: [FileItem] = []
                        try provider.list(start.directory, showHidden: showHidden, cancellation: cancellation) {
                            batch in
                            items += batch
                            return true
                        }
                        return items
                    }
                }
                if isCancelled() { return visited }
                var batch: [FileItem] = []
                for (start, listing) in zip(chunk, listings) {
                    switch listing {
                    case .failure(let error):
                        if mustRead, isFirstLevel { throw error }

                    case .success(let items):
                        if visited.count < keeping { visited.append(start.directory) }
                        for item in items {
                            let name = start.prefix + item.name
                            let isWalked = item.isRealDirectory && (entersPackages || !item.isPackage)
                            if isWalked, let child = enter(item.url, name: name, from: start, entered: &entered) {
                                next.append(child)
                            }
                            if !isWalked || listsFolders { batch.append(item.named(name)) }
                        }
                    }
                }
                if !batch.isEmpty, !receive(batch) { return visited }
            }
            level = next
            isFirstLevel = false
        }
        return visited
    }
}

extension FileItem {
    /// The same entry under another name: its place in a virtual folder.
    func named(_ name: String) -> FileItem {
        FileItem(
            url: url, name: name, isDirectory: isDirectory, isSymlink: isSymlink, isPackage: isPackage,
            isHidden: isHidden,
            size: size, modified: modified, permissions: permissions, computedSize: computedSize, isSpecial: isSpecial
        )
    }
}
