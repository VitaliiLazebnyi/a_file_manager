import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: the main thread, the rescue and the gate while a write is under way.
@Suite
internal struct Review2ArchivesGateTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    // MARK: The main thread (A003, A004, A015, A054, A091)

    /// What the main thread asks of an archive is answered while a write holds the archive (A003).
    @Test
    internal func capabilitiesAnswerWhileAWriteIsUnderWay() throws {
        let archive = try makeZip()
        try write("pending", to: bench.inside(archive, "tree/pending.txt", scheme: ArchiveURL.writableScheme))
        let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        bench.environment.whileWriting = {
            entered.signal()
            release.wait()
        }
        let done = DispatchSemaphore(value: 0)
        let store = bench.store
        Thread.detachNewThread {
            _ = store.flushAll(cancellation: nil)
            done.signal()
        }
        entered.wait()
        // The write holds its gate now. What the main thread asks answers all the same.
        let root = bench.inside(archive, "", scheme: ArchiveURL.writableScheme)
        #expect(bench.zip.capabilities(for: root) == [.write, .deferredWrites])
        #expect(bench.store.openArchive(at: archive)?.capabilities == [.write, .deferredWrites])
        // A rename that would write at once does not wait behind the write either.
        try write(
            "second",
            to: bench.inside(archive, "tree/.afm-\(UUID().uuidString).tmp", scheme: ArchiveURL.writableScheme)
        )
        release.signal()
        done.wait()
        bench.environment.whileWriting = nil
        #expect(listed(archive).contains("tree/pending.txt"))
    }

    // MARK: Rescue (A078, A082)

    /// Members kept by the rescue come with an index of what they are; a member on its way is not among them.
    @Test
    internal func membersThatAreKeptComeWithAListOfWhatTheyAre() throws {
        let archive = try makeZip()
        try write("unsaved one", to: bench.inside(archive, "tree/one.txt", scheme: ArchiveURL.writableScheme))
        try write(
            "on its way",
            to: bench.inside(archive, "tree/.afm-\(UUID().uuidString).tmp", scheme: ArchiveURL.writableScheme)
        )
        let open = try bench.store.archive(at: archive, cancellation: nil)
        guard case .kept(let folder) = open.rescue(quickly: true, before: .distantFuture) else {
            Issue.record("the members were not kept")
            return
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let lists = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("index-") }
        let index = try String(contentsOf: folder.appendingPathComponent(try #require(lists.first)), encoding: .utf8)
        // The member with its name, and not the one a job had not finished.
        #expect(
            index.contains("\ttree/one.txt\t") && !index.contains(".afm-") && index.contains(archive.lastPathComponent)
        )
        let file = try #require(index.split(separator: "\n").last?.split(separator: "\t").first)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(file)).path))
    }

    // MARK: The gate

    /// A cancelled second write does not wait for a running one, and the rescue waits no longer than it is given.
    @Test
    internal func aWaitForARunningWriteEndsWhenItIsCancelled() throws {
        let archive = try makeZip()
        try write("pending", to: bench.inside(archive, "tree/pending.txt", scheme: ArchiveURL.writableScheme))
        let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
        bench.environment.whileWriting = {
            entered.signal()
            release.wait()
        }
        let done = DispatchSemaphore(value: 0)
        let store = bench.store
        Thread.detachNewThread {
            _ = store.flushAll(cancellation: nil)
            done.signal()
        }
        entered.wait()
        let open = try #require(bench.store.openArchive(at: archive))
        let flag = CancellationFlag()
        flag.cancel()
        // A second write (a commit, the quit) that is cancelled does not wait for the first.
        #expect {
            try open.flush(leavingOutArrivals: false, cancellation: flag) { _, _ in true }
        } throws: { error in
            if case ArchiveError.cancelled = error {
                return true
            }
            return false
        }
        // And the rescue waits no longer than it is given.
        if case .nothingToSave = open.rescue(quickly: true, before: Date()) {
            Issue.record("the pending member was not seen")
        }
        release.signal()
        done.wait()
        bench.environment.whileWriting = nil
    }
}
