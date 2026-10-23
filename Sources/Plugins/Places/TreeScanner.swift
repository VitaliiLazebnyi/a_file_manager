public import AFMKernel
public import Foundation

/// Reads the folders below a root (spec 12 › Reading the tree and the tree cache).
///
/// The scan is a background job that must not get in the way: it runs its disk reads at the
/// lowest priority, does not make the system fetch files that are only in the cloud, and
/// does not go into places the user has not opened: other volumes, network automounts, the
/// folders macOS asks the user's permission for, and the cloud folders. Those are listed in
/// the tree and read when the user opens them. A scan ends by itself after `timeLimit`
/// seconds or `folderLimit` folders, and then counts as incomplete.
///
/// **Threading.** `run` blocks and is meant for a background thread. It goes through the tree
/// level by level and reads the folders of a level on all cores at once; `receive` is called
/// on the calling thread, one call at a time. `cancellation` may be set from any thread.
/// `paths` and `unscanned` belong to the thread that runs the scan and are read after `run`
/// has returned.
///
/// Used by one thread at a time: the limits are set before `run`, and `paths`, `unscanned`
/// and `reachedLimit` are only touched by the thread that runs it. The threads that read
/// folders side by side use only what is fixed in `init`, and `cancellation`, which is safe
/// from any thread.
public final class TreeScanner: @unchecked Sendable {
    /// A folder that was read: its path relative to the root and the names of its subfolders,
    /// in display order (sorted off the main thread, where the scan runs).
    public struct Level: Equatable {
        /// The folder's path relative to the root; empty for the root.
        public let path: String
        /// The names of its subfolders.
        public let children: [String]
        /// Whether `children` are in display order already.
        public let isSorted: Bool
        /// The nodes for `children`, made where the level is made (off the main thread, in a
        /// scan) so that the tree only has to link them.
        public let nodes: [TreeNode]

        /// The level of the folder at `path` with the subfolders `children`; their nodes are made here.
        public init(path: String, children: [String], isSorted: Bool = false) {
            self.path = path
            self.children = children
            self.isSorted = isSorted
            nodes = DirectoryTree.makeNodes(children, sorted: isSorted)
        }

        /// Levels are equal when path, names and order are: the nodes are made anew for each.
        public static func == (first: Self, second: Self) -> Bool {
            (first.path, first.children, first.isSorted) == (second.path, second.children, second.isSorted)
        }
    }

    /// A subfolder found while reading a folder.
    private struct Subfolder {
        /// Its name.
        let name: String
        /// Its location.
        let url: URL
        /// Another volume is mounted on this folder.
        var isMount = false
        /// A scan does not go in: the folder is protected or only in the cloud (see `isProtected`).
        var isUnread = false
    }

    /// Set from any thread to stop the scan.
    public let cancellation = CancellationFlag()
    /// How long a scan may go on, in seconds.
    public var timeLimit: TimeInterval = 10 * 60
    /// How many folders a scan may find.
    public var folderLimit = 5_000_000
    /// True when the last `run` ended because of `timeLimit` or `folderLimit`.
    public private(set) var reachedLimit = false
    /// The folder the scan starts at.
    private let root: URL
    /// The file system it reads.
    private let provider: any FileSystemProvider
    /// Whether hidden folders are read and listed.
    private let showHidden: Bool
    /// Folders listed but not read (other volumes mounted inside this one).
    private let isExcluded: @Sendable (URL) -> Bool
    /// How many folders are read before their results are handed over.
    private let batchSize: Int
    /// Every folder found so far as a relative path, parents before their children: the form
    /// the cache stores.
    public private(set) var paths: [String] = []
    /// The folders among `paths` that were not read: left out on purpose, or not reached
    /// before the scan was cancelled.
    public private(set) var unscanned: [String] = []

