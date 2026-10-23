import Foundation

/// Clearing away list files.
extension CommandRunner {
    /// Removes the folders of earlier runs of the program that are no longer running.
    ///
    /// Folders are named by process number; another running instance keeps its own.
    nonisolated internal static func removeStaleListFolders(in parent: URL) {
        let manager = FileManager.default
        for url in (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = Int32(url.lastPathComponent) else { continue }
            if pid != getpid(), kill(pid, 0) == -1, errno == ESRCH { try? manager.removeItem(at: url) }
        }
    }

    /// Removes the list files earlier commands left behind, off the main thread.
    internal func removeListFiles() {
        let folder = listFolder
        onListQueue(
            { try? FileManager.default.removeItem(at: folder) },
            then: { _ in
                // Nothing waits for the removal.
            }
        )
    }

    /// For the moment the program quits (nothing dispatched is run then): removes the lists
    /// no started program can still be reading.
    ///
    /// A younger one stays; its folder is cleared away at the next start, when this process is
    /// gone.
    internal func removeListFilesNow() {
        let manager = FileManager.default
        let dated: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? manager.contentsOfDirectory(at: listFolder, includingPropertiesForKeys: dated)) ?? []
        var kept = 0
        for file in files {
            // A list without a date (gone meanwhile) is removed like an old one.
            if let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                Date().timeIntervalSince(written) < listGrace
            {
                kept += 1
            } else {
                try? manager.removeItem(at: file)
            }
        }
        if kept == 0 { try? manager.removeItem(at: listFolder) }
    }
}
