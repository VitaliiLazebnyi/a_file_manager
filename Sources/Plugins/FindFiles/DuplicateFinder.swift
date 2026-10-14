import AFMKernel
import CryptoKit
import Foundation

/// "Find duplicate files" of the Advanced tab (spec 09 › Duplicate finder). The ticked
/// sub-criteria must all hold between the files of a group.
public struct DuplicateOptions: Codable, Equatable {
    public var isEnabled: Bool
    public var sameName: Bool
    public var sameSize: Bool
    public var sameContents: Bool

    public init(isEnabled: Bool = false, sameName: Bool = true, sameSize: Bool = true, sameContents: Bool = false) {
        self.isEnabled = isEnabled
        self.sameName = sameName
        self.sameSize = sameSize
        self.sameContents = sameContents
    }

    /// With no sub-criterion ticked the option counts as off.
    public var isActive: Bool { isEnabled && (sameName || sameSize || sameContents) }
}

/// Sorts found files into groups of duplicates.
///
/// **Threading.** `groups` blocks and is meant for a background thread. Comparing contents
/// means reading every candidate once; the files are hashed (SHA-256) on all cores at the
/// same time, each thread with its own reader. `onProgress` is called from those threads, one
/// call at a time.
public enum DuplicateFinder {
    private struct Key: Hashable {
        var name = ""
        var size: Int64 = -1
        var digest = Data()
    }

    /// The groups of two or more files that are equal by the ticked criteria. Groups are in
    /// the order of the first ticked criterion (name, then size), the files of a group in path
    /// order. A cancelled run returns nothing, so no half-compared files are shown.
    public static func groups(
        of items: [FileItem], options: DuplicateOptions, fileSystems: FileSystemRegistry,
        cancellation: CancellationFlag = CancellationFlag(), onProgress: ((Int, Int) -> Void)? = nil
    ) -> [[FileItem]] {
        guard options.isActive else { return [] }
        func key(_ item: FileItem) -> Key {
            // Equal contents imply equal sizes, so the size narrows the candidates for free.
            Key(
                name: options.sameName ? item.name.lowercased() : "",
                size: options.sameSize || options.sameContents ? item.size : -1)
        }
        var keyed = items.filter { !$0.isDirectory && !$0.isSpecial }.map { (key: key($0), item: $0) }
        keyed = withoutSingles(keyed)
        keyed = withoutSingles(distinctFiles(keyed))
        if options.sameContents {
            let lock = NSLock()
            var done = 0
            let total = keyed.count
            let digests = Parallel.map(keyed) { entry -> Data? in
                let digest = digest(of: entry.item.url, fileSystems: fileSystems, cancellation: cancellation)
                lock.lock()
                done += 1
                onProgress?(done, total)
                lock.unlock()
                return digest
            }
            // A file that could not be read is equal to nothing.
            keyed = withoutSingles(
                zip(keyed, digests).compactMap { entry, digest in
                    digest.map { digest in
                        var key = entry.key
                        key.digest = digest
                        return (key, entry.item)
                    }
                })
        }
        guard !cancellation.isCancelled else { return [] }
        let groups = Dictionary(grouping: keyed, by: \.key).values.map { group in
            Sorter.sorted(group.map(\.item), numeric: true) { $0.url.path }
        }
        // The keys of the names and paths are made once per group, not once per comparison.
        let ordered = groups.map {
            group -> (group: [FileItem], lowered: String, name: Sorter.NameKey?, path: Sorter.NameKey) in
            let first = group[0]
            return (
                group, options.sameName ? first.name.lowercased() : "",
                options.sameName ? Sorter.key(of: first.name) : nil,
                Sorter.key(of: first.url.path, numeric: true)
            )
        }
        return ordered.sorted { first, second in
            if options.sameName, first.lowered != second.lowered, let a = first.name, let b = second.name {
                return a < b
            }
            if first.group[0].size != second.group[0].size { return first.group[0].size < second.group[0].size }
            return first.path < second.path
        }.map { $0.group }
    }

