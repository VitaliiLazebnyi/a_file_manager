import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The watcher: a folder that is renamed, and requests that change nothing or watch nothing.
@Suite
internal struct CoverageLocalWatcherMore {
    /// A watched folder that is renamed is reported as changed.
    @Test
    internal func aWatchedFolderThatIsRenamedIsReportedAsChanged() throws {
        let box = try Sandbox()
        let folder = try box.folder("watched")
        let changed = Shared(false)
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "coverage")) { folders in
            if folders.contains(where: { $0.lastPathComponent == "watched" }) { changed.value = true }
        }
        defer { watcher.stop() }
        watcher.watch([folder])
        #expect(Wait.until { !watcher.watchedFolders.isEmpty })
        var count = 0
        // The stream may begin a moment after it was made, and on a busy machine the system may
        // report much later still: renamed until it is heard, with no limit short of a hang.
        #expect(
            Wait.until {
                count += 1
                let (old, new) = count.isMultiple(of: 2) ? ("renamed", "watched") : ("watched", "renamed")
                try? FileManager.default.moveItem(at: box.url(old), to: box.url(new))
                return Wait.until(seconds: 1.5) { changed.value }
            }
        )
    }

    /// Requests that change nothing or watch nothing.
    @Test
    internal func requestsThatChangeNothingOrWatchNothing() throws {
        let box = try Sandbox()
        try box.folder("a")
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "coverage")) { _ in
            // Nothing is looked at.
        }
        defer { watcher.stop() }
        let folders = [box.url("a"), box.url("gone")]
        watcher.watch(folders)
        #expect(Wait.until { watcher.watchedFolders == Set(folders) })
        // Asked for again: all are known, nothing is resolved or made anew.
        watcher.watch(folders)
        #expect(watcher.watchedFolders == Set(folders))
        watcher.watch([])
        #expect(watcher.watchedFolders.isEmpty)
    }
}
