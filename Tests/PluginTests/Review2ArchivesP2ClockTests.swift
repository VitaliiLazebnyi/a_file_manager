import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: the clock of the delayed writes (A043, A045).
@MainActor
@Suite
internal struct Review2ArchivesP2ClockTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// A write that is due is done by whichever of its two timers comes first, and none after the quit (A043).
    @Test
    internal func aWriteThatIsDueIsDoneByWhicheverOfItsTwoTimersComesFirst() throws {
        let archive = try makeZip()
        let clock = HandClock()
        bench.environment.schedule = { clock.schedule($0, $1, $2) }
        bench.environment.flushDelay = 3
        bench.environment.escalationDelay = 7
        try write("first", to: bench.inside(archive, "tree/first.txt", scheme: ArchiveURL.writableScheme))
        // One change, two timers: the patient one at the delay, the urgent one behind it.
        let due = clock.take()
        #expect(due.map(\.delay) == [3, 10] && due.map(\.priority) == [.utility, .userInitiated])
        // More changes before it fires arm nothing new.
        try write("second", to: bench.inside(archive, "tree/second.txt", scheme: ArchiveURL.writableScheme))
        #expect(clock.take().isEmpty)
        // The patient one never gets to run (every core is busy); the urgent one writes. The
        // changes have not rested for the delay yet, so it first waits out the rest…
        due[1].work()
        #expect(!listed(archive).contains("tree/first.txt"))
        var next = clock.take()
        #expect(next.count == 2 && next[0].delay > 0 && next[0].delay <= 3)
        // …and writes when the delay has passed.
        bench.environment.flushDelay = 0
        next[1].work()
        #expect(
            listed(archive).contains("tree/first.txt") && listed(archive).contains("tree/second.txt")
                && !bench.store.hasPendingChanges
        )
        // The ones that come late find nothing to do, and arm nothing.
        due[0].work()
        next[0].work()
        #expect(clock.take().isEmpty && !bench.store.hasPendingChanges)
        // After the program began to quit, a timer that still fires writes nothing.
        try write("third", to: bench.inside(archive, "tree/third.txt", scheme: ArchiveURL.writableScheme))
        next = clock.take()
        bench.environment.isStopping = true
        for timer in next { timer.work() }
        #expect(bench.store.hasPendingChanges && !listed(archive).contains("tree/third.txt"))
        bench.environment.isStopping = false
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
    }

    /// A write that fails is tried again after twice as long each time, up to the limit, and at once on a change.
    @Test
    internal func aWriteThatFailsIsTriedAgainEachTimeAfterTwiceAsLong() throws {
        try bench.makeTree("tree")
        try box.folder("locked")
        #expect(runTool("/usr/bin/zip", ["-qr", "locked/tree.zip", "tree"], in: box.root).status == 0)
        let archive = box.url("locked/tree.zip")
        let clock = HandClock()
        let reports = Collected<String>()
        bench.environment.schedule = { clock.schedule($0, $1, $2) }
        bench.environment.reportFailure = { error, _ in reports.add(error.localizedDescription) }
        (bench.environment.flushDelay, bench.environment.escalationDelay) = (0, 1)
        (bench.environment.retryDelay, bench.environment.maxRetryDelay) = (30, 100)
        bench.environment.immediateWriteLimit = 0
        try write("kept back", to: bench.inside(archive, "tree/kept-back.txt", scheme: ArchiveURL.writableScheme))
        var due = clock.take()
        #expect(due.map(\.delay) == [0, 1])
        // The folder takes no new file: the write fails, and goes on failing.
        #expect(chmod(box.url("locked").path, 0o555) == 0)
        defer { chmod(box.url("locked").path, 0o755) }
        var pauses: [TimeInterval] = []
        for _ in 0..<4 {
            due[0].work()
            due = clock.take()
            #expect(due.count == 2 && due.map(\.priority) == [.utility, .userInitiated])
            pauses.append(due.first?.delay ?? -1)
            guard due.count == 2 else { break }
        }
        // 30 s, then twice as long each time, and never more than the limit.
        #expect(pauses == [30, 60, 100, 100], "\(pauses)")
        // The user heard of it once, and the change still waits.
        #expect(reports.all.count == 1 && bench.store.hasPendingChanges)
        // A change brings the next attempt at once, not at the end of the pause.
        #expect(chmod(box.url("locked").path, 0o755) == 0)
        try write("more", to: bench.inside(archive, "tree/more.txt", scheme: ArchiveURL.writableScheme))
        let sooner = clock.take()
        #expect(sooner.map(\.delay) == [0, 1])
        sooner[0].work()
        #expect(
            !bench.store.hasPendingChanges && listed(archive).contains("tree/kept-back.txt")
                && listed(archive).contains("tree/more.txt")
        )
        // The old timers are overtaken: they do nothing.
        for timer in due { timer.work() }
        // After a write that worked, a failure counts from the beginning again.
        try write("last", to: bench.inside(archive, "tree/last.txt", scheme: ArchiveURL.writableScheme))
        due = clock.take()
        #expect(chmod(box.url("locked").path, 0o555) == 0)
        due[0].work()
        #expect(clock.take().first?.delay == 30)
        #expect(chmod(box.url("locked").path, 0o755) == 0)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty)
    }
}
