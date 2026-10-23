import Foundation

/// What the scan asks of the system: the places it does not go into, mount points, and how gently it reads.
extension TreeScanner {
    /// Where a scan does not go on its own: the folders macOS asks the user's permission for
    /// and the cloud folders, in the home folder, and the automounts.
    ///
    /// Whole paths.
    private static let protectedPaths: Set<String> = {
        let home = NSHomeDirectory()
        var protected: Set<String> = [
            "/net", "/home", "/Network", "/dev", "/System/Volumes", "/Volumes", "/private/var/db"
        ]
        for relative in [
            "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library/Mobile Documents",
            "Library/CloudStorage", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers",
            "Library/Group Containers", "Library/Calendars", "Library/Cookies", "Library/HomeKit", "Library/Metadata",
            "Library/Suggestions", "Library/Reminders", "Library/Application Support/AddressBook",
            "Library/Application Support/CallHistoryDB", "Library/Application Support/CallHistoryTransactions",
            "Library/Application Support/FileProvider", "Library/Application Support/CloudDocs",
            "Library/Application Support/com.apple.TCC", "Library/Application Support/Knowledge"
        ] {
            protected.insert(home + "/" + relative)
        }
        return protected
    }()

    /// The flag of a folder or file whose content is in the cloud only (`SF_DATALESS`).
    internal static let dataless: UInt32 = 0x4000_0000

    /// Whether a scan leaves this folder unread.
    internal static func isProtected(_ url: URL) -> Bool {
        url.isFileURL && protectedPaths.contains(url.path)
    }

    /// Runs `body` with the disk work of this thread at the lowest priority, as far as the
    /// system lets a thread do that (not a pool thread of Dispatch, which then runs at its
    /// quality-of-service class's priority), and without the system fetching a file or folder
    /// that is only in the cloud, which a listing would do.
    internal static func gently<T>(_ body: () -> T) -> T {
        let (disk, cloud) = (
            getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD),
            getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        )
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        defer {
            // The threads are shared: they go back to what they had.
            if disk >= 0 {
                setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, disk)
            }
            if cloud >= 0 {
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, cloud)
            }
        }
        return body()
    }

    /// True when a disk is mounted at `path` itself.
    ///
    /// A device other than the parent's is not enough to say so: the user's folders on the start-up
    /// disk are firmlinked from the data volume, and the system answers with the volume's mount
    /// point for them, not their own.
    internal static func isMountPoint(_ path: String) -> Bool {
        // The system names the mount point by its real path; a path without one is none.
        guard let pointer = realpath(path, nil) else {
            return false
        }
        let real = String(cString: pointer)
        free(pointer)
        var info = statfs()
        return statfs(real, &info) == 0 && mountPoint(info) == real
    }

    /// Where the volume a `statfs` answer describes is mounted.
    private static func mountPoint(_ info: statfs) -> String {
        var info = info
        return withUnsafePointer(to: &info.f_mntonname) { name in
            name.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
