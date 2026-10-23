import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import LocalFileSystemPlugin

/// The watcher: no waiting for the caller, one report for a burst, nothing after stop.
@Suite
internal struct Review2DirectoryWatcher {
    /// Starting to watch returns at once, even for hundreds of folders.
    @Test
    internal func startingToWatchReturnsAtOnceEvenForManyFolders() throws {
        let box = try Sandbox()
        let folders = (0..<500).map { box.url("f\($0)") }
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "test")) { _ in
            // Nothing to do with the reports here.
        }
        let start = DispatchTime.now().uptimeNanoseconds
        watcher.watch(folders)
        watcher.watch(Array(folders.prefix(3)))
        // Two calls that only note what is wanted; the stream is made behind them.
        #expect(DispatchTime.now().uptimeNanoseconds - start < 500_000_000)
        watcher.stop()
    }

    /// A flood of changes is reported at most twice a second, and nothing comes after `stop()`.
    @Test
    internal func aBurstOfChangesIsReportedInLumpsAndNothingComesAfterStop() async throws {
        let box = try Sandbox()
        try box.folder("watched")
        let count = Locked(0)
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "test")) { _ in count.withValue { $0 += 1 } }
        watcher.watch([box.url("watched")])
        let started = Date()
        var number = 0
        // A flood for a few seconds; the first report cannot come before the stream runs.
        while Date().timeIntervalSince(started) < 4 || count.withValue({ $0 }) == 0 {
            try box.file("watched/f\(number).txt")
            if number > 3 { try? FileManager.default.removeItem(at: box.url("watched/f\(number - 3).txt")) }
            number += 1
            if number.isMultiple(of: 20) { try await Task.sleep(nanoseconds: 5_000_000) }
            // Given up by the count as well as by the clock: a pause here has taken minutes
            // among the other tests, and the changes made before it may all have come before
            // the stream ran (see the next test).
            if Date().timeIntervalSince(started) > 60, number > 2_000 { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        let reports = count.withValue { $0 }
        // Hundreds of changes; at most one report per half second (plus slack).
        #expect(
            reports >= 1 && Double(reports) <= elapsed / 0.5 + 3,
            "\(reports) reports in \(elapsed) s for \(number) changes"
        )
        watcher.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterStop = count.withValue { $0 }
        for index in 0..<20 { try box.file("watched/late\(index).txt") }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        #expect(count.withValue { $0 } == afterStop)
    }

    /// A folder added to the set that is watched is reported on.
    @Test
    internal func aFolderThatIsWatchedAgainAfterAChangeOfTheSetKeepsReporting() async throws {
        let box = try Sandbox()
        try box.folder("a")
        try box.folder("b")
        let seen = Locked(Set<String>())
        let watcher = DirectoryWatcher(queue: DispatchQueue(label: "test")) { urls in
            seen.withValue { $0.formUnion(urls.map(\.lastPathComponent)) }
        }
        watcher.watch([box.url("a")])
        watcher.watch([box.url("a"), box.url("b")])
        // A change is made again and again until one is reported. The first ones may come
        // before the stream for the new set runs, and what was changed more than a moment
        // before a stream starts is not reported to it (measured: 18 of 20 at 2 ms, 0 of 20
        // at 50 ms). So the test must get to make further changes, and that is counted, not
        // timed: among the other tests of the process a pause of 0.2 s has taken more than
        // two minutes (every thread the tests share was held by tests that wait), and a loop
        // bounded by the clock alone then ended after its first round, with "no report in
        // 60 s" for a watcher that had not been given a change it could see. That, not the
        // watcher, was the failure once seen in a full run.
        var number = 0
        let started = Date()
        while !seen.withValue({ $0.contains("b") }), number < 50 || Date().timeIntervalSince(started) < 60,
            number < 3_000
        {
            try box.file("b/f\(number).txt")
            number += 1
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(
            seen.withValue { $0.contains("b") },
            "no report after \(number) changes in \(Int(Date().timeIntervalSince(started))) s"
        )
        watcher.stop()
    }
}
