import Foundation

/// Where the volumes of the local file system are mounted and which of them are on this machine.
///
/// The system answers from what it has in memory, without asking any disk or server
/// (`MNT_NOWAIT`), so this may be asked on the main thread; the answer is kept for a moment,
/// because lists ask for every row they draw. Safe to use from any thread.
internal enum Mounts {
    /// One mounted volume.
    internal struct Volume: Equatable {
        /// Where it is mounted.
        internal let path: String
        /// False for network shares.
        internal let isLocal: Bool
    }

    /// How long an answer of the system is used again, in seconds.
    internal static let lifetime: TimeInterval = 2
    /// Guards `cached`, and keeps the calls to the system apart.
    private static let lock = NSLock()
    /// The last answer and when it came (in the system's uptime), guarded by `lock`.
    nonisolated(unsafe) private static var cached: (at: TimeInterval, volumes: [Volume])?

    /// The mounted volumes; `/` alone when the system does not say.
    internal static func volumes() -> [Volume] {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < lifetime {
            return cached.volumes
        }
        // The system's list lives in a buffer of its own that the next call overwrites; the
        // lock keeps the calls apart.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        var volumes: [Volume] = []
        if count > 0, let buffer {
            volumes = (0..<Int(count))
                .map { index in
                    let path = withUnsafePointer(to: &buffer[index].f_mntonname) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                    }
                    return Volume(path: path, isLocal: buffer[index].f_flags & UInt32(MNT_LOCAL) != 0)
                }
        }
        if volumes.isEmpty {
            volumes = [Volume(path: "/", isLocal: true)]
        }
        cached = (now, volumes)
        return volumes
    }

    /// The volume a local path lies on: the one with the longest mount point that holds it.
    internal static func volume(of path: String, among volumes: [Volume]) -> Volume? {
        volumes.filter { holds($0.path, path) }.max { $0.path.utf8.count < $1.path.utf8.count }
    }

    /// Whether a local path lies on a volume of this machine; true where the volume is not known.
    internal static func isLocal(path: String) -> Bool {
        volume(of: path, among: volumes())?.isLocal ?? true
    }

    /// Whether the volume mounted at `mountPoint` holds `path`: it is the mount point, or a path
    /// inside it (not one that merely starts with the same letters).
    private static func holds(_ mountPoint: String, _ path: String) -> Bool {
        guard mountPoint != "/", path != mountPoint else {
            return true
        }
        let mount = mountPoint.utf8
        let full = path.utf8
        return full.starts(with: mount) && full.dropFirst(mount.count).first == UInt8(ascii: "/")
    }
}
