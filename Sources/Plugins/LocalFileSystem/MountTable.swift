import Foundation

/// The mounted file systems, as the kernel lists them.
///
/// Reading the list never touches a mounted disk (`MNT_NOWAIT`), so it is safe to ask on any thread
/// about a path on a share that has stopped answering. Kept for a moment and then read again. All
/// state is guarded by `lock`.
internal final class MountTable: @unchecked Sendable {
    /// One mounted file system.
    internal struct Mount {
        /// The folder it is mounted on.
        internal let path: String
        /// A disk of this Mac.
        ///
        /// False for shares, and for automounted paths, which look local and fetch their contents
        /// from a server on first use.
        internal let isLocal: Bool
    }

    /// The table of the program, read again when it is a moment old.
    internal static let shared = MountTable()
    private static let lifetime: UInt64 = 2_000_000_000

    /// The start-up disk, on which every path lies that lies on no other mount.
    internal static let root = Mount(path: "/", isLocal: true)

    private let lock = NSLock()
    private var mounts: [Mount] = []
    private var read: UInt64 = 0

    /// The folder the file system that `info` describes is mounted on.
    internal static func mountPoint(of info: statfs) -> String { text(of: info.f_mntonname) }

    /// The text in one of the fixed-size fields of a `statfs`: everything before the first zero
    /// byte (the system always ends it with one), with bytes that are not UTF-8 repaired.
    private static func text(of field: some Any) -> String {
        withUnsafeBytes(of: field) { bytes in
            let text = bytes.prefix { $0 != 0 }
            return String(unsafeUninitializedCapacity: text.count) { buffer in buffer.initialize(fromContentsOf: text) }
        }
    }

    private static func readMounts() -> [Mount] {
        // (A failure, -1, counts as none.)
        let count = max(getfsstat(nil, 0, MNT_NOWAIT), 0)
        var buffer = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + 8)
        let size = Int32(buffer.count * MemoryLayout<statfs>.stride)
        let filled = max(getfsstat(&buffer, size, MNT_NOWAIT), 0)
        let found = buffer.prefix(Int(filled))
            .map { info -> Mount in
                let isLocalDisk =
                    info.f_flags & UInt32(MNT_LOCAL) != 0 && info.f_flags & UInt32(MNT_AUTOMOUNTED) == 0
                    && text(of: info.f_fstypename) != "autofs"
                return Mount(path: mountPoint(of: info), isLocal: isLocalDisk)
            }
        // The deepest mount first, so that the first that contains a path is the one it is on;
        // the start-up disk is `root`.
        return found.filter { $0.path != "/" }.sorted { $0.path.utf8.count > $1.path.utf8.count }
    }

    /// Called with the lock held.
    private func refresh() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard read == 0 || now &- read > Self.lifetime else {
            return
        }
        mounts = Self.readMounts()
        read = now
    }

    /// The mount a path lies on (by its text: the path is not looked at on disk).
    internal func mount(containing path: String) -> Mount {
        lock.lock()
        refresh()
        let current = mounts
        lock.unlock()
        return current.first { mount in path == mount.path || path.hasPrefix(mount.path + "/") } ?? Self.root
    }

    /// Whether the path lies on a disk of this Mac (by its text, as `mount(containing:)`).
    internal func isLocal(_ path: String) -> Bool { mount(containing: path).isLocal }

    deinit {
        // Nothing to release.
    }
}
