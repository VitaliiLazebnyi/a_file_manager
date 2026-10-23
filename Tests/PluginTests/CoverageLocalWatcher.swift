import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The watcher: streams the system refuses, folders asked for again, the figures printed at the end.
@Suite
internal struct CoverageLocalWatcher {
    /// A folder the system cannot watch is tried again.
    @Test
    internal func aFolderTheSystemCannotWatchIsTriedAgain() throws {
        let box = try Sandbox()
        let before = FSEvCensus.figures.refused
        let tries = Shared(0)
        // A system that makes no stream (and touches no descriptor).
        let refusing = FSEvSystem(
            makeStream: { _, _, _ in
                tries.modify { $0 += 1 }
                return nil
            },
            spareDescriptors: { 1_000 }
        )
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "coverage"), system: refusing) { _ in
            // Nothing is looked at.
        }
        watcher.watch([box.url("a")])
        #expect(Wait.until { tries.value >= 1 })
        // Asked for again while a try is pending: refused again, and still tried once.
        watcher.watch([box.url("a"), box.url("b")])
        // Each request that gets no stream is one refusal, whatever number of folders it has: two
        // so far (three when a try again came first, which a busy machine may not get to).
        #expect(Wait.until { tries.value >= 3 && FSEvCensus.figures.refused >= before + 2 })
        #expect(watcher.watchedFolders.isEmpty)
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
            Wait.until {
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
    ///
    /// The process of its own only counts a stream and ends: it makes no stream and waits for
    /// nothing, so it is over at once also on a busy machine (where a child that waited for the
    /// system's stream once lost its channel to the test).
    @Test
    internal func theFiguresArePrintedAtTheEndWhenAskedFor() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardErrorContent]) {
            setenv("AFM_WATCHER_CENSUS", "1", 1)
            FSEvCensus.started()
            FSEvCensus.wasRefused()
            exit(0)
        }
        let printed = String(bytes: result.standardErrorContent, encoding: .utf8)
        #expect(printed?.contains("AFM_WATCHER_CENSUS live=1 peak=1 refused=1") == true)
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
            guard Wait.until(seconds: Wait.ceiling, { FSEvCensus.figures.refused >= 2 * 20 }) else { exit(1) }
            exit(0)
        }
    }
}