    /// Folders for which `isExcluded` answers true are listed in the tree but not read (other
    /// volumes mounted inside this one).
    ///
    /// Folders on the local disk that are a mount point themselves are left unread as well,
    /// whatever `isExcluded` says. It is called on several threads at once.
    @preconcurrency
    public init(
        root: URL,
        provider: any FileSystemProvider,
        showHidden: Bool = false,
        batchSize: Int = 256,
        isExcluded: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.root = root
        self.provider = provider
        self.showHidden = showHidden
        self.batchSize = max(batchSize, 1)
        self.isExcluded = isExcluded
    }

    /// Folders in the order the tree shows them.
    public static func sorted(_ folders: [(name: String, url: URL)]) -> [(name: String, url: URL)] {
        Sorter.sorted(folders, numeric: true, byName: \.name)
    }

    /// Reads the whole tree, the folders near the root first.
    ///
    /// Returns false when it was cancelled. Links to folders are listed nowhere, so the walk cannot
    /// run in circles; packages (`.app`) are files to the user and are left out as well. A folder
    /// that cannot be read counts as empty.
    @discardableResult
    public func run(receive: ([Level]) -> Void) -> Bool {
        var frontier: [(path: String, url: URL)] = [("", root)]
        paths = []
        unscanned = []
        reachedLimit = false
        let deadline = Date().addingTimeInterval(timeLimit)
        while !frontier.isEmpty {
            var next: [(path: String, url: URL)] = []
            for start in stride(from: 0, to: frontier.count, by: batchSize) {
                if !reachedLimit, paths.count >= folderLimit || Date() > deadline {
                    reachedLimit = true
                }
                if cancellation.isCancelled || reachedLimit {
                    return cancelled(frontier[start...], next)
                }
                let batch = Array(frontier[start..<min(start + batchSize, frontier.count)])
                let listed = readFolders(batch)
                if cancellation.isCancelled {
                    return cancelled(frontier[start...], next)
                }
                receive(zip(batch, listed).map { Level(path: $0.path, children: $1.map(\.name), isSorted: true) })
                for (folder, children) in zip(batch, listed) {
                    for child in children {
                        let path = folder.path.isEmpty ? child.name : folder.path + "/" + child.name
                        paths.append(path)
                        if child.isMount || child.isUnread || isExcluded(child.url) {
                            unscanned.append(path)
                        } else {
                            next.append((path, child.url))
                        }
                    }
                }
            }
            frontier = next
        }
        return true
    }

    /// The subfolders of a batch of folders, read side by side.
    ///
    /// On the local disk this is done with the threads of the caller's own priority (the scan runs
    /// at utility priority, and so does the disk work of these threads); a file system that may
    /// wait for a server uses the pool, which adds threads while some wait.
    private func readFolders(_ batch: [(path: String, url: URL)]) -> [[Subfolder]] {
        @Sendable
        func read(_ folder: (path: String, url: URL)) -> [Subfolder] {
            Self.gently { Sorter.sorted(folders(of: folder.url, isScan: true), numeric: true, byName: \.name) }
        }
        guard provider.scheme == "file", root.isFileURL else {
            return Parallel.map(batch, read)
        }
        // Each piece writes its own place.
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<[Subfolder]>.allocate(capacity: batch.count)
        results.initialize(repeating: [])
        defer {
            // The lists that were read are let go before the memory they are in.
            _ = results.deinitialize()
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: batch.count) { index in
            autoreleasepool { results[index] = read(batch[index]) }
        }
        return Array(results)
    }

    /// Notes the folders a stopped scan did not read: those of the level it was on from `unread` on (the root
    /// excepted), and those of the next level found so far; returns false.
    private func cancelled(
        _ unread: ArraySlice<(path: String, url: URL)>,
        _ found: [(path: String, url: URL)]
    ) -> Bool {
        unscanned += unread.dropFirst(unread.first?.path.isEmpty == true ? 1 : 0).map(\.path) + found.map(\.path)
        return false
    }

    /// One level, for a folder the user opens before the scan has reached it.
    public func subfolders(of directory: URL) -> [(name: String, url: URL)] {
        folders(of: directory, isScan: false).map { ($0.name, $0.url) }
    }

