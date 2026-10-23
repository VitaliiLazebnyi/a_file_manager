import Darwin.C

/// What the local file system does to the thread it runs on.
extension LocalFileSystem {
    /// Runs `body` with the materialising of files that are only on a server (iCloud Drive,
    /// File Provider) switched off for this thread: a walk that measures a tree must not
    /// make the system download it.
    ///
    /// A folder that is not there yet then counts as nothing.
    internal static func withoutMaterializing<T>(_ body: () -> T) -> T {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3, IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1, _DEFAULT = 0
        let kind: Int32 = 3
        let scope = IOPOL_SCOPE_THREAD
        // (The policy of the thread itself can always be read; a failure would mean the default.)
        let previous = max(getiopolicy_np(kind, scope), 0)
        setiopolicy_np(kind, scope, 1)
        defer { setiopolicy_np(kind, scope, previous) }
        return body()
    }
}
