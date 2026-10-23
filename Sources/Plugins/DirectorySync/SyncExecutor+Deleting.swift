import AFMKernel
import Foundation

/// Deleting: files, folders that are empty, and with "Delete all empty directories" every empty folder below one.
extension SyncExecutor {
    /// Deletes one item; returns false for a folder that still holds something (a file the user kept), which
    /// stays.
    internal func perform(_ deletion: SyncPlan.Deletion) throws -> Bool {
        let fileSystem = try fileSystems.provider(for: deletion.url)
        try fileSystems.flushPendingWrites(to: deletion.url, cancellation: cancellation)
        if deletion.isDirectory {
            let contents = try fileSystem.list(deletion.url, showHidden: true, cancellation: cancellation)
            // A listing that the cancel cut short is not an empty folder.
            if cancellation.isCancelled {
                throw Cancelled()
            }
            if !contents.isEmpty {
                return false
            }
        }
        try remove(deletion.url, in: fileSystem)
        outcome.deleted += 1
        return true
    }

    /// Moves the item to the Trash where the file system has one and the user wants it, else deletes it.
    private func remove(_ url: URL, in fileSystem: any FileSystemProvider) throws {
        if options.useTrash, fileSystem.capabilities(for: url).contains(.trash) {
            try fileSystem.trash(url)
        } else {
            try fileSystem.remove(url)
        }
    }

    /// Deletes the empty folders of a tree from the bottom up; returns whether `directory`
    /// itself is empty afterwards (never for the root, which stays).
    ///
    /// Failures are ignored: the folder simply stays.
    @discardableResult
    internal func removeEmptyDirectories(below directory: URL, isRoot: Bool) -> Bool {
        guard !cancellation.isCancelled, let fileSystem = try? fileSystems.provider(for: directory),
            let items = try? fileSystem.list(directory, showHidden: true, cancellation: cancellation),
            !cancellation.isCancelled
        else {
            return false
        }
        var isEmpty = true
        for item in items {
            guard item.isRealDirectory, removeEmptyDirectories(below: item.url, isRoot: false) else {
                isEmpty = false
                continue
            }
            if (try? remove(item.url, in: fileSystem)) != nil {
                outcome.deleted += 1
                changed[directory.locationKey] = directory
            } else {
                isEmpty = false
            }
        }
        return isEmpty && !isRoot
    }
}
