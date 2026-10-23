public import AFMKernel
import CryptoKit
import Foundation

/// Sorts found files into groups of duplicates.
///
/// **Threading.** `groups` blocks and is meant for a background thread. Comparing contents
/// means reading every candidate once; the files are hashed (SHA-256) on all cores at the
/// same time, each thread with its own reader. `onProgress` is called from those threads, one
/// call at a time.
public enum DuplicateFinder {
    private struct Key: Hashable {
        var name: String
        var size: Int64
        var digest = Data()
    }

    /// A group with the keys it is sorted by, made once per group and not once per comparison.
    private struct OrderedGroup {
        var files: [FileItem]
        var loweredName: String
        var nameKey: Sorter.NameKey?
        var pathKey: Sorter.NameKey
    }

    /// How reading one block of a file went.
    private enum BlockRead {
        case cancelled
        case ended
        case hashed
    }

    /// A disk that is somebody else's: a share of a server, mounted here.
    internal struct Mount {
        /// What the system calls the source of the mount (`smbfs://user@host/share`).
        internal let source: String
        /// Where the share is mounted (`/Volumes/share`).
        internal let mountPoint: String

        /// The mount that holds `url`, when it is not a local disk; nil otherwise.
        internal static func of(_ url: URL) -> Self? {
            var info = statfs()
            func text<T>(_ field: T) -> String {
                withUnsafePointer(to: field) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
                }
            }
            guard statfs(url.path, &info) == 0, info.f_flags & UInt32(MNT_LOCAL) == 0,
                case let source = text(info.f_mntfromname), !source.isEmpty
            else {
                return nil
            }
            return Self(source: text(info.f_fstypename) + ":" + source, mountPoint: text(info.f_mntonname))
        }