    /// Leaves out what cannot be a duplicate to delete: FIFOs and devices (they are no
    /// files to compare, and reading them blocks or never ends), and every path to a file
    /// already in the list, whether a link, a hard link or the same folder reached by two roads
    /// (deleting the "other" copy would delete the only one). The first path stays.
    private static func distinctFiles(_ keyed: [(key: Key, item: FileItem)]) -> [(key: Key, item: FileItem)] {
        let identities = Parallel.map(keyed) { FileIdentity.of($0.item.url) }
        var seen = Set<FileIdentity>()
        // A file on a server has no device and inode to tell it by; the same place written two
        // ways (`sftp://HOST/a`, `sftp://host/a/`) must still not be a group with itself.
        var seenPlaces = Set<String>()
        // One share mounted at two places has a device of its own at each, so the same file there
        // has two identities: it is told by the share and the path in it.
        var mounts: [UInt64: Mount?] = [:]
        var result: [(key: Key, item: FileItem)] = []
        for (entry, found) in zip(keyed, identities) {
            if let found {
                guard found.isRegularFile, seen.insert(found.identity).inserted else { continue }
                if entry.item.url.isFileURL {
                    let mount: Mount?
                    if let known = mounts[found.identity.device] {
                        mount = known
                    } else {
                        mount = Mount.of(entry.item.url)
                        mounts[found.identity.device] = .some(mount)
                    }
                    if let mount, !seenPlaces.insert(mount.place(of: entry.item.url.path)).inserted { continue }
                }
            } else if entry.item.url.isFileURL {
                continue
            } else {
                guard seenPlaces.insert(FileSearch.locationKey(of: entry.item.url)).inserted else { continue }
            }
            result.append(entry)
        }
        return result
    }

    /// A disk that is somebody else's: a share of a server, mounted here.
    struct Mount {
        /// What the system calls the source of the mount (`//user@host/share`), and where it is mounted.
        let from: String
        let on: String

        /// The mount that holds `url`, when it is not a local disk; nil otherwise.
        static func of(_ url: URL) -> Mount? {
            var info = statfs()
            guard url.withUnsafeFileSystemRepresentation({ $0.map { statfs($0, &info) } ?? -1 }) == 0,
                info.f_flags & UInt32(MNT_LOCAL) == 0
            else { return nil }
            func text<T>(_ field: T) -> String {
                withUnsafePointer(to: field) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
                }
            }
            let (from, on) = (text(info.f_mntfromname), text(info.f_mntonname))
            return from.isEmpty ? nil : Mount(from: text(info.f_fstypename) + ":" + from, on: on)
        }

        /// The file in the share, as the same text for every place the share is mounted at.
        func place(of path: String) -> String {
            let inside =
                path.utf8.starts(with: on.utf8)
                ? String(decoding: Array(path.utf8.dropFirst(on.utf8.count)), as: UTF8.self) : path
            return from + (inside.hasPrefix("/") ? "" : "/") + inside
        }
    }

    private static func withoutSingles(_ keyed: [(key: Key, item: FileItem)]) -> [(key: Key, item: FileItem)] {
        var counts: [Key: Int] = [:]
        for entry in keyed { counts[entry.key, default: 0] += 1 }
        return keyed.filter { (counts[$0.key] ?? 0) > 1 }
    }

    /// The SHA-256 of a file's contents, read in blocks; nil when it cannot be read or the
    /// work was cancelled.
    static func digest(
        of url: URL, fileSystems: FileSystemRegistry, cancellation: CancellationFlag = CancellationFlag()
    ) -> Data? {
        // A local file is opened without waiting and looked at once opened; one that is only a
        // stub of a file in the cloud is not read (that would download it).
        guard !cancellation.isCancelled, let reader = fileSystems.searchReader(for: url, cancellation: cancellation)
        else { return nil }
        defer { reader.close() }
        // A read blocked on a server ends when the run is cancelled.
        let token = cancellation.interrupting(reader)
        defer { withExtendedLifetime(token) {} }
        var hash = SHA256()
        do {
            while true {
                let more: Bool? = try autoreleasepool {
                    guard let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else { return false }
                    if cancellation.isCancelled { return nil }
                    hash.update(data: block)
                    return true
                }
                guard let more else { return nil }
                if !more { break }
            }
        } catch {
            return nil
        }
        return Data(hash.finalize())
    }
}