    /// `isScan`: the folders are read for the scan, which does not go into protected ones; a
    /// folder the user opens is read whatever it is.
    private func folders(of directory: URL, isScan: Bool) -> [Subfolder] {
        // The local disk is read entry by entry, and given up at the first entry after a cancellation.
        if directory.isFileURL, provider.scheme == "file" {
            return leanSubfolders(of: directory, isScan: isScan)
        }
        guard !cancellation.isCancelled else {
            return []
        }
        // Read piece by piece, so a huge or slow folder can be given up half-way.
        var items: [FileItem] = []
        let finished: Void? = try? provider.list(directory, showHidden: showHidden) { batch in
            items += batch
            return !cancellation.isCancelled
        }
        guard finished != nil, !cancellation.isCancelled else {
            return []
        }
        // A name with a line break could not be written to the cache file, one with a slash
        // not into a relative path.
        return
            items.filter { item in
                item.isRealDirectory && !item.isPackage && !item.name.utf8.contains(0x0A)
                    && !item.name.utf8.contains(0x2F)
            }
            .map { Subfolder(name: $0.name, url: $0.url) }
    }

    /// The same for a folder of the local disk, without a `FileItem` for every file: only the
    /// folders are asked about.
    ///
    /// Hidden folders and packages are left out as a listing leaves them out. A folder that cannot
    /// be opened counts as empty.
    private func leanSubfolders(of directory: URL, isScan: Bool) -> [Subfolder] {
        guard let stream = opendir(directory.path) else {
            return []
        }
        defer { closedir(stream) }
        // The folder's own device; should it not be told, every subfolder is asked whether it is a mount point.
        var own = stat()
        _ = fstat(dirfd(stream), &own)
        var folders: [Subfolder] = []
        while let entry = readdir(stream) {
            if cancellation.isCancelled {
                return []
            }
            if let folder = subfolder(entry.pointee, of: directory, device: own.st_dev, isScan: isScan) {
                folders.append(folder)
            }
        }
        return folders
    }

    /// The subfolder a directory entry names; nil when it is no folder, a hidden one that is not wanted, or a
    /// package.
    ///
    /// `device` is the device of the folder the entry is in (a subfolder on another may be a mount point).
    private func subfolder(_ entry: dirent, of directory: URL, device: dev_t, isScan: Bool) -> Subfolder? {
        var entry = entry
        let name = withUnsafePointer(to: &entry.d_name) { bytes in
            bytes.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) { String(cString: $0) }
        }
        guard name != ".", name != "..", !name.contains("\n") else {
            return nil
        }
        let url = directory.appending(name: name)
        var info = stat()
        var isMount = false
        var isUnread = false
        switch Int32(entry.d_type) {
        case DT_DIR:
            // Only a flag of the folder can still hide it; it is looked at when hidden folders are not wanted.
            if !showHidden, name.hasPrefix(".") {
                return nil
            }
            let known = lstat(url.path, &info) == 0
            if !showHidden {
                guard known, info.st_flags & UInt32(UF_HIDDEN) == 0 else {
                    return nil
                }
            }
            isMount = known && info.st_dev != device && Self.isMountPoint(url.path)
            // A folder that is only in the cloud (SF_DATALESS) would be fetched by a listing.
            isUnread = isScan && (Self.isProtected(url) || (known && info.st_flags & Self.dataless != 0))

        case DT_UNKNOWN:
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                return nil
            }
            if !showHidden, name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 {
                return nil
            }
            isUnread = isScan && (Self.isProtected(url) || info.st_flags & Self.dataless != 0)

        default:
            return nil
        }
        // Only a folder with an extension can be a package.
        if !url.pathExtension.isEmpty, (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
            return nil
        }
        return Subfolder(name: name, url: url, isMount: isMount, isUnread: isUnread)
    }

    deinit {
        // Nothing to release.
    }
}
