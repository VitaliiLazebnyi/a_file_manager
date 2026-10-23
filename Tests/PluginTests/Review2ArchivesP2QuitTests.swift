import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2, second pass: the branches of the quit.
@MainActor
@Suite
internal struct Review2ArchivesP2QuitTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    /// Changes are written before the program quits; with none, the quit goes on at once.
    @Test
    internal func changesAreWrittenBeforeTheProgramQuits() throws {
        let archive = try makeZip()
        let plugin = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
        defer { plugin.store.close() }
        // Nothing to do: done at once, on the calling thread.
        // Written by the other thread before it signals, read here after the wait.
        nonisolated(unsafe) var done = false
        plugin.prepareToQuit(cancellation: CancellationFlag()) { done = true }
        #expect(done && plugin.shouldTerminate())

        let writer = try plugin.store.archive(at: archive, cancellation: nil)
            .write("tree/at-quit.txt", level: nil, password: nil)
        try writer.write(Data("kept".utf8))
        try writer.close(attributes: FileAttributes())
        #expect(plugin.hasPendingChanges && !listed(archive).contains("tree/at-quit.txt"))
        let finished = DispatchSemaphore(value: 0)
        plugin.prepareToQuit(cancellation: CancellationFlag()) { finished.signal() }
        finished.wait()
        #expect(!plugin.hasPendingChanges && listed(archive).contains("tree/at-quit.txt"))
        #expect(!plugin.environment.quitting.isCancelled)
    }

    /// A quit the user does not wait for keeps what was not written, with a list, and says where.
    @Test
    internal func aQuitTheUserDoesNotWaitForKeepsWhatWasNotWritten() throws {
        let archive = try makeZip()
        let plugin = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
        let reports = Collected<String>()
        plugin.environment.reportFailure = { error, _ in reports.add(error.localizedDescription) }
        let opened = try plugin.store.archive(at: archive, cancellation: nil)
        let writer = try opened.write("tree/unwritten.txt", level: nil, password: nil)
        try writer.write(Data("unwritten".utf8))
        try writer.close(attributes: FileAttributes())

        // Somebody holds the archive file (a Pack that runs), so the write has to wait.
        let (holding, release, released) = (
            DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)
        )
        plugin.environment.immediateWriteLimit = 0
        Thread.detachNewThread {
            // (The changes that wait are written first by this call; these come after.)
            try? opened.whileHoldingFile(cancellation: nil) { _ in
                if let late = try? opened.write("tree/late.txt", level: nil, password: nil) {
                    try? late.write(Data("late".utf8))
                    try? late.close(attributes: FileAttributes())
                }
                holding.signal()
                release.wait()
            }
            released.signal()
        }
        holding.wait()
        #expect(plugin.hasPendingChanges)
        // The sheet's Cancel: the hook reports back although nothing could be written…
        let cancellation = CancellationFlag()
        let finished = DispatchSemaphore(value: 0)
        plugin.prepareToQuit(cancellation: cancellation) { finished.signal() }
        cancellation.cancel()
        finished.wait()
        #expect(plugin.hasPendingChanges && plugin.environment.quitting.isCancelled)
        // …and the stop does not start waiting again: the member is kept where it lies,
        // with a list that says what it is, and the user is told where.
        plugin.stop()
        let scratch = plugin.environment.scratch.url
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        let index = try #require(kept.first { $0.hasPrefix("index-") })
        let list = try String(contentsOf: scratch.appendingPathComponent(index), encoding: .utf8)
        #expect(list.contains("tree/late.txt") && kept.contains { $0.hasSuffix(".zipdata") })
        #expect(reports.all.count == 1 && reports.all.first?.contains(scratch.path) == true, "\(reports.all)")
        release.signal()
        released.wait()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A quit that runs out of time ends the writes, or leaves the stuck one, and says where the data is.
    @Test
    internal func aQuitThatRunsOutOfTimeEndsTheWritesAndSaysWhereTheDataIs() throws {
        // First branch: the writes can be ended. Second: one cannot (it waits for something
        // that never answers), and the program quits all the same, deleting nothing.
        for endable in [true, false] { try quitRunsOutOfTime(endable: endable) }
    }

    /// One branch of `aQuitThatRunsOutOfTimeEndsTheWritesAndSaysWhereTheDataIs`: a write that can be ended, or
    /// one that cannot.
    private func quitRunsOutOfTime(endable: Bool) throws {
        let name = endable ? "endable.zip" : "stuck.zip"
        try? FileManager.default.removeItem(at: box.url("tree"))
        let archive = try makeZip(name)
        let plugin = ArchivesPlugin(flushDelay: nil, launchesApplications: false)
        let reports = Collected<String>()
        plugin.environment.reportFailure = { error, _ in reports.add(error.localizedDescription) }
        // (Long enough for the last attempt to save the members, which waits two seconds
        // for the archive file, to be over before the stop gives up on it.)
        plugin.environment.quitTimeout = endable ? 3 : 0.2
        plugin.environment.immediateWriteLimit = 0
        let opened = try plugin.store.archive(at: archive, cancellation: nil)
        let (release, released) = hold(opened, plugin: plugin, endable: endable)
        #expect(plugin.hasPendingChanges)
        plugin.stop()
        #expect(plugin.environment.quitting.isCancelled)
        let scratch = plugin.environment.scratch.url
        let kept = keptFiles(in: scratch, waitingForTheIndex: endable)
        // Told once, with the place; the compressed data is still there.
        #expect(
            reports.all.count == 1 && reports.all.first?.contains(scratch.path) == true,
            "\(endable): \(reports.all)"
        )
        #expect(kept.contains { $0.hasSuffix(".zipdata") }, "\(endable): \(kept)")
        if endable { #expect(kept.contains { $0.hasPrefix("index-") }) }
        // The archive itself is whole, as it was.
        #expect(
            runTool("/usr/bin/unzip", ["-tq", archive.path], in: nil).status == 0
                && !listed(archive).contains("tree/added.txt")
        )
        release.signal()
        released.wait()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Adds a member to `opened` and holds its write until the first semaphore is signalled.
    ///
    /// The write is held by holding the archive file (`endable`: a wait that can be ended) or inside the
    /// write, where nothing ends it. The second semaphore is signalled when the hold is over.
    private func hold(
        _ opened: OpenArchive,
        plugin: ArchivesPlugin,
        endable: Bool
    ) -> (release: DispatchSemaphore, released: DispatchSemaphore) {
        let (holding, release, released) = (
            DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)
        )
        @Sendable
        func add(_ path: String) {
            guard let writer = try? opened.write(path, level: nil, password: nil) else {
                return
            }
            try? writer.write(Data("added".utf8))
            try? writer.close(attributes: FileAttributes())
        }
        if endable {
            // The archive file is held by somebody else: the write waits for it, and that wait can be ended.
            Thread.detachNewThread {
                try? opened.whileHoldingFile(cancellation: nil) { _ in
                    add("tree/added.txt")
                    holding.signal()
                    release.wait()
                }
                released.signal()
            }
            holding.wait()
        } else {
            // The write itself is stuck where nothing ends it.
            add("tree/added.txt")
            plugin.environment.whileWriting = {
                holding.signal()
                release.wait()
                released.signal()
            }
        }
        return (release, released)
    }

    /// What lies in the temporary folder `scratch`.
    ///
    /// When asked to, waits a while for the index of kept members: on a machine too busy for the stop to see
    /// the list written, it is written a moment later.
    private func keptFiles(in scratch: URL, waitingForTheIndex: Bool) -> [String] {
        var kept = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        let patience = Date(timeIntervalSinceNow: Wait.ceiling)
        while waitingForTheIndex, !kept.contains(where: { $0.hasPrefix("index-") }), Date() < patience {
            usleep(20_000)
            kept = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        }
        return kept
    }
}
