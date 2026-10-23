import Foundation

/// Questions about the volumes files lie on: free room, the device, and what lies at a path, asked
/// without ever waiting for a volume that may not answer (a server that is gone).
internal enum Volume {
    /// What lies at a path, as `kind(ofLocalPath:)` finds it.
    internal enum PathKind {
        /// A folder.
        case directory
        /// Nothing, or a path that runs through something that is not a folder.
        case missing
        /// Something else: a device, a socket, a pipe.
        case other
        /// A file.
        case regularFile
        /// On a volume that may not answer (a server): it was not asked.
        case unasked
    }

    private static let mountLock = NSLock()
    /// Guarded by `mountLock`.
    nonisolated(unsafe) private static var mounts: (read: DispatchTime, points: [(path: [UInt8], isLocal: Bool)])?

    /// Whether `needed` bytes can be written into `folder`: what the volume counts as free, or
    /// what the system says it can make free for important work.
    ///
    /// True when the volume cannot be asked.
    internal static func hasRoom(for needed: UInt64, at folder: URL) -> Bool {
        var info = statfs()
        guard statfs(folder.path, &info) == 0 else {
            return true
        }
        if UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize)).partialValue >= needed {
            return true
        }
        // The system can make more room than it counts as free; it is asked before a write is refused.
        guard
            let more = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage,
            more > 0
        else {
            return false
        }
        return UInt64(more) >= needed
    }

    /// The volume a path lies on, as a number; nil when the path cannot be asked.
    internal static func device(of path: String) -> dev_t? {
        var status = stat()
        return stat(path, &status) == 0 ? status.st_dev : nil
    }

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
    /// of mounts alone.
    ///
    /// Asking such a path about itself does not hang on a server that is gone.
    internal static func isOnLocalVolume(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.first == 0x2F else {
            return false
        }
        var found = false
        for point in mountPoints() {
            let isPrefix =
                point.path == [0x2F]
                || (bytes.starts(with: point.path)
                    && (bytes.count == point.path.count || bytes[point.path.count] == 0x2F))
            guard isPrefix else { continue }
            guard point.isLocal else {
                return false
            }
            found = true
        }
        return found
    }

    /// What lies at an absolute path, found without ever asking a volume that is not a disk
    /// of this machine: the path is walked name by name, links are followed by hand, and the
    /// walk stops with `.unasked` where it would leave the local disks.
    ///
    /// Fast, and safe on the main thread.
    internal static func kind(ofLocalPath path: String) -> PathKind {
        var current = path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        for _ in 0..<16 {
            guard isOnLocalVolume(current) else {
                return .unasked
            }
            let names = ArchiveTree.names(of: current)
            var prefix = ""
            var redirected = false
            for (index, name) in names.enumerated() {
                // The folder the name lies in (the top folder is "").
                let folder = prefix
                prefix += "/" + name
                var status = stat()
                guard lstat(prefix, &status) == 0 else {
                    return .missing
                }
                let type = status.st_mode & S_IFMT
                // (A link that cannot be read is taken for what it is: not a folder.)
                if type == S_IFLNK, case let length = readlink(prefix, &buffer, buffer.count), length > 0,
                    let target = String(bytes: buffer.prefix(length).map { UInt8(bitPattern: $0) }, encoding: .utf8)
                {
                    let base = target.hasPrefix("/") ? target : folder + "/" + target
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
                guard type == S_IFDIR else {
                    return .missing
                }
            }
            if !redirected {
                return .directory
            }
        }
        return .missing
    }
}
