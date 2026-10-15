import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The watcher: streams the system refuses, folders asked for again, the figures printed at the end.
@Suite
internal struct CoverageLocalWatcher {
    /// A folder the system cannot watch is tried again.
    @Test
    internal func aFolderTheSystemCannotWatchIsTriedAgain() {
        let before = DirectoryWatcher.Census.figures.refused
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "coverage")) { _ in
            // Nothing is looked at.
        }
        // A path longer than any path can be: the system makes no stream for it.
        let impossible = URL(fileURLWithPath: "/" + String(repeating: "a", count: 5_000))
        watcher.watch([impossible])
        #expect(Wait.until(seconds: 60) { DirectoryWatcher.Census.figures.refused >= before + 1 })
        // Asked for again while a try is pending: refused again, and still tried once.
        watcher.watch([impossible, URL(fileURLWithPath: "/" + String(repeating: "b", count: 5_000))])
        #expect(Wait.until(seconds: 60) { DirectoryWatcher.Census.figures.refused >= before + 3 })
        watcher.stop()
    }

    /// Folders asked for again are not resolved again.
    @Test
    internal func foldersAskedForAgainAreNotResolvedAgain() throws {
        let box = try Sandbox()
        try box.folder("a")
        let changed = Shared(false)
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "coverage")) { folders in
            if folders.contains(where: { $0.lastPathComponent == "a" }) { changed.value = true }
        }
        // One folder by two names, and one that is not there.
        let folders = [
            URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/private/tmp"), box.url("a"), box.url("gone")
        ]
        watcher.watch(folders)
        // Once the stream runs, a change in `a` is reported.
        var count = 0
        #expect(
            Wait.until(seconds: 60) {
                count += 1
                try? "x".write(to: box.url("a/\(count).txt"), atomically: false, encoding: .utf8)
                return Wait.until(seconds: 0.5) { changed.value }
            }
        )
        // Asked for again, all of them are known: nothing is resolved or made anew.
        watcher.watch(folders)
        watcher.watch([])
        watcher.stop()
    }

    /// The figures are printed at the end when asked for.
    @Test
    internal func theFiguresArePrintedAtTheEndWhenAskedFor() async {
        await #expect(processExitsWith: .success) {
            setenv("AFM_WATCHER_CENSUS", "1", 1)
            let watcher = DirectoryWatcher(queue: DispatchQueue(label: "coverage")) { _ in
                // Nothing is looked at.
            }
            watcher.watch([URL(fileURLWithPath: NSTemporaryDirectory())])
            _ = Wait.until(seconds: 60) { DirectoryWatcher.Census.figures.live >= 1 }
            exit(0)
        }
    }

    /// Streams beyond what the system gives one program are refused and tried again.
    @Test
    internal func streamsBeyondWhatTheSystemGivesOneProgramAreRefusedAndTriedAgain() async {
        await #expect(processExitsWith: .success) {
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            let watchers = (0..<540)
                .map { _ in
                    DirectoryWatcher(queue: DispatchQueue(label: "coverage")) { _ in
                        // Nothing is looked at.
                    }
                }
            for watcher in watchers { watcher.watch([folder]) }
            // Refused, and refused again when tried again a moment later.
            guard Wait.until(seconds: 120, { DirectoryWatcher.Census.figures.refused >= 2 * 20 }) else { exit(1) }
            exit(0)
        }
    }
}
