import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import ArchivesPlugin

/// Review round 2: nothing that was put into an archive is lost, written twice or written
/// where it does not belong, whatever happens while it is written: the quit, changes during a write, members
/// on their way.
@Suite
internal struct Review2ArchivesWriteTests: ArchiveFixSuite {
    /// The archive file systems in a sandbox of their own.
    internal let bench: ArchiveBench

    /// A fresh bench for each test.
    internal init() throws {
        bench = try ArchiveBench()
    }

    // MARK: Quit (A011, A012, A027, A086)

    /// One flush writes a change in an archive inside an archive into both, in either order of the store (A011).
    @Test
    internal func oneCallWritesAnArchiveInsideAnArchive() throws {
        try bench.makeTree("tree")
        #expect(runTool("/usr/bin/zip", ["-qr", "inner.zip", "tree"], in: box.root).status == 0)
        // Large enough that putting it back into the outer archive is left to the delay.
        #expect(try Data(contentsOf: box.url("inner.zip")).count > 300_000)
        #expect(runTool("/usr/bin/zip", ["-q0", "outer.zip", "inner.zip"], in: box.root).status == 0)
        let inner = bench.inside(box.url("outer.zip"), "inner.zip", scheme: ArchiveURL.writableScheme)
        // Both orders of the store's table: whichever archive comes first, both are written.
        for round in 0..<6 {
            try write(
                "edit \(round)",
                to: bench.inside(inner, "tree/new\(round).txt", scheme: ArchiveURL.writableScheme)
            )
            #expect(bench.store.flushAll(cancellation: nil).isEmpty && !bench.store.hasPendingChanges)
            bench.store.close()
            try? FileManager.default.removeItem(at: box.url("check"))
            #expect(
                runTool("/usr/bin/unzip", ["-qo", box.url("outer.zip").path, "-d", box.url("check").path], in: nil)
                    .status == 0
            )
            #expect(listed(box.url("check/inner.zip")).contains("tree/new\(round).txt"), "round \(round)")
        }
    }

    /// One flush writes a change into a ZIP on a server and leaves no temporary file there.
    @Test
    internal func oneCallWritesAnArchiveOnAServerThatKeepsWritesBack() throws {
        let local = try makeZip()
        let onServer = try upload(local, to: "/store/tree.zip")
        try write("to the server", to: bench.inside(onServer, "tree/sent.txt", scheme: ArchiveURL.writableScheme))
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && !bench.store.hasPendingChanges)
        #expect(listed(try download(onServer, as: "from-server.zip")).contains("tree/sent.txt"))
        // Nothing with a temporary name stays on the server.
        #expect(bench.memory.allPaths.allSatisfy { !$0.contains(".afm-") })
    }

    // MARK: Changes while a write is under way (A016, A017)

    /// A member deleted while its first write runs is gone after the next write (A016).
    @Test
    internal func aMemberDeletedWhileItIsFirstWrittenIsGoneAfterTheNextWrite() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme)
        try write("short-lived", to: tree.appending(name: "new.txt"))
        try write("stays", to: tree.appending(name: "other.txt"))
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var fired = false
        bench.environment.whileWriting = { [bench] in
            guard !fired else {
                return
            }
            fired = true
            try? bench.zip.remove(tree.appending(name: "new.txt"))
        }
        // The first write puts the member into the file; the deletion comes while it runs.
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && fired)
        bench.environment.whileWriting = nil
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && !bench.store.hasPendingChanges)
        #expect(!listed(archive).contains("tree/new.txt") && listed(archive).contains("tree/other.txt"))
        bench.store.close()
        #expect(
            try !bench.names(tree, showHidden: true).contains("new.txt")
                && bench.names(tree, showHidden: true).contains("other.txt")
        )
    }

    /// A member replaced while its first write runs is in the file once, with the new contents (A017).
    @Test
    internal func aMemberReplacedWhileItIsFirstWrittenIsWrittenOnce() throws {
        let archive = try makeZip()
        let member = bench.inside(archive, "tree/twice.txt", scheme: ArchiveURL.writableScheme)
        try write("first version", to: member)
        // Used by the callbacks, which run one at a time while the calls below wait for them.
        nonisolated(unsafe) var fired = false
        bench.environment.whileWriting = { [bench] in
            guard !fired else {
                return
            }
            fired = true
            try? bench.zip.remove(member)
            try? write("second version", to: member)
        }
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && fired && !bench.store.hasPendingChanges)
        bench.environment.whileWriting = nil
        #expect(listed(archive).filter { $0 == "tree/twice.txt" }.count == 1)
        #expect(runTool("/usr/bin/unzip", ["-p", archive.path, "tree/twice.txt"], in: nil).output == "second version")
    }

    // MARK: Members on their way (A033, A101)

    /// A member under a job's temporary name is left out of every write and joins under its real name (A033).
    @Test
    internal func aMemberUnderAJobsTemporaryNameIsNeverWrittenIntoTheFile() throws {
        let archive = try makeZip()
        let tree = bench.inside(archive, "tree", scheme: ArchiveURL.writableScheme)
        let temporary = tree.appending(name: ".afm-\(UUID().uuidString).tmp")
        #expect(
            OpenArchive.isTransferName(temporary.lastPathComponent) && !OpenArchive.isTransferName(".afm-short.tmp")
        )
        try write("on its way", to: temporary)
        try write("already there", to: tree.appending(name: "done.txt"))
        let open = try bench.store.archive(at: archive, cancellation: nil)
        // Written by whoever writes (the delay, a commit, the quit): the member is left out,
        // and it is not counted as a change that waits.
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && !open.hasPendingChanges)
        #expect(listed(archive).contains("tree/done.txt") && !listed(archive).contains { $0.contains(".afm-") })
        // The archive is not let go while the member is on its way.
        #expect(open.isBusy && !open.retireIfIdle())
        // It joins the file with its real name.
        try bench.zip.move(temporary, to: tree.appending(name: "arrived.txt"), replacing: false)
        #expect(bench.store.flushAll(cancellation: nil).isEmpty && !open.isBusy)
        #expect(listed(archive).contains("tree/arrived.txt") && !listed(archive).contains { $0.contains(".afm-") })
        // One that its job gives up leaves nothing behind.
        let abandoned = tree.appending(name: ".afm-\(UUID().uuidString).tmp")
        try write("given up", to: abandoned)
        try bench.zip.remove(abandoned)
        #expect(
            bench.store.flushAll(cancellation: nil).isEmpty && !open.isBusy
                && !listed(archive).contains { $0.contains(".afm-") }
        )
    }
}