        /// The file in the share, as the same text for every place the share is mounted at.
        internal func place(of path: String) -> String {
            var inside = path
            if path.utf8.starts(with: mountPoint.utf8) {
                inside = String(path[path.utf8.index(path.startIndex, offsetBy: mountPoint.utf8.count)...])
            }
            return source + (inside.hasPrefix("/") ? "" : "/") + inside
        }
    }

    /// The groups of two or more files that are equal by the ticked criteria.
    ///
    /// Groups are in the order of the first ticked criterion (name, then size), the files of a
    /// group in path order. A cancelled run returns nothing, so no half-compared files are shown.
    @preconcurrency
    public static func groups(
        of items: [FileItem],
        options: DuplicateOptions,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [[FileItem]] {
        guard options.isActive else {
            return []
        }
        var keyed = items.filter { !$0.isDirectory && !$0.isSpecial }
            .map { (key: key(of: $0, options: options), item: $0) }
        keyed = withoutSingles(keyed)
        keyed = withoutSingles(distinctFiles(keyed, mountOf: Mount.of))
        if options.sameContents {
            keyed = withEqualContents(
                keyed,
                fileSystems: fileSystems,
                cancellation: cancellation,
                onProgress: onProgress
            )
        }
        guard !cancellation.isCancelled else {
            return []
        }
        let groups = Dictionary(grouping: keyed, by: \.key).values
            .map { group in
                Sorter.sorted(group.map(\.item), numeric: true) { $0.url.path }
            }
        return ordered(groups, options: options)
    }

    /// Leaves out what cannot be a duplicate to delete: FIFOs and devices (they are no
    /// files to compare, and reading them blocks or never ends), and every path to a file
    /// already in the list, whether a link, a hard link or the same folder reached by two roads
    /// (deleting the "other" copy would delete the only one).
    ///
    /// The first path stays.
    ///
    /// `mountOf` tells the share that holds a local file, if any (`Mount.of`).
    internal static func distinctFiles<Entry: Sendable>(
        _ keyed: [(key: Entry, item: FileItem)],
        mountOf: (URL) -> Mount?
    ) -> [(key: Entry, item: FileItem)] {
        let identities = Parallel.map(keyed) { FileIdentity.of($0.item.url) }
        var seen = Set<FileIdentity>()
        // A file on a server has no device and inode to tell it by; the same place written two
        // ways (`sftp://HOST/a`, `sftp://host/a/`) must still not be a group with itself.
        var seenPlaces = Set<String>()
        // One share mounted at two places has a device of its own at each, so the same file there
        // has two identities: it is told by the share and the path in it.
        var mounts: [UInt64: Mount?] = [:]
        // Whether the place of a local file in its share was not seen yet (always on a local disk).
        func isNewPlace(_ url: URL, device: UInt64) -> Bool {
            let mount: Mount?
            if let known = mounts[device] {
                mount = known
            } else {
                mount = mountOf(url)
                mounts[device] = .some(mount)
            }
            guard let mount else {
                return true
            }
            return seenPlaces.insert(mount.place(of: url.path)).inserted
        }
        var result: [(key: Entry, item: FileItem)] = []
        for (entry, found) in zip(keyed, identities) {
            if let found {
                // (An identity is found for local files only.)
                guard found.isRegularFile, seen.insert(found.identity).inserted,
                    isNewPlace(entry.item.url, device: found.identity.device)
                else {
                    continue
                }
            } else if entry.item.url.isFileURL {
                continue
            } else {
                guard seenPlaces.insert(FileSearch.locationKey(of: entry.item.url)).inserted else {
                    continue
                }
            }
            result.append(entry)
        }
        return result
    }

    /// The SHA-256 of a file's contents, read in blocks; nil when it cannot be read or the
    /// work was cancelled.
    internal static func digest(
        of url: URL,
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag
    ) -> Data? {
        // A local file is opened without waiting and looked at once opened; one that is only a
        // stub of a file in the cloud is not read (that would download it).
        guard !cancellation.isCancelled, let reader = fileSystems.searchReader(for: url, cancellation: cancellation)
        else {
            return nil
        }
        defer { reader.close() }
        // A read blocked on a server ends when the run is cancelled.
        let token = cancellation.interrupting(reader)
        defer {
            withExtendedLifetime(token) {
                // The token interrupts the reader until here.
            }
        }
        var hash = SHA256()
        do {
            while true {
                let read: BlockRead = try autoreleasepool {
                    guard let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else {
                        return .ended
                    }
                    if cancellation.isCancelled {
                        return .cancelled
                    }
                    hash.update(data: block)
                    return .hashed
                }
                switch read {
                case .cancelled:
                    return nil

                case .ended:
                    return Data(hash.finalize())

                case .hashed:
                    continue
                }
            }
        } catch {
            return nil
        }
    }

    /// The key an item is grouped by: its name (when the names count) and its size.
    private static func key(of item: FileItem, options: DuplicateOptions) -> Key {
        // Equal contents imply equal sizes, so the size narrows the candidates for free.
        Key(
            name: options.sameName ? item.name.lowercased() : "",
            size: options.sameSize || options.sameContents ? item.size : -1
        )
    }

    /// The entries with the digest of their contents in the key, hashed on all cores.
    ///
    /// A file that could not be read is equal to nothing and is left out.
    private static func withEqualContents(
        _ keyed: [(key: Key, item: FileItem)],
        fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) -> [(key: Key, item: FileItem)] {
        let lock = NSLock()
        // Guarded by `lock`.
        nonisolated(unsafe) var done = 0
        let total = keyed.count
        let digests = Parallel.map(keyed) { entry -> Data? in
            let found = digest(of: entry.item.url, fileSystems: fileSystems, cancellation: cancellation)
            lock.lock()
            done += 1
            onProgress?(done, total)
            lock.unlock()
            return found
        }
        return withoutSingles(
            zip(keyed, digests)
                .compactMap { entry, digest in
                    digest.map { contents in
                        var key = entry.key
                        key.digest = contents
                        return (key, entry.item)
                    }
                }
        )
    }

    /// The groups in the order of the first ticked criterion (name, then size), then by the path of the first file.
    private static func ordered(_ groups: [[FileItem]], options: DuplicateOptions) -> [[FileItem]] {
        let keyed = groups.map { group in
            let first = group[0]
            return OrderedGroup(
                files: group,
                loweredName: options.sameName ? first.name.lowercased() : "",
                nameKey: options.sameName ? Sorter.key(of: first.name) : nil,
                pathKey: Sorter.key(of: first.url.path, numeric: true)
            )
        }
        return
            keyed.sorted { first, second in
                if options.sameName, first.loweredName != second.loweredName, let firstName = first.nameKey,
                    let secondName = second.nameKey
                {
                    return firstName < secondName
                }
                if first.files[0].size != second.files[0].size {
                    return first.files[0].size < second.files[0].size
                }
                return first.pathKey < second.pathKey
            }
            .map(\.files)
    }

    private static func withoutSingles(_ keyed: [(key: Key, item: FileItem)]) -> [(key: Key, item: FileItem)] {
        // The keys that more than one entry has.
        var seen = Set<Key>()
        var repeated = Set<Key>()
        for entry in keyed where !seen.insert(entry.key).inserted {
            repeated.insert(entry.key)
        }
        return keyed.filter { repeated.contains($0.key) }
    }
}
